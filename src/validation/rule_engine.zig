const std = @import("std");
const arena_pool = @import("../core/arena_pool.zig");
const batch = @import("../core/batch.zig");
const reader = @import("../core/reader.zig");
const compile_rules = @import("compile.zig");
const evaluator = @import("evaluator.zig");
const rule = @import("rule.zig");
const validation_summary = @import("validation_summary.zig");
const violation = @import("violation.zig");
const violation_sink = @import("violation_sink.zig");
const unique = @import("unique.zig");

pub const Options = struct {
    unique_memory_limit: usize = unique.default_memory_limit,
};

pub const RuleEngine = struct {
    allocator: std.mem.Allocator,
    upstream: reader.Reader,
    definitions: []const rule.Rule,
    sink: violation_sink.ViolationSink,
    compiled_rules: []rule.CompiledRule = &.{},
    summary: validation_summary.ValidationSummary = .{},
    initialized: bool = false,
    finalized: bool = false,
    schema_hash: u64 = 0,
    options: Options,
    unique_trackers: []?unique.Tracker = &.{},

    pub fn init(
        allocator: std.mem.Allocator,
        upstream: reader.Reader,
        definitions: []const rule.Rule,
        sink: violation_sink.ViolationSink,
        options: Options,
    ) RuleEngine {
        return .{
            .allocator = allocator,
            .upstream = upstream,
            .definitions = definitions,
            .sink = sink,
            .options = options,
        };
    }

    pub fn deinit(self: *RuleEngine) void {
        if (!self.finalized) self.sink.abort();
        for (self.unique_trackers) |*tracker| if (tracker.*) |*active| active.deinit();
        if (self.unique_trackers.len != 0) self.allocator.free(self.unique_trackers);
        if (self.compiled_rules.len != 0) compile_rules.deinit(self.allocator, self.compiled_rules);
        if (self.summary.violations_by_rule.len != 0) self.allocator.free(self.summary.violations_by_rule);
        if (self.summary.violations_by_column.len != 0) self.allocator.free(self.summary.violations_by_column);
    }

    pub fn next(self: *RuleEngine, output: *arena_pool.BatchArena) !?batch.Batch {
        const input = try self.upstream.next(output) orelse {
            _ = try self.finalize();
            return null;
        };
        if (!self.initialized) try self.initialize(&input);
        if (input.schema.hash != self.schema_hash) return error.SchemaMismatch;
        try self.validateBatch(&input);
        return input;
    }

    pub fn asReader(self: *RuleEngine) reader.Reader {
        return .{ .ptr = self, .next_fn = nextOpaque };
    }

    pub fn finalize(self: *RuleEngine) !*const validation_summary.ValidationSummary {
        if (!self.finalized) {
            for (self.unique_trackers) |tracker| {
                if (tracker) |active| self.summary.unique_rules_spilled += @intFromBool(active.spilled);
            }
            try self.sink.finish();
            self.finalized = true;
        }
        return &self.summary;
    }

    fn initialize(self: *RuleEngine, input: *const batch.Batch) !void {
        self.compiled_rules = try compile_rules.compile(self.allocator, input.schema, self.definitions);
        errdefer {
            compile_rules.deinit(self.allocator, self.compiled_rules);
            self.compiled_rules = &.{};
        }
        self.unique_trackers = try self.allocator.alloc(?unique.Tracker, self.compiled_rules.len);
        @memset(self.unique_trackers, null);
        errdefer {
            for (self.unique_trackers) |*tracker| if (tracker.*) |*active| active.deinit();
            self.allocator.free(self.unique_trackers);
            self.unique_trackers = &.{};
        }
        for (self.compiled_rules, self.unique_trackers) |compiled, *tracker| {
            if (compiled.tag == .unique) {
                tracker.* = try unique.Tracker.init(self.allocator, self.options.unique_memory_limit);
            }
        }
        self.summary.violations_by_rule = try self.allocator.alloc(
            validation_summary.RuleCount,
            self.compiled_rules.len,
        );
        errdefer {
            self.allocator.free(self.summary.violations_by_rule);
            self.summary.violations_by_rule = &.{};
        }
        for (self.compiled_rules, self.summary.violations_by_rule) |compiled, *count| {
            count.* = .{ .rule_id = compiled.id };
        }
        self.summary.violations_by_column = try self.allocator.alloc(
            validation_summary.ColumnCount,
            input.columns.len,
        );
        for (self.summary.violations_by_column, 0..) |*count, index| {
            count.* = .{ .column_index = @intCast(index) };
        }
        self.initialized = true;
        self.schema_hash = input.schema.hash;
    }

    fn validateBatch(self: *RuleEngine, input: *const batch.Batch) !void {
        var buffer: [256]violation.Violation = undefined;
        var buffer_len: usize = 0;
        for (0..input.row_count) |row| {
            var row_failed = false;
            for (self.compiled_rules, 0..) |compiled, rule_index| {
                const column_index: usize = compiled.column_index;
                const target = input.column(column_index);
                const code = if (compiled.tag == .unique) blk: {
                    if (target.isNull(row)) continue;
                    var key_buffer: [80]u8 = undefined;
                    const key = try unique.canonicalKey(target, row, &key_buffer);
                    if (!try self.unique_trackers[rule_index].?.observe(key)) continue;
                    break :blk violation.Code.duplicate_value;
                } else evaluator.evaluate(compiled, target, row) orelse continue;
                row_failed = true;
                self.summary.total_violations += 1;
                self.summary.violations_by_rule[rule_index].count += 1;
                self.summary.violations_by_column[column_index].count += 1;
                buffer[buffer_len] = .{
                    .row_id = .{
                        .source_id = input.metadata.source_id,
                        .batch_id = input.metadata.batch_id,
                        .row_in_batch = @intCast(row),
                        .global_offset = input.metadata.global_row_offset + row,
                    },
                    .column_index = compiled.column_index,
                    .rule_id = compiled.id,
                    .code = code,
                };
                buffer_len += 1;
                if (buffer_len == buffer.len) {
                    try self.sink.write(&buffer);
                    buffer_len = 0;
                }
            }
            self.summary.rows_with_violations += @intFromBool(row_failed);
        }
        if (buffer_len != 0) try self.sink.write(buffer[0..buffer_len]);
        self.summary.rows_processed += input.row_count;
        self.summary.batches_processed += 1;
    }

    fn nextOpaque(ptr: *anyopaque, output: *arena_pool.BatchArena) anyerror!?batch.Batch {
        const self: *RuleEngine = @ptrCast(@alignCast(ptr));
        return self.next(output);
    }
};

test "rule engine counts violations without stopping the stream" {
    const schema = @import("../core/schema.zig");
    const batch_builder = @import("../core/batch.zig");
    const ProbeReader = struct {
        input: batch.Batch,
        emitted: bool = false,
        fn next(ptr: *anyopaque, _: *arena_pool.BatchArena) !?batch.Batch {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            if (self.emitted) return null;
            self.emitted = true;
            return self.input;
        }
    };
    var arena = arena_pool.BatchArena.init(std.testing.allocator);
    defer arena.deinit();
    const fields = [_]schema.Field{.{ .name = "age", .tag = .i64 }};
    const source_schema = schema.Schema{ .fields = &fields, .hash = schema.Schema.computeHash(&fields) };
    var builder = try batch_builder.Builder.init(&arena, &source_schema);
    try builder.appendI64(0, 12);
    try builder.finishRow();
    const input = try builder.finish(.{});
    var probe = ProbeReader{ .input = input };
    const definitions = [_]rule.Rule{.{ .id = 7, .column = "age", .tag = .range, .min = "18" }};
    var samples = violation_sink.SamplingSink.init(std.testing.allocator, 10);
    defer samples.deinit();
    var engine = RuleEngine.init(
        std.testing.allocator,
        .{ .ptr = &probe, .next_fn = ProbeReader.next },
        &definitions,
        samples.asSink(),
        .{},
    );
    defer engine.deinit();
    try std.testing.expect((try engine.next(&arena)) != null);
    const summary = try engine.finalize();
    try std.testing.expectEqual(@as(u64, 1), summary.total_violations);
    try std.testing.expectEqual(violation.Code.below_minimum, samples.samples.items[0].code);
}

test "regex and exact uniqueness work across batches after spill" {
    const schema = @import("../core/schema.zig");
    const batch_builder = @import("../core/batch.zig");
    const ProbeReader = struct {
        inputs: [2]batch.Batch,
        index: usize = 0,

        fn next(ptr: *anyopaque, _: *arena_pool.BatchArena) !?batch.Batch {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            if (self.index == self.inputs.len) return null;
            defer self.index += 1;
            return self.inputs[self.index];
        }
    };

    var arena = arena_pool.BatchArena.init(std.testing.allocator);
    defer arena.deinit();
    const fields = [_]schema.Field{.{ .name = "code", .tag = .string }};
    const source_schema = schema.Schema{ .fields = &fields, .hash = schema.Schema.computeHash(&fields) };
    var first_builder = try batch_builder.Builder.init(&arena, &source_schema);
    try first_builder.appendString(0, "AA-0001");
    try first_builder.finishRow();
    try first_builder.appendString(0, "BB-0002");
    try first_builder.finishRow();
    const first = try first_builder.finish(.{ .batch_id = 0, .global_row_offset = 0 });
    var second_builder = try batch_builder.Builder.init(&arena, &source_schema);
    try second_builder.appendString(0, "bad");
    try second_builder.finishRow();
    try second_builder.appendString(0, "AA-0001");
    try second_builder.finishRow();
    const second = try second_builder.finish(.{ .batch_id = 1, .global_row_offset = 2 });

    var probe = ProbeReader{ .inputs = .{ first, second } };
    const definitions = [_]rule.Rule{
        .{ .id = 10, .column = "code", .tag = .regex, .regex = "^[A-Z]{2}-[0-9]{4}$" },
        .{ .id = 11, .column = "code", .tag = .unique },
    };
    var samples = violation_sink.SamplingSink.init(std.testing.allocator, 10);
    defer samples.deinit();
    var engine = RuleEngine.init(
        std.testing.allocator,
        .{ .ptr = &probe, .next_fn = ProbeReader.next },
        &definitions,
        samples.asSink(),
        .{ .unique_memory_limit = 40 },
    );
    defer engine.deinit();
    var output = arena_pool.BatchArena.init(std.testing.allocator);
    defer output.deinit();
    while (try engine.next(&output)) |_| output.reset();
    const summary = try engine.finalize();

    try std.testing.expect(engine.unique_trackers[1].?.spilled);
    try std.testing.expectEqual(@as(u64, 2), summary.total_violations);
    try std.testing.expectEqual(@as(u64, 2), summary.rows_with_violations);
    try std.testing.expectEqual(violation.Code.regex_mismatch, samples.samples.items[0].code);
    try std.testing.expectEqual(violation.Code.duplicate_value, samples.samples.items[1].code);
    try std.testing.expectEqual(@as(u64, 3), samples.samples.items[1].row_id.global_offset);
}

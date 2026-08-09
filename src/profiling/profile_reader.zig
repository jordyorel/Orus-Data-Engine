const std = @import("std");
const arena_pool = @import("../core/arena_pool.zig");
const batch = @import("../core/batch.zig");
const reader = @import("../core/reader.zig");
const column_profiler = @import("column_profiler.zig");
const profile_report = @import("profile_report.zig");

pub const ProfileReader = struct {
    allocator: std.mem.Allocator,
    upstream: reader.Reader,
    profilers: std.ArrayList(column_profiler.ColumnProfiler) = .empty,
    rows_processed: u64 = 0,
    batches_processed: u64 = 0,
    source_id: u128 = 0,
    schema_hash: ?u64 = null,

    pub fn init(allocator: std.mem.Allocator, upstream: reader.Reader) ProfileReader {
        return .{ .allocator = allocator, .upstream = upstream };
    }

    pub fn deinit(self: *ProfileReader) void {
        for (self.profilers.items) |*profiler| profiler.deinit(self.allocator);
        self.profilers.deinit(self.allocator);
    }

    pub fn next(self: *ProfileReader, output: *arena_pool.BatchArena) !?batch.Batch {
        const input = try self.upstream.next(output) orelse return null;
        try self.observe(&input);
        return input;
    }

    pub fn observe(self: *ProfileReader, input: *const batch.Batch) !void {
        if (self.schema_hash == null) {
            try self.initialize(input);
        } else if (self.schema_hash.? != input.schema.hash) {
            return error.SchemaMismatch;
        }
        for (input.columns, self.profilers.items) |*input_column, *profiler| {
            try profiler.update(input_column);
        }
        self.rows_processed += input.row_count;
        self.batches_processed += 1;
    }

    pub fn asReader(self: *ProfileReader) reader.Reader {
        return .{ .ptr = self, .next_fn = nextOpaque };
    }

    /// Produces a report fully owned by `allocator`.
    pub fn finalize(self: *const ProfileReader, allocator: std.mem.Allocator) !profile_report.ProfileReport {
        const columns = try allocator.alloc(profile_report.ColumnProfile, self.profilers.items.len);
        errdefer allocator.free(columns);
        var initialized: usize = 0;
        errdefer for (columns[0..initialized]) |item| {
            allocator.free(item.name);
            if (item.decimal) |decimal| {
                allocator.free(decimal.min);
                allocator.free(decimal.max);
            }
        };

        for (self.profilers.items, 0..) |profiler, index| {
            const item = profile_report.ColumnProfile{
                .name = try allocator.dupe(u8, profiler.name),
                .tag = profiler.tag,
                .nullable = profiler.nullable,
                .null_count = profiler.nulls.null_count,
                .null_rate = profiler.nulls.nullRate(),
                .distinct_count = profiler.cardinality.distinctCount(),
                .cardinality_mode = profiler.cardinality.mode,
            };
            columns[index] = item;
            initialized += 1;
            switch (profiler.tag) {
                .i64, .f64, .date, .datetime => if (profiler.numeric.count != 0) {
                    columns[index].numeric = .{
                        .min = profiler.numeric.min,
                        .max = profiler.numeric.max,
                        .mean = profiler.numeric.mean,
                        .variance = profiler.numeric.variance(),
                    };
                },
                .decimal => if (profiler.decimal.count != 0) {
                    columns[index].decimal = try decimalProfile(allocator, &profiler);
                },
                .string => {
                    if (profiler.length.count != 0) columns[index].length = .{
                        .min = profiler.length.min,
                        .max = profiler.length.max,
                        .mean = profiler.length.mean,
                    };
                    columns[index].detected_pattern = profiler.patterns.detected();
                },
                .boolean => {},
            }
        }
        return .{
            .columns = columns,
            .rows_processed = self.rows_processed,
            .batches_processed = self.batches_processed,
            .source_id = self.source_id,
            .schema_hash = self.schema_hash orelse 0,
        };
    }

    fn initialize(self: *ProfileReader, input: *const batch.Batch) !void {
        try self.profilers.ensureTotalCapacity(self.allocator, input.schema.fields.len);
        for (input.schema.fields) |field| {
            try self.appendProfiler(field.name, field.tag, field.nullable);
        }
        self.schema_hash = input.schema.hash;
        self.source_id = input.metadata.source_id;
    }

    fn appendProfiler(
        self: *ProfileReader,
        name: []const u8,
        tag: @import("../core/value.zig").ValueTag,
        nullable: bool,
    ) !void {
        var profiler = try column_profiler.ColumnProfiler.init(
            self.allocator,
            name,
            tag,
            nullable,
        );
        errdefer profiler.deinit(self.allocator);
        try self.profilers.append(self.allocator, profiler);
    }

    fn nextOpaque(ptr: *anyopaque, output: *arena_pool.BatchArena) anyerror!?batch.Batch {
        const self: *ProfileReader = @ptrCast(@alignCast(ptr));
        return self.next(output);
    }
};

fn decimalProfile(
    allocator: std.mem.Allocator,
    profiler: *const column_profiler.ColumnProfiler,
) !profile_report.DecimalProfile {
    const min = try profiler.decimal.min.toString(allocator);
    errdefer allocator.free(min);
    return .{
        .min = min,
        .max = try profiler.decimal.max.toString(allocator),
    };
}

test "profile reader retains no pointers into batch memory" {
    const schema = @import("../core/schema.zig");
    var arena = arena_pool.BatchArena.init(std.testing.allocator);
    defer arena.deinit();
    const fields = [_]schema.Field{.{ .name = "name" }};
    const source_schema = schema.Schema{ .fields = &fields, .hash = schema.Schema.computeHash(&fields) };
    var builder = try batch.Builder.init(&arena, &source_schema);
    try builder.appendString(0, "Ada");
    try builder.finishRow();
    const input = try builder.finish(.{});
    var profiler = ProfileReader.init(std.testing.allocator, undefined);
    defer profiler.deinit();
    try profiler.observe(&input);
    arena.reset();
    var report = try profiler.finalize(std.testing.allocator);
    defer report.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), report.columns[0].distinct_count);
    try std.testing.expectEqualStrings("name", report.columns[0].name);
}

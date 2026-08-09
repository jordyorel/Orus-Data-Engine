const std = @import("std");
const arena_pool = @import("../core/arena_pool.zig");
const batch = @import("../core/batch.zig");
const reader = @import("../core/reader.zig");
const schema = @import("../core/schema.zig");
const source = @import("../connectors/source.zig");
const converter = @import("converter.zig");
const type_infer = @import("type_infer.zig");

pub const Options = struct {
    inference: type_infer.Options = .{},
    conversion: converter.Options = .{ .invalid_value_policy = .null_value },
};

pub const IngestReader = struct {
    allocator: std.mem.Allocator,
    upstream: source.Source,
    options: Options,
    inferred_schema: ?schema.Schema = null,
    invalid_values: u64 = 0,
    raw_arena: arena_pool.BatchArena,

    pub fn init(allocator: std.mem.Allocator, upstream: source.Source, options: Options) IngestReader {
        return .{
            .allocator = allocator,
            .upstream = upstream,
            .options = options,
            .raw_arena = arena_pool.BatchArena.init(allocator),
        };
    }

    pub fn deinit(self: *IngestReader) void {
        if (self.inferred_schema) |*inferred| inferred.deinit(self.allocator);
        self.raw_arena.deinit();
    }

    /// Reads one raw batch and writes its typed representation into `output`.
    /// The inferred schema is owned by this reader and survives arena resets.
    pub fn next(self: *IngestReader, output: *arena_pool.BatchArena) !?batch.Batch {
        self.raw_arena.reset();
        const raw = try self.upstream.nextRaw(&self.raw_arena) orelse return null;
        if (self.inferred_schema == null) {
            self.inferred_schema = try type_infer.inferSchema(
                self.allocator,
                &raw,
                self.options.inference,
                true,
            );
        }
        const converted = try converter.convert(
            output,
            &raw,
            &self.inferred_schema.?,
            self.options.conversion,
        );
        self.invalid_values += converted.invalid_values;
        return converted.output;
    }

    pub fn asReader(self: *IngestReader) reader.Reader {
        return .{ .ptr = self, .next_fn = nextOpaque };
    }

    pub fn inferredSchema(self: *const IngestReader) ?*const schema.Schema {
        return if (self.inferred_schema) |*inferred| inferred else null;
    }

    fn nextOpaque(ptr: *anyopaque, output: *arena_pool.BatchArena) anyerror!?batch.Batch {
        const self: *IngestReader = @ptrCast(@alignCast(ptr));
        return self.next(output);
    }
};

test "ingest reader infers once and streams typed csv batches" {
    const csv_source = @import("../connectors/csv_source.zig");
    var csv = try csv_source.CsvSource.init(
        std.testing.io,
        std.testing.allocator,
        "fixtures/sample.csv",
        .{ .batch_size = 2 },
    );
    defer csv.deinit();
    var ingest = IngestReader.init(std.testing.allocator, csv.asSource(), .{});
    defer ingest.deinit();
    var arena = arena_pool.BatchArena.init(std.testing.allocator);
    defer arena.deinit();

    const first = (try ingest.next(&arena)).?;
    try std.testing.expectEqual(@as(usize, 2), first.row_count);
    try std.testing.expectEqual(@import("../core/value.zig").ValueTag.string, first.column(0).tag);
    try std.testing.expectEqual(@import("../core/value.zig").ValueTag.i64, first.column(2).tag);
    try std.testing.expectEqual(@as(i64, 10), first.column(2).get(0).?.i64);
    try std.testing.expect(first.column(2).get(1) == null);
    const schema_hash = first.schema.hash;

    arena.reset();
    const second = (try ingest.asReader().next(&arena)).?;
    try std.testing.expectEqual(@as(usize, 1), second.row_count);
    try std.testing.expectEqual(schema_hash, second.schema.hash);
    try std.testing.expectEqual(@as(i64, 7), second.column(2).get(0).?.i64);
    try std.testing.expect((try ingest.next(&arena)) == null);
}

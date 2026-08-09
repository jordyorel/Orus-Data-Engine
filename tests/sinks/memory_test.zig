const std = @import("std");
const engine = @import("orus_data_engine");

test "memory sink retains a bounded stable batch" {
    var source = try engine.connectors.jsonl_source.JsonlSource.init(
        std.testing.io,
        std.testing.allocator,
        "fixtures/jsonl/customers.jsonl",
        .{ .batch_size = 2 },
    );
    defer source.deinit();
    var input_arena = engine.core.arena_pool.BatchArena.init(std.testing.allocator);
    defer input_arena.deinit();
    var output = try engine.sinks.memory_sink.MemorySink.init(std.testing.allocator, 3, 4096);
    defer output.deinit();
    while (try source.nextRaw(&input_arena)) |input| {
        try output.write(&input);
        input_arena.reset();
    }
    try output.finish();
    const retained = (try output.batch()).?;
    try std.testing.expectEqual(@as(usize, 3), retained.row_count);
    try std.testing.expectEqualStrings("Alice \"A\"", retained.column(1).get(0).?.string);
    try std.testing.expect(retained.column(1).isNull(2));
}

test "memory sink rejects input beyond its row limit" {
    var source = try engine.connectors.jsonl_source.JsonlSource.init(
        std.testing.io,
        std.testing.allocator,
        "fixtures/jsonl/customers.jsonl",
        .{},
    );
    defer source.deinit();
    var arena = engine.core.arena_pool.BatchArena.init(std.testing.allocator);
    defer arena.deinit();
    const input = (try source.nextRaw(&arena)).?;
    var output = try engine.sinks.memory_sink.MemorySink.init(std.testing.allocator, 2, 4096);
    defer output.deinit();
    try std.testing.expectError(error.MemorySinkRowLimit, output.write(&input));
}

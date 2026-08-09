const std = @import("std");
const engine = @import("orus_data_engine");

test "file sources propagate a version and finalize the exact content hash" {
    try verifyCsv("fixtures/csv/replay.csv");
    try verifyJsonl("fixtures/jsonl/customers.jsonl");
}

fn verifyCsv(path: []const u8) !void {
    var source = try engine.connectors.csv_source.CsvSource.init(
        std.testing.io,
        std.testing.allocator,
        path,
        .{ .batch_size = 1 },
    );
    defer source.deinit();
    const version = source.identity_value.version;
    try std.testing.expect(version != 0);
    var arena = engine.core.arena_pool.BatchArena.init(std.testing.allocator);
    defer arena.deinit();
    while (try source.nextRaw(&arena)) |input| {
        try std.testing.expectEqual(version, input.metadata.source_version);
        arena.reset();
    }
    try expectHash(path, source.identity_value.content_hash);
}

fn verifyJsonl(path: []const u8) !void {
    var source = try engine.connectors.jsonl_source.JsonlSource.init(
        std.testing.io,
        std.testing.allocator,
        path,
        .{ .batch_size = 1 },
    );
    defer source.deinit();
    const version = source.identity_value.version;
    try std.testing.expect(version != 0);
    var arena = engine.core.arena_pool.BatchArena.init(std.testing.allocator);
    defer arena.deinit();
    while (try source.nextRaw(&arena)) |input| {
        try std.testing.expectEqual(version, input.metadata.source_version);
        arena.reset();
    }
    try expectHash(path, source.identity_value.content_hash);
}

fn expectHash(path: []const u8, actual: [32]u8) !void {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        path,
        std.testing.allocator,
        .limited(1024 * 1024),
    );
    defer std.testing.allocator.free(bytes);
    var expected: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &expected, .{});
    try std.testing.expectEqualSlices(u8, &expected, &actual);
}

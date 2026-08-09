const std = @import("std");
const engine = @import("orus_data_engine");

test "JSONL source infers a typed schema and streams batches" {
    var source = try engine.connectors.jsonl_source.JsonlSource.init(
        std.testing.io,
        std.testing.allocator,
        "fixtures/jsonl/customers.jsonl",
        .{ .batch_size = 2 },
    );
    defer source.deinit();
    var arena = engine.core.arena_pool.BatchArena.init(std.testing.allocator);
    defer arena.deinit();

    const first = (try source.nextRaw(&arena)).?;
    try std.testing.expectEqual(@as(usize, 2), first.row_count);
    try std.testing.expectEqual(engine.core.value.ValueTag.i64, first.schema.fields[0].tag);
    try std.testing.expectEqual(engine.core.value.ValueTag.boolean, first.schema.fields[2].tag);
    try std.testing.expectEqual(engine.core.value.ValueTag.f64, first.schema.fields[3].tag);
    try std.testing.expectEqual(@as(i64, 1), first.column(0).get(0).?.i64);
    try std.testing.expectEqualStrings("Alice \"A\"", first.column(1).get(0).?.string);
    try std.testing.expectEqualStrings("Bob", first.column(1).get(1).?.string);
    arena.reset();

    const second = (try source.nextRaw(&arena)).?;
    try std.testing.expectEqual(@as(usize, 1), second.row_count);
    try std.testing.expect(second.column(1).isNull(0));
    try std.testing.expect((try source.nextRaw(&arena)) == null);
    try std.testing.expect(source.asSource().bytesRead() > 0);
}

test "JSONL source rejects unsupported or inconsistent records" {
    const Case = struct { path: []const u8, expected: anyerror };
    const cases = [_]Case{
        .{ .path = "fixtures/jsonl/unknown-field.jsonl", .expected = error.UnknownJsonField },
        .{ .path = "fixtures/jsonl/nested.jsonl", .expected = error.NestedJsonValueUnsupported },
        .{ .path = "fixtures/jsonl/type-mismatch.jsonl", .expected = error.JsonTypeMismatch },
    };
    for (cases) |case| {
        var source = try engine.connectors.jsonl_source.JsonlSource.init(
            std.testing.io,
            std.testing.allocator,
            case.path,
            .{},
        );
        defer source.deinit();
        var arena = engine.core.arena_pool.BatchArena.init(std.testing.allocator);
        defer arena.deinit();
        try std.testing.expectError(case.expected, source.nextRaw(&arena));
    }
}

test "JSONL sink writes data readable by the JSONL source" {
    const output_path = ".zig-cache/jsonl-roundtrip.jsonl";
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, output_path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => std.debug.panic("cannot remove test output: {s}", .{@errorName(err)}),
    };
    var input = try engine.connectors.jsonl_source.JsonlSource.init(
        std.testing.io,
        std.testing.allocator,
        "fixtures/jsonl/customers.jsonl",
        .{ .batch_size = 2 },
    );
    defer input.deinit();
    var output = try engine.sinks.jsonl_sink.JsonlSink.open(
        std.testing.io,
        std.testing.allocator,
        output_path,
    );
    defer output.deinit();
    var arena = engine.core.arena_pool.BatchArena.init(std.testing.allocator);
    defer arena.deinit();
    while (try input.nextRaw(&arena)) |input_batch| {
        try output.write(&input_batch);
        arena.reset();
    }
    try output.finish();
    try std.testing.expectEqual(@as(u64, 3), output.rows_written);

    var replay = try engine.connectors.jsonl_source.JsonlSource.init(
        std.testing.io,
        std.testing.allocator,
        output_path,
        .{},
    );
    defer replay.deinit();
    const replayed = (try replay.nextRaw(&arena)).?;
    try std.testing.expectEqual(@as(usize, 3), replayed.row_count);
}

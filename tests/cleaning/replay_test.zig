const std = @import("std");
const engine = @import("orus_data_engine");

test "audit replay reproduces transformed batches exactly" {
    const audit_path = ".zig-cache/replay-test.audit.jsonl";
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, audit_path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => std.debug.panic("cannot remove replay fixture: {s}", .{@errorName(err)}),
    };
    const spec = engine.cleaning.transform_registry.TransformSpec{
        .id = 7,
        .column = "name",
        .operation = .trim,
    };
    var audit = try engine.cleaning.audit_log.AuditLog.open(
        std.testing.io,
        std.testing.allocator,
        audit_path,
    );
    defer audit.deinit();
    var original_csv = try engine.connectors.csv_source.CsvSource.init(
        std.testing.io,
        std.testing.allocator,
        "fixtures/csv/replay.csv",
        .{ .batch_size = 2 },
    );
    defer original_csv.deinit();
    var original_ingest = engine.ingestion.ingest_reader.IngestReader.init(
        std.testing.allocator,
        original_csv.asSource(),
        .{},
    );
    defer original_ingest.deinit();
    var input_arena = engine.core.arena_pool.BatchArena.init(std.testing.allocator);
    defer input_arena.deinit();
    var output_arena = engine.core.arena_pool.BatchArena.init(std.testing.allocator);
    defer output_arena.deinit();
    var scratch = engine.execution.allocators.ScratchArena.init(std.testing.allocator);
    defer scratch.deinit();
    while (try original_ingest.next(&input_arena)) |input| {
        const operation = try spec.compile(input.schema);
        const transformed = try operation.asTransform().apply(&input, &output_arena, scratch.allocator());
        const entry = engine.cleaning.provenance.create(99, &.{spec}, &input, &transformed, 1);
        try audit.record(&entry);
        input_arena.reset();
        output_arena.reset();
        scratch.reset();
    }
    _ = try audit.finish();

    var replay_csv = try engine.connectors.csv_source.CsvSource.init(
        std.testing.io,
        std.testing.allocator,
        "fixtures/csv/replay.csv",
        .{ .batch_size = 2 },
    );
    defer replay_csv.deinit();
    var replay_ingest = engine.ingestion.ingest_reader.IngestReader.init(
        std.testing.allocator,
        replay_csv.asSource(),
        .{},
    );
    defer replay_ingest.deinit();
    var replay = try engine.cleaning.replay.ReplayReader.init(
        std.testing.io,
        std.testing.allocator,
        replay_ingest.asReader(),
        audit_path,
        .{},
    );
    defer replay.deinit();
    var replay_output = engine.core.arena_pool.BatchArena.init(std.testing.allocator);
    defer replay_output.deinit();
    const expected = [_][]const u8{ "Ada", "Bob", "Clara" };
    var row: usize = 0;
    while (try replay.next(&replay_output)) |replayed| {
        for (0..replayed.row_count) |batch_row| {
            try std.testing.expectEqualStrings(expected[row], replayed.column(1).get(batch_row).?.string);
            row += 1;
        }
        replay_output.reset();
    }
    try std.testing.expectEqual(expected.len, row);
}

test "replay rejects a missing audit entry" {
    const audit_path = ".zig-cache/replay-empty.audit.jsonl";
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, audit_path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => std.debug.panic("cannot remove empty audit: {s}", .{@errorName(err)}),
    };
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = audit_path, .data = "" });
    var csv = try engine.connectors.csv_source.CsvSource.init(
        std.testing.io,
        std.testing.allocator,
        "fixtures/csv/replay.csv",
        .{},
    );
    defer csv.deinit();
    var ingest = engine.ingestion.ingest_reader.IngestReader.init(
        std.testing.allocator,
        csv.asSource(),
        .{},
    );
    defer ingest.deinit();
    var replay = try engine.cleaning.replay.ReplayReader.init(
        std.testing.io,
        std.testing.allocator,
        ingest.asReader(),
        audit_path,
        .{},
    );
    defer replay.deinit();
    var output = engine.core.arena_pool.BatchArena.init(std.testing.allocator);
    defer output.deinit();
    try std.testing.expectError(error.ReplayAuditEndedEarly, replay.next(&output));
}

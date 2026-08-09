const std = @import("std");
const engine = @import("orus_data_engine");

test "exact matcher indexes and matches complete multi-batch datasets" {
    var reference_csv = try engine.connectors.csv_source.CsvSource.init(
        std.testing.io,
        std.testing.allocator,
        "fixtures/matching/reference.csv",
        .{ .batch_size = 2 },
    );
    defer reference_csv.deinit();
    var candidate_csv = try engine.connectors.csv_source.CsvSource.init(
        std.testing.io,
        std.testing.allocator,
        "fixtures/matching/candidates.csv",
        .{ .batch_size = 1 },
    );
    defer candidate_csv.deinit();
    var reference_ingest = engine.ingestion.ingest_reader.IngestReader.init(
        std.testing.allocator,
        reference_csv.asSource(),
        .{},
    );
    defer reference_ingest.deinit();
    var candidate_ingest = engine.ingestion.ingest_reader.IngestReader.init(
        std.testing.allocator,
        candidate_csv.asSource(),
        .{},
    );
    defer candidate_ingest.deinit();
    var output = engine.matching.match_sink.SamplingSink.init(std.testing.allocator, 10);
    defer output.deinit();
    var matcher = try engine.matching.matcher.Matcher.init(
        std.testing.allocator,
        .{
            .reference_column = 1,
            .candidate_column = 1,
            .blocking = .{ .prefix = 3 },
            .index_memory_limit = 64 * 1024,
        },
        output.asSink(),
    );
    defer matcher.deinit();
    var arena = engine.core.arena_pool.BatchArena.init(std.testing.allocator);
    defer arena.deinit();
    var scratch = engine.execution.allocators.ScratchArena.init(std.testing.allocator);
    defer scratch.deinit();

    const summary = try matcher.run(
        reference_ingest.asReader(),
        candidate_ingest.asReader(),
        &arena,
        &scratch,
    );
    try std.testing.expectEqual(@as(u64, 3), summary.reference_rows);
    try std.testing.expectEqual(@as(u64, 3), summary.candidate_rows);
    try std.testing.expectEqual(@as(u64, 2), summary.reference_batches);
    try std.testing.expectEqual(@as(u64, 3), summary.candidate_batches);
    try std.testing.expectEqual(@as(u64, 3), summary.matches);
    try std.testing.expectEqual(@as(usize, 3), output.samples.items.len);
    try std.testing.expect(output.finished);
    try std.testing.expectEqual(@as(u64, 0), output.samples.items[0].right.global_offset);
    try std.testing.expect(output.samples.items[0].left.source_id != output.samples.items[0].right.source_id);
    try std.testing.expectEqual(engine.matching.match_result.Method.exact, output.samples.items[0].method);
    try std.testing.expectEqual(@as(f32, 1), output.samples.items[0].score);
}

test "matcher streams result buffers progressively" {
    const schema = engine.core.schema;
    const ProbeReader = struct {
        input: engine.core.batch.Batch,
        emitted: bool = false,

        fn next(ptr: *anyopaque, _: *engine.core.arena_pool.BatchArena) !?engine.core.batch.Batch {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            if (self.emitted) return null;
            self.emitted = true;
            return self.input;
        }
    };
    const CountingSink = struct {
        writes: u32 = 0,
        results: u64 = 0,
        finished: bool = false,

        fn asSink(self: *@This()) engine.matching.match_sink.MatchSink {
            return .{ .ptr = self, .write_fn = write, .finish_fn = finish, .abort_fn = abort };
        }

        fn write(ptr: *anyopaque, results: []const engine.matching.match_result.MatchResult) !void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.writes += 1;
            self.results += results.len;
        }

        fn finish(ptr: *anyopaque) !void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.finished = true;
        }

        fn abort(_: *anyopaque) void {}
    };

    var storage = engine.core.arena_pool.BatchArena.init(std.testing.allocator);
    defer storage.deinit();
    const fields = [_]schema.Field{.{ .name = "key", .tag = .string }};
    const source_schema = schema.Schema{ .fields = &fields, .hash = schema.Schema.computeHash(&fields) };
    var reference_builder = try engine.core.batch.Builder.init(&storage, &source_schema);
    try reference_builder.appendString(0, "same");
    try reference_builder.finishRow();
    const reference_batch = try reference_builder.finish(.{ .source_id = 1 });
    var candidate_builder = try engine.core.batch.Builder.init(&storage, &source_schema);
    for (0..300) |_| {
        try candidate_builder.appendString(0, "same");
        try candidate_builder.finishRow();
    }
    const candidate_batch = try candidate_builder.finish(.{ .source_id = 2 });
    var reference = ProbeReader{ .input = reference_batch };
    var candidates = ProbeReader{ .input = candidate_batch };
    var output = CountingSink{};
    var matcher = try engine.matching.matcher.Matcher.init(
        std.testing.allocator,
        .{ .reference_column = 0, .candidate_column = 0, .index_memory_limit = 64 * 1024 },
        output.asSink(),
    );
    defer matcher.deinit();
    var arena = engine.core.arena_pool.BatchArena.init(std.testing.allocator);
    defer arena.deinit();
    var scratch = engine.execution.allocators.ScratchArena.init(std.testing.allocator);
    defer scratch.deinit();

    const summary = try matcher.run(
        .{ .ptr = &reference, .next_fn = ProbeReader.next },
        .{ .ptr = &candidates, .next_fn = ProbeReader.next },
        &arena,
        &scratch,
    );
    try std.testing.expectEqual(@as(u64, 300), summary.matches);
    try std.testing.expectEqual(@as(u64, 300), output.results);
    try std.testing.expectEqual(@as(u32, 2), output.writes);
    try std.testing.expect(output.finished);
}

test "fuzzy matcher applies blocking composite score and threshold" {
    var reference_csv = try engine.connectors.csv_source.CsvSource.init(
        std.testing.io,
        std.testing.allocator,
        "fixtures/matching/fuzzy-reference.csv",
        .{ .batch_size = 2 },
    );
    defer reference_csv.deinit();
    var candidate_csv = try engine.connectors.csv_source.CsvSource.init(
        std.testing.io,
        std.testing.allocator,
        "fixtures/matching/fuzzy-candidates.csv",
        .{ .batch_size = 2 },
    );
    defer candidate_csv.deinit();
    var reference_ingest = engine.ingestion.ingest_reader.IngestReader.init(
        std.testing.allocator,
        reference_csv.asSource(),
        .{},
    );
    defer reference_ingest.deinit();
    var candidate_ingest = engine.ingestion.ingest_reader.IngestReader.init(
        std.testing.allocator,
        candidate_csv.asSource(),
        .{},
    );
    defer candidate_ingest.deinit();
    var output = engine.matching.match_sink.SamplingSink.init(std.testing.allocator, 10);
    defer output.deinit();
    var matcher = try engine.matching.matcher.PartitionedMatcher.init(
        std.testing.io,
        std.testing.allocator,
        .{
            .matching = .{
                .reference_column = 1,
                .candidate_column = 1,
                .blocking = .{ .prefix = 3 },
                .index_memory_limit = 64 * 1024,
                .scoring = .{ .fuzzy = .{ .max_distance = 3, .threshold = 0.85 } },
            },
            .partition_count = 2,
            .max_value_bytes = 128,
            .temp_prefix = ".zig-cache/test-fuzzy-spill",
        },
        output.asSink(),
    );
    var arena = engine.core.arena_pool.BatchArena.init(std.testing.allocator);
    defer arena.deinit();
    var scratch = engine.execution.allocators.ScratchArena.init(std.testing.allocator);
    defer scratch.deinit();

    const summary = try matcher.run(
        reference_ingest.asReader(),
        candidate_ingest.asReader(),
        &arena,
        &scratch,
    );
    try std.testing.expect(summary.matches >= 2);
    for (output.samples.items) |item| {
        try std.testing.expectEqual(engine.matching.match_result.Method.composite, item.method);
        try std.testing.expect(item.score >= 0.85);
    }
}

test "partitioned matcher spills and removes temporary files" {
    var reference_csv = try engine.connectors.csv_source.CsvSource.init(
        std.testing.io,
        std.testing.allocator,
        "fixtures/matching/reference.csv",
        .{ .batch_size = 2 },
    );
    defer reference_csv.deinit();
    var candidate_csv = try engine.connectors.csv_source.CsvSource.init(
        std.testing.io,
        std.testing.allocator,
        "fixtures/matching/candidates.csv",
        .{ .batch_size = 1 },
    );
    defer candidate_csv.deinit();
    var reference_ingest = engine.ingestion.ingest_reader.IngestReader.init(
        std.testing.allocator,
        reference_csv.asSource(),
        .{},
    );
    defer reference_ingest.deinit();
    var candidate_ingest = engine.ingestion.ingest_reader.IngestReader.init(
        std.testing.allocator,
        candidate_csv.asSource(),
        .{},
    );
    defer candidate_ingest.deinit();
    var output = engine.matching.match_sink.SamplingSink.init(std.testing.allocator, 10);
    defer output.deinit();
    const prefix = ".zig-cache/test-match-spill";
    var matcher = try engine.matching.matcher.PartitionedMatcher.init(
        std.testing.io,
        std.testing.allocator,
        .{
            .matching = .{
                .reference_column = 1,
                .candidate_column = 1,
                .index_memory_limit = 16 * 1024,
            },
            .partition_count = 3,
            .max_value_bytes = 128,
            .temp_prefix = prefix,
        },
        output.asSink(),
    );
    var arena = engine.core.arena_pool.BatchArena.init(std.testing.allocator);
    defer arena.deinit();
    var scratch = engine.execution.allocators.ScratchArena.init(std.testing.allocator);
    defer scratch.deinit();

    const summary = try matcher.run(
        reference_ingest.asReader(),
        candidate_ingest.asReader(),
        &arena,
        &scratch,
    );
    try std.testing.expectEqual(@as(u64, 3), summary.matches);
    try std.testing.expectEqual(@as(u32, 3), summary.partitions_processed);
    try std.testing.expect(summary.spill_bytes > 0);
    try std.testing.expect(summary.peak_index_bytes <= 16 * 1024);
    try std.testing.expect(output.finished);
    try std.testing.expectError(
        error.FileNotFound,
        std.Io.Dir.cwd().openFile(std.testing.io, ".zig-cache/test-match-spill-reference-0.bin", .{}),
    );
}

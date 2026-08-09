const std = @import("std");
const engine = @import("orus_data_engine");

pub fn main(init: std.process.Init) !void {
    const path = "fixtures/customers-2000000.csv";
    var reference_csv = try engine.connectors.csv_source.CsvSource.init(
        init.io,
        init.gpa,
        path,
        .{ .batch_size = 8192 },
    );
    defer reference_csv.deinit();
    var candidate_csv = try engine.connectors.csv_source.CsvSource.init(
        init.io,
        init.gpa,
        path,
        .{ .batch_size = 8192 },
    );
    defer candidate_csv.deinit();
    var reference_ingest = engine.ingestion.ingest_reader.IngestReader.init(
        init.gpa,
        reference_csv.asSource(),
        .{},
    );
    defer reference_ingest.deinit();
    var candidate_ingest = engine.ingestion.ingest_reader.IngestReader.init(
        init.gpa,
        candidate_csv.asSource(),
        .{},
    );
    defer candidate_ingest.deinit();
    var output = engine.matching.match_sink.SamplingSink.init(init.gpa, 0);
    defer output.deinit();
    var matcher = try engine.matching.matcher.PartitionedMatcher.init(
        init.io,
        init.gpa,
        .{
            .matching = .{
                .reference_column = 1,
                .candidate_column = 1,
                .index_memory_limit = 32 * 1024 * 1024,
            },
            .partition_count = 32,
            .max_value_bytes = 128,
            .temp_prefix = ".zig-cache/benchmark-match-spill",
        },
        output.asSink(),
    );
    var arena = engine.core.arena_pool.BatchArena.init(init.gpa);
    defer arena.deinit();
    var scratch = engine.execution.allocators.ScratchArena.init(init.gpa);
    defer scratch.deinit();

    const started = std.Io.Timestamp.now(init.io, .awake);
    const summary = try matcher.run(
        reference_ingest.asReader(),
        candidate_ingest.asReader(),
        &arena,
        &scratch,
    );
    const elapsed = started.durationTo(std.Io.Timestamp.now(init.io, .awake));
    const seconds = @as(f64, @floatFromInt(elapsed.nanoseconds)) / 1_000_000_000;
    std.debug.print(
        "matching reference_rows={d} candidate_rows={d} matches={d} partitions={d} spill_mib={d} peak_index_mib={d} seconds={d:.3} rows_per_second={d:.0}\n",
        .{
            summary.reference_rows,
            summary.candidate_rows,
            summary.matches,
            summary.partitions_processed,
            summary.spill_bytes / (1024 * 1024),
            summary.peak_index_bytes / (1024 * 1024),
            seconds,
            @as(f64, @floatFromInt(summary.reference_rows + summary.candidate_rows)) / seconds,
        },
    );
}

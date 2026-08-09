const std = @import("std");
const engine = @import("orus_data_engine");

pub fn main(init: std.process.Init) !void {
    const input_path = "fixtures/customers-2000000.csv";
    const output_path = ".zig-cache/customers-2000000-benchmark.jsonl";
    defer std.Io.Dir.cwd().deleteFile(init.io, output_path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => std.debug.print("warning: cannot remove JSONL benchmark output: {s}\n", .{@errorName(err)}),
    };

    var csv = try engine.connectors.csv_source.CsvSource.init(
        init.io,
        init.gpa,
        input_path,
        .{ .batch_size = 8192 },
    );
    defer csv.deinit();
    var ingest = engine.ingestion.ingest_reader.IngestReader.init(init.gpa, csv.asSource(), .{});
    defer ingest.deinit();
    var output = try engine.sinks.jsonl_sink.JsonlSink.open(init.io, init.gpa, output_path);
    defer output.deinit();
    var arena = engine.core.arena_pool.BatchArena.init(init.gpa);
    defer arena.deinit();

    const write_started = std.Io.Timestamp.now(init.io, .awake);
    while (try ingest.next(&arena)) |input| {
        try output.write(&input);
        arena.reset();
    }
    try output.finish();
    const write_elapsed = write_started.durationTo(std.Io.Timestamp.now(init.io, .awake));

    var jsonl = try engine.connectors.jsonl_source.JsonlSource.init(
        init.io,
        init.gpa,
        output_path,
        .{ .batch_size = 8192 },
    );
    defer jsonl.deinit();
    var rows_read: u64 = 0;
    const read_started = std.Io.Timestamp.now(init.io, .awake);
    while (try jsonl.nextRaw(&arena)) |input| {
        rows_read += input.row_count;
        arena.reset();
    }
    const read_elapsed = read_started.durationTo(std.Io.Timestamp.now(init.io, .awake));
    const write_seconds = seconds(write_elapsed);
    const read_seconds = seconds(read_elapsed);
    std.debug.print(
        "jsonl rows={d} bytes={d} write_seconds={d:.3} write_rows_per_second={d:.0} read_seconds={d:.3} read_rows_per_second={d:.0}\n",
        .{
            rows_read,
            jsonl.bytes_consumed,
            write_seconds,
            @as(f64, @floatFromInt(output.rows_written)) / write_seconds,
            read_seconds,
            @as(f64, @floatFromInt(rows_read)) / read_seconds,
        },
    );
}

fn seconds(duration: std.Io.Duration) f64 {
    return @as(f64, @floatFromInt(duration.nanoseconds)) / 1_000_000_000;
}

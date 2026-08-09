const std = @import("std");
const engine = @import("orus_data_engine");

pub fn main(init: std.process.Init) !void {
    var allocators = engine.execution.allocators.PipelineAllocators.init(init.gpa);
    defer allocators.deinit();
    var source = try engine.connectors.csv_source.CsvSource.init(
        init.io,
        allocators.run(),
        "fixtures/customers-2000000.csv",
        .{ .batch_size = 8192 },
    );
    defer source.deinit();
    var ingest = engine.ingestion.ingest_reader.IngestReader.init(
        allocators.run(),
        source.asSource(),
        .{},
    );
    defer ingest.deinit();
    var profiler = engine.profiling.profile_reader.ProfileReader.init(
        allocators.run(),
        ingest.asReader(),
    );
    defer profiler.deinit();
    while (try profiler.next(allocators.batches.input())) |_| allocators.batches.input().reset();
    std.debug.print("profiling rows={d} batches={d}\n", .{
        profiler.rows_processed,
        profiler.batches_processed,
    });
}

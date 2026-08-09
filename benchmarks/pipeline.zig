const std = @import("std");
const engine = @import("orus_data_engine");

pub fn main(init: std.process.Init) !void {
    var csv = try engine.connectors.csv_source.CsvSource.init(
        init.io,
        init.gpa,
        "fixtures/customers-2000000.csv",
        .{ .batch_size = 8192 },
    );
    defer csv.deinit();
    var context = try engine.execution.context.ExecutionContext.init(init.gpa, 1, "/tmp");
    defer context.deinit();
    const lowercase = engine.cleaning.transform.StringTransform{
        .id = 1,
        .column_index = 2,
        .operation = .lowercase,
    };
    var output = engine.sinks.null_sink.NullSink{};
    var builder = engine.pipeline.builder.PipelineBuilder.init(init.gpa, csv.asSource());
    defer builder.deinit();
    _ = try builder.withTransform(lowercase.asTransform());
    _ = builder.withSink(output.asSink());
    var pipeline = try builder.build(&context);
    defer pipeline.deinit();

    const started = std.Io.Timestamp.now(init.io, .awake);
    const result = try pipeline.run(&context, init.io);
    const elapsed = started.durationTo(std.Io.Timestamp.now(init.io, .awake));
    const seconds = @as(f64, @floatFromInt(elapsed.nanoseconds)) / 1_000_000_000;
    std.debug.print(
        "pipeline rows={d} batches={d} bytes={d} seconds={d:.3} rows_per_second={d:.0}\n",
        .{
            result.rows_written,
            result.batches_processed,
            result.bytes_read,
            seconds,
            @as(f64, @floatFromInt(result.rows_written)) / seconds,
        },
    );
}

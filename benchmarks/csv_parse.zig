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
    var rows: u64 = 0;
    while (try source.nextRaw(allocators.batches.input())) |input| {
        rows += input.row_count;
        allocators.batches.input().reset();
    }
    std.debug.print("csv_parse rows={d} bytes={d}\n", .{ rows, source.bytes_consumed });
}

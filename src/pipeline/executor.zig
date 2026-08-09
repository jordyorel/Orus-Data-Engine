const context_mod = @import("../execution/context.zig");
const reader_mod = @import("../core/reader.zig");
const sink_mod = @import("../core/sink.zig");
const transform_mod = @import("../cleaning/transform.zig");

pub fn execute(
    final_reader: reader_mod.Reader,
    transforms: []const transform_mod.Transform,
    sink: sink_mod.Sink,
    context: *context_mod.ExecutionContext,
) !void {
    var sink_finished = false;
    errdefer if (!sink_finished) sink.abort();

    while (true) {
        const next_batch = final_reader.next(context.allocators.batches.input()) catch |err| {
            context.error_context.clear();
            try context.error_context.push(.{ .stage = "reader" });
            return err;
        };
        var current = next_batch orelse break;
        context.metrics.observeBatch(&current);

        for (transforms) |operation| {
            const transformed = operation.apply(
                &current,
                context.allocators.batches.output(),
                context.allocators.scratch.allocator(),
            ) catch |err| {
                context.error_context.clear();
                try context.error_context.push(.{
                    .stage = operation.name,
                    .batch_id = current.metadata.batch_id,
                    .row_offset = current.metadata.global_row_offset,
                });
                return err;
            };
            current = transformed;
            context.allocators.batches.swap();
            context.allocators.scratch.reset();
        }

        sink.write(&current) catch |err| {
            context.error_context.clear();
            try context.error_context.push(.{
                .stage = "sink",
                .batch_id = current.metadata.batch_id,
                .row_offset = current.metadata.global_row_offset,
            });
            return err;
        };
        context.metrics.observeWrite(&current);
        context.allocators.batches.input().reset();
        context.allocators.batches.output().reset();
        context.allocators.scratch.reset();
    }

    sink.finish() catch |err| {
        context.error_context.clear();
        try context.error_context.push(.{ .stage = "sink.finish" });
        return err;
    };
    sink_finished = true;
}

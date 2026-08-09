const batch = @import("../core/batch.zig");
const sink_mod = @import("../core/sink.zig");

pub const NullSink = struct {
    rows_written: u64 = 0,
    batches_written: u64 = 0,
    finished: bool = false,
    aborted: bool = false,

    pub fn asSink(self: *NullSink) sink_mod.Sink {
        return .{
            .ptr = self,
            .write_fn = writeOpaque,
            .finish_fn = finishOpaque,
            .abort_fn = abortOpaque,
        };
    }

    fn writeOpaque(ptr: *anyopaque, input: *const batch.Batch) !void {
        const self: *NullSink = @ptrCast(@alignCast(ptr));
        if (self.finished or self.aborted) return error.SinkClosed;
        self.rows_written += input.row_count;
        self.batches_written += 1;
    }

    fn finishOpaque(ptr: *anyopaque) !void {
        const self: *NullSink = @ptrCast(@alignCast(ptr));
        if (self.aborted) return error.SinkAborted;
        self.finished = true;
    }

    fn abortOpaque(ptr: *anyopaque) void {
        const self: *NullSink = @ptrCast(@alignCast(ptr));
        self.aborted = true;
    }
};

test "null sink counts streamed batches" {
    const schema = @import("../core/schema.zig");
    const fields = [_]schema.Field{};
    const empty_schema = schema.Schema{ .fields = &fields, .hash = schema.Schema.computeHash(&fields) };
    const input = batch.Batch{ .schema = &empty_schema, .columns = &.{}, .row_count = 7, .metadata = .{} };
    var output = NullSink{};
    try output.asSink().write(&input);
    try output.asSink().finish();
    try @import("std").testing.expectEqual(@as(u64, 7), output.rows_written);
    try @import("std").testing.expect(output.finished);
}

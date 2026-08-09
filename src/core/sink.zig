const batch = @import("batch.zig");

/// Non-owning dispatch handle. The concrete sink owns its state and resources.
pub const Sink = struct {
    ptr: *anyopaque,
    write_fn: *const fn (*anyopaque, *const batch.Batch) anyerror!void,
    finish_fn: *const fn (*anyopaque) anyerror!void,
    abort_fn: *const fn (*anyopaque) void,

    pub fn write(self: Sink, input: *const batch.Batch) !void {
        return self.write_fn(self.ptr, input);
    }

    pub fn finish(self: Sink) !void {
        return self.finish_fn(self.ptr);
    }

    pub fn abort(self: Sink) void {
        self.abort_fn(self.ptr);
    }
};

test "sink dispatches lifecycle methods" {
    const Probe = struct {
        writes: usize = 0,
        finished: bool = false,
        aborted: bool = false,

        fn write(ptr: *anyopaque, _: *const batch.Batch) !void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.writes += 1;
        }

        fn finish(ptr: *anyopaque) !void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.finished = true;
        }

        fn abort(ptr: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.aborted = true;
        }
    };
    const schema = @import("schema.zig");
    const fields = [_]schema.Field{};
    const empty_schema = schema.Schema{
        .fields = &fields,
        .hash = schema.Schema.computeHash(&fields),
    };
    const empty_batch = batch.Batch{
        .schema = &empty_schema,
        .columns = &.{},
        .row_count = 0,
        .metadata = .{},
    };
    var probe = Probe{};
    const sink = Sink{
        .ptr = &probe,
        .write_fn = Probe.write,
        .finish_fn = Probe.finish,
        .abort_fn = Probe.abort,
    };

    try sink.write(&empty_batch);
    try sink.finish();
    sink.abort();
    try @import("std").testing.expectEqual(@as(usize, 1), probe.writes);
    try @import("std").testing.expect(probe.finished);
    try @import("std").testing.expect(probe.aborted);
}

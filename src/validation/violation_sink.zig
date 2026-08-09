const std = @import("std");
const violation = @import("violation.zig");

pub const ViolationSink = struct {
    ptr: *anyopaque,
    write_fn: *const fn (*anyopaque, []const violation.Violation) anyerror!void,
    finish_fn: *const fn (*anyopaque) anyerror!void,
    abort_fn: *const fn (*anyopaque) void,

    pub fn write(self: ViolationSink, items: []const violation.Violation) !void {
        try self.write_fn(self.ptr, items);
    }

    pub fn finish(self: ViolationSink) !void {
        try self.finish_fn(self.ptr);
    }

    pub fn abort(self: ViolationSink) void {
        self.abort_fn(self.ptr);
    }
};

/// Retains only the first `limit` violations while counting all writes.
pub const SamplingSink = struct {
    allocator: std.mem.Allocator,
    limit: usize,
    samples: std.ArrayList(violation.Violation) = .empty,
    total: u64 = 0,
    finished: bool = false,
    aborted: bool = false,

    pub fn init(allocator: std.mem.Allocator, limit: usize) SamplingSink {
        return .{ .allocator = allocator, .limit = limit };
    }

    pub fn deinit(self: *SamplingSink) void {
        self.samples.deinit(self.allocator);
    }

    pub fn asSink(self: *SamplingSink) ViolationSink {
        return .{ .ptr = self, .write_fn = writeOpaque, .finish_fn = finishOpaque, .abort_fn = abortOpaque };
    }

    pub fn truncated(self: *const SamplingSink) bool {
        return self.total > self.samples.items.len;
    }

    fn writeOpaque(ptr: *anyopaque, items: []const violation.Violation) !void {
        const self: *SamplingSink = @ptrCast(@alignCast(ptr));
        if (self.finished or self.aborted) return error.ViolationSinkClosed;
        self.total += items.len;
        const available = self.limit -| self.samples.items.len;
        const retained = @min(available, items.len);
        try self.samples.appendSlice(self.allocator, items[0..retained]);
    }

    fn finishOpaque(ptr: *anyopaque) !void {
        const self: *SamplingSink = @ptrCast(@alignCast(ptr));
        if (self.aborted) return error.ViolationSinkAborted;
        self.finished = true;
    }

    fn abortOpaque(ptr: *anyopaque) void {
        const self: *SamplingSink = @ptrCast(@alignCast(ptr));
        self.aborted = true;
    }
};

pub const JsonlFileSink = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    atomic: std.Io.File.Atomic,
    destination: []u8,
    writer: std.Io.File.Writer,
    buffer: []u8,
    written: u64 = 0,
    finished: bool = false,
    released: bool = false,
    aborted: bool = false,

    pub fn open(io: std.Io, allocator: std.mem.Allocator, path: []const u8) !JsonlFileSink {
        const destination = try allocator.dupe(u8, path);
        errdefer allocator.free(destination);
        var atomic = try std.Io.Dir.cwd().createFileAtomic(io, destination, .{ .replace = true });
        errdefer atomic.deinit(io);
        const buffer = try allocator.alloc(u8, 64 * 1024);
        errdefer allocator.free(buffer);
        return .{
            .allocator = allocator,
            .io = io,
            .atomic = atomic,
            .destination = destination,
            .writer = atomic.file.writerStreaming(io, buffer),
            .buffer = buffer,
        };
    }

    pub fn deinit(self: *JsonlFileSink) void {
        if (!self.released) self.atomic.deinit(self.io);
        self.allocator.free(self.buffer);
        self.allocator.free(self.destination);
    }

    pub fn asSink(self: *JsonlFileSink) ViolationSink {
        return .{ .ptr = self, .write_fn = writeOpaque, .finish_fn = finishOpaque, .abort_fn = abortOpaque };
    }

    fn writeOpaque(ptr: *anyopaque, items: []const violation.Violation) !void {
        const self: *JsonlFileSink = @ptrCast(@alignCast(ptr));
        if (self.finished or self.aborted) return error.ViolationSinkClosed;
        for (items) |item| {
            var stringify: std.json.Stringify = .{ .writer = &self.writer.interface, .options = .{} };
            try stringify.write(item);
            try self.writer.interface.writeByte('\n');
            self.written += 1;
        }
    }

    fn finishOpaque(ptr: *anyopaque) !void {
        const self: *JsonlFileSink = @ptrCast(@alignCast(ptr));
        if (self.aborted) return error.ViolationSinkAborted;
        if (self.finished) return;
        try self.writer.interface.flush();
        try self.atomic.file.sync(self.io);
        try self.atomic.replace(self.io);
        self.atomic.deinit(self.io);
        self.released = true;
        self.finished = true;
    }

    fn abortOpaque(ptr: *anyopaque) void {
        const self: *JsonlFileSink = @ptrCast(@alignCast(ptr));
        if (!self.released) {
            self.atomic.deinit(self.io);
            self.released = true;
        }
        self.aborted = true;
    }
};

test "sampling sink bounds retained violations" {
    var sink = SamplingSink.init(std.testing.allocator, 1);
    defer sink.deinit();
    const items = [_]violation.Violation{
        .{ .row_id = .{ .source_id = 0, .batch_id = 0, .row_in_batch = 0, .global_offset = 0 }, .column_index = 0, .rule_id = 1, .code = .required_missing },
        .{ .row_id = .{ .source_id = 0, .batch_id = 0, .row_in_batch = 1, .global_offset = 1 }, .column_index = 0, .rule_id = 1, .code = .required_missing },
    };
    try sink.asSink().write(&items);
    try std.testing.expectEqual(@as(usize, 1), sink.samples.items.len);
    try std.testing.expect(sink.truncated());
}

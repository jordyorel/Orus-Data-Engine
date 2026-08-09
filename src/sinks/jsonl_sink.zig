const std = @import("std");
const batch = @import("../core/batch.zig");
const sink_mod = @import("../core/sink.zig");

pub const JsonlSink = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    atomic: std.Io.File.Atomic,
    destination: []u8,
    writer: std.Io.File.Writer,
    buffer: []u8,
    rows_written: u64 = 0,
    finished: bool = false,
    released: bool = false,
    aborted: bool = false,

    pub fn open(io: std.Io, allocator: std.mem.Allocator, path: []const u8) !JsonlSink {
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

    pub fn deinit(self: *JsonlSink) void {
        if (!self.released) self.atomic.deinit(self.io);
        self.allocator.free(self.buffer);
        self.allocator.free(self.destination);
    }

    pub fn asSink(self: *JsonlSink) sink_mod.Sink {
        return .{ .ptr = self, .write_fn = writeOpaque, .finish_fn = finishOpaque, .abort_fn = abortOpaque };
    }

    pub fn write(self: *JsonlSink, input: *const batch.Batch) !void {
        if (self.finished or self.aborted) return error.SinkClosed;
        for (0..input.row_count) |row| {
            try self.writer.interface.writeByte('{');
            for (input.schema.fields, 0..) |field, index| {
                if (index != 0) try self.writer.interface.writeByte(',');
                try writeJsonString(&self.writer.interface, field.name);
                try self.writer.interface.writeByte(':');
                const column = input.column(index);
                if (column.isNull(row)) try self.writer.interface.writeAll("null") else try writeValue(&self.writer.interface, column, row);
            }
            try self.writer.interface.writeAll("}\n");
            self.rows_written += 1;
        }
    }

    pub fn finish(self: *JsonlSink) !void {
        if (!self.finished) {
            try self.writer.interface.flush();
            try self.atomic.file.sync(self.io);
            try self.atomic.replace(self.io);
            self.atomic.deinit(self.io);
            self.released = true;
            self.finished = true;
        }
    }

    fn writeOpaque(ptr: *anyopaque, input: *const batch.Batch) !void {
        try (@as(*JsonlSink, @ptrCast(@alignCast(ptr)))).write(input);
    }
    fn finishOpaque(ptr: *anyopaque) !void {
        try (@as(*JsonlSink, @ptrCast(@alignCast(ptr)))).finish();
    }
    fn abortOpaque(ptr: *anyopaque) void {
        const self: *JsonlSink = @ptrCast(@alignCast(ptr));
        if (!self.released) {
            self.atomic.deinit(self.io);
            self.released = true;
        }
        self.aborted = true;
    }
};

fn writeValue(writer: *std.Io.Writer, column: *const @import("../core/column.zig").Column, row: usize) !void {
    var decimal_buffer: [80]u8 = undefined;
    switch (column.data) {
        .i64 => |items| try writer.print("{d}", .{items[row]}),
        .f64 => |items| {
            if (!std.math.isFinite(items[row])) return error.NonFiniteJsonNumber;
            try writer.print("{d}", .{items[row]});
        },
        .decimal => |items| try writeJsonString(writer, try items[row].formatInto(&decimal_buffer)),
        .boolean => |items| try writer.writeAll(if (items.isSet(row)) "true" else "false"),
        .string => |items| try writeJsonString(writer, items.get(row)),
        .date => |items| try writer.print("{d}", .{items[row]}),
        .datetime => |items| try writer.print("{d}", .{items[row]}),
    }
}

fn writeJsonString(writer: *std.Io.Writer, value: []const u8) !void {
    var stringify: std.json.Stringify = .{ .writer = writer, .options = .{} };
    try stringify.write(value);
}

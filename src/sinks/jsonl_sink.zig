const std = @import("std");
const batch = @import("../core/batch.zig");
const sink_mod = @import("../core/sink.zig");
const csv_sink = @import("csv_sink.zig");

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
            try writeRowObject(&self.writer.interface, input, row);
            try self.writer.interface.writeByte('\n');
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

pub fn writeRowObject(writer: *std.Io.Writer, input: *const batch.Batch, row: usize) !void {
    if (row >= input.row_count) return error.RowOutOfBounds;
    try writer.writeByte('{');
    for (input.schema.fields, 0..) |field, index| {
        if (index != 0) try writer.writeByte(',');
        try writeJsonString(writer, field.name);
        try writer.writeByte(':');
        const column = input.column(index);
        if (column.isNull(row)) try writer.writeAll("null") else try writeValue(writer, column, row);
    }
    try writer.writeByte('}');
}

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
        .date => |items| try writeJsonString(writer, try csv_sink.formatDate(items[row], &decimal_buffer)),
        .datetime => |items| {
            const days: i32 = @intCast(@divFloor(items[row], 86_400));
            const seconds = @mod(items[row], 86_400);
            const date = try csv_sink.formatDate(days, &decimal_buffer);
            var datetime_buffer: [32]u8 = undefined;
            const formatted = try std.fmt.bufPrint(&datetime_buffer, "{s}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
                date,
                @divFloor(seconds, 3600),
                @divFloor(@mod(seconds, 3600), 60),
                @mod(seconds, 60),
            });
            try writeJsonString(writer, formatted);
        },
    }
}

fn writeJsonString(writer: *std.Io.Writer, value: []const u8) !void {
    var stringify: std.json.Stringify = .{ .writer = writer, .options = .{} };
    try stringify.write(value);
}

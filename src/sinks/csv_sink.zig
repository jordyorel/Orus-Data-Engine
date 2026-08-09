const std = @import("std");
const batch = @import("../core/batch.zig");
const sink = @import("../core/sink.zig");

pub const CsvSink = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    atomic: std.Io.File.Atomic,
    destination: []u8,
    writer: std.Io.File.Writer,
    buffer: []u8,
    header_written: bool = false,
    finished: bool = false,
    released: bool = false,
    aborted: bool = false,
    rows_written: u64 = 0,

    pub fn open(io: std.Io, allocator: std.mem.Allocator, path: []const u8) !CsvSink {
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

    pub fn deinit(self: *CsvSink) void {
        if (!self.released) self.atomic.deinit(self.io);
        self.allocator.free(self.buffer);
        self.allocator.free(self.destination);
    }

    pub fn asSink(self: *CsvSink) sink.Sink {
        return .{ .ptr = self, .write_fn = writeOpaque, .finish_fn = finishOpaque, .abort_fn = abortOpaque };
    }

    pub fn write(self: *CsvSink, input: *const batch.Batch) !void {
        if (self.finished or self.aborted) return error.SinkClosed;
        if (!self.header_written) {
            for (input.schema.fields, 0..) |field, index| {
                if (index != 0) try self.writer.interface.writeByte(',');
                try writeString(&self.writer.interface, field.name);
            }
            try self.writer.interface.writeByte('\n');
            self.header_written = true;
        }
        for (0..input.row_count) |row| {
            for (input.columns, 0..) |*column, index| {
                if (index != 0) try self.writer.interface.writeByte(',');
                if (!column.isNull(row)) try writeValue(&self.writer.interface, column, row);
            }
            try self.writer.interface.writeByte('\n');
            self.rows_written += 1;
        }
    }

    pub fn finish(self: *CsvSink) !void {
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
        const self: *CsvSink = @ptrCast(@alignCast(ptr));
        try self.write(input);
    }

    fn finishOpaque(ptr: *anyopaque) !void {
        const self: *CsvSink = @ptrCast(@alignCast(ptr));
        try self.finish();
    }

    fn abortOpaque(ptr: *anyopaque) void {
        const self: *CsvSink = @ptrCast(@alignCast(ptr));
        if (!self.released) {
            self.atomic.deinit(self.io);
            self.released = true;
        }
        self.aborted = true;
    }
};

fn writeValue(writer: *std.Io.Writer, column: *const @import("../core/column.zig").Column, row: usize) !void {
    var buffer: [80]u8 = undefined;
    switch (column.data) {
        .i64 => |items| try writer.print("{d}", .{items[row]}),
        .f64 => |items| try writer.print("{d}", .{items[row]}),
        .decimal => |items| try writer.writeAll(try items[row].formatInto(&buffer)),
        .boolean => |items| try writer.writeAll(if (items.isSet(row)) "true" else "false"),
        .string => |items| try writeString(writer, items.get(row)),
        .date => |items| try writer.writeAll(try formatDate(items[row], &buffer)),
        .datetime => |items| {
            const days: i32 = @intCast(@divFloor(items[row], 86_400));
            const seconds = @mod(items[row], 86_400);
            const date = try formatDate(days, &buffer);
            try writer.print("{s}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
                date,
                @divFloor(seconds, 3600),
                @divFloor(@mod(seconds, 3600), 60),
                @mod(seconds, 60),
            });
        },
    }
}

fn formatDate(days_since_epoch: i32, buffer: []u8) ![]const u8 {
    const days: i64 = @as(i64, days_since_epoch) + 719468;
    const era = @divFloor(days, 146097);
    const day_of_era = days - era * 146097;
    const year_of_era = @divFloor(
        day_of_era - @divFloor(day_of_era, 1460) + @divFloor(day_of_era, 36524) -
            @divFloor(day_of_era, 146096),
        365,
    );
    var year = year_of_era + era * 400;
    const day_of_year = day_of_era -
        (365 * year_of_era + @divFloor(year_of_era, 4) - @divFloor(year_of_era, 100));
    const month_prime = @divFloor(5 * day_of_year + 2, 153);
    const day = day_of_year - @divFloor(153 * month_prime + 2, 5) + 1;
    const month = month_prime + (if (month_prime < 10) @as(i64, 3) else -9);
    year += @intFromBool(month <= 2);
    if (year < 0 or year > 9999) return error.DateOutOfRange;
    return std.fmt.bufPrint(buffer, "{d:0>4}-{d:0>2}-{d:0>2}", .{
        @as(u16, @intCast(year)),
        @as(u8, @intCast(month)),
        @as(u8, @intCast(day)),
    });
}

fn writeString(writer: *std.Io.Writer, text: []const u8) !void {
    const quoted = std.mem.indexOfAny(u8, text, ",\n\r\"") != null;
    if (!quoted) return writer.writeAll(text);
    try writer.writeByte('"');
    for (text) |byte| {
        if (byte == '"') try writer.writeByte('"');
        try writer.writeByte(byte);
    }
    try writer.writeByte('"');
}

test "date formatting is canonical and round-trippable" {
    var buffer: [16]u8 = undefined;
    try std.testing.expectEqualStrings("1970-01-01", try formatDate(0, &buffer));
    try std.testing.expectEqualStrings("2024-02-29", try formatDate(19782, &buffer));
}

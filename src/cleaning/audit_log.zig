const std = @import("std");
const provenance = @import("provenance.zig");

pub const Summary = struct { entries_written: u64 };

pub const AuditLog = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    atomic: std.Io.File.Atomic,
    destination: []u8,
    writer: std.Io.File.Writer,
    buffer: []u8,
    entries_written: u64 = 0,
    finished: bool = false,
    released: bool = false,

    pub fn open(
        io: std.Io,
        allocator: std.mem.Allocator,
        path: []const u8,
    ) !AuditLog {
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

    pub fn record(self: *AuditLog, entry: *const provenance.Entry) !void {
        if (self.finished) return error.AuditLogFinished;
        var stringify: std.json.Stringify = .{ .writer = &self.writer.interface, .options = .{} };
        try stringify.write(entry);
        try self.writer.interface.writeByte('\n');
        self.entries_written += 1;
    }

    pub fn finish(self: *AuditLog) !Summary {
        if (!self.finished) {
            try self.writer.interface.flush();
            try self.atomic.file.sync(self.io);
            try self.atomic.replace(self.io);
            self.atomic.deinit(self.io);
            self.released = true;
            self.finished = true;
        }
        return .{ .entries_written = self.entries_written };
    }

    pub fn deinit(self: *AuditLog) void {
        if (!self.released) self.atomic.deinit(self.io);
        self.allocator.free(self.buffer);
        self.allocator.free(self.destination);
    }
};

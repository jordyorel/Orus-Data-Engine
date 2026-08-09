const std = @import("std");

pub const StringColumn = struct {
    offsets: []const u32,
    data: []const u8,

    /// Returns a view into batch-owned memory.
    pub fn get(self: *const StringColumn, index: usize) []const u8 {
        std.debug.assert(index + 1 < self.offsets.len);
        return self.data[self.offsets[index]..self.offsets[index + 1]];
    }

    pub fn len(self: *const StringColumn) usize {
        return self.offsets.len - 1;
    }
};

pub const Builder = struct {
    allocator: std.mem.Allocator,
    offsets: std.ArrayList(u32) = .empty,
    data: std.ArrayList(u8) = .empty,

    pub fn init(allocator: std.mem.Allocator) !Builder {
        var builder = Builder{ .allocator = allocator };
        try builder.offsets.append(allocator, 0);
        return builder;
    }

    pub fn append(self: *Builder, value: []const u8) !void {
        const end = std.math.cast(u32, self.data.items.len + value.len) orelse
            return error.ColumnTooLarge;
        try self.data.appendSlice(self.allocator, value);
        try self.offsets.append(self.allocator, end);
    }

    pub fn appendNull(self: *Builder) !void {
        try self.offsets.append(self.allocator, self.offsets.items[self.offsets.items.len - 1]);
    }

    pub fn len(self: *const Builder) usize {
        return self.offsets.items.len - 1;
    }

    pub fn finish(self: *Builder) !StringColumn {
        return .{
            .offsets = try self.offsets.toOwnedSlice(self.allocator),
            .data = try self.data.toOwnedSlice(self.allocator),
        };
    }
};

test "string builder produces contiguous immutable storage" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var builder = try Builder.init(arena.allocator());
    try builder.append("MTN");
    try builder.appendNull();
    try builder.append("");
    const column = try builder.finish();

    try std.testing.expectEqual(@as(usize, 3), column.len());
    try std.testing.expectEqualStrings("MTN", column.get(0));
    try std.testing.expectEqualStrings("", column.get(1));
    try std.testing.expectEqualStrings("", column.get(2));
}

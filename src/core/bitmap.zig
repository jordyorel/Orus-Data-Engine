const std = @import("std");

pub const Bitmap = struct {
    words: []const u64,
    len: usize,

    pub fn isSet(self: *const Bitmap, index: usize) bool {
        std.debug.assert(index < self.len);
        return self.words[index / 64] & (@as(u64, 1) << @intCast(index % 64)) != 0;
    }

    pub fn countSet(self: *const Bitmap) usize {
        var count: usize = 0;
        for (self.words) |word| count += @popCount(word);
        return count;
    }
};

pub const NullBitmap = Bitmap;
pub const BitVector = Bitmap;

/// Mutable bitmap construction state. Its allocations belong to the supplied
/// arena and become invalid when that arena is reset.
pub const Builder = struct {
    allocator: std.mem.Allocator,
    words: std.ArrayList(u64) = .empty,
    len: usize = 0,

    pub fn init(allocator: std.mem.Allocator) Builder {
        return .{ .allocator = allocator };
    }

    pub fn append(self: *Builder, set: bool) !void {
        if (self.len % 64 == 0) try self.words.append(self.allocator, 0);
        if (set) {
            self.words.items[self.len / 64] |= @as(u64, 1) << @intCast(self.len % 64);
        }
        self.len += 1;
    }

    pub fn finish(self: *Builder) !Bitmap {
        return .{
            .words = try self.words.toOwnedSlice(self.allocator),
            .len = self.len,
        };
    }
};

test "bitmap tracks and counts bits across word boundaries" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var builder = Builder.init(arena.allocator());

    for (0..70) |index| try builder.append(index == 1 or index == 69);
    const bitmap = try builder.finish();

    try std.testing.expectEqual(@as(usize, 70), bitmap.len);
    try std.testing.expect(bitmap.isSet(1));
    try std.testing.expect(bitmap.isSet(69));
    try std.testing.expect(!bitmap.isSet(68));
    try std.testing.expectEqual(@as(usize, 2), bitmap.countSet());
}

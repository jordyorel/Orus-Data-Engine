const std = @import("std");

pub const SourceIdentity = struct {
    id: u128 = 0,
    version: u64 = 0,
    content_hash: [32]u8 = [_]u8{0} ** 32,
    uri: []const u8,
};

pub fn fileVersion(uri: []const u8, stat: std.Io.File.Stat) u64 {
    var hash = std.hash.XxHash3.init(0);
    updateSlice(&hash, uri);
    updateInt(&hash, stat.size);
    updateInt(&hash, stat.mtime.nanoseconds);
    updateInt(&hash, stat.ctime.nanoseconds);
    return hash.final();
}

fn updateSlice(hash: *std.hash.XxHash3, value: []const u8) void {
    updateInt(hash, @as(u64, @intCast(value.len)));
    hash.update(value);
}

fn updateInt(hash: *std.hash.XxHash3, value: anytype) void {
    const T = @TypeOf(value);
    var bytes: [@divExact(@bitSizeOf(T), 8)]u8 = undefined;
    std.mem.writeInt(T, &bytes, value, .little);
    hash.update(&bytes);
}

test "file version changes with source metadata" {
    const Stat = std.Io.File.Stat;
    const base = Stat{
        .inode = 0,
        .nlink = 1,
        .size = 10,
        .permissions = .default_file,
        .kind = .file,
        .atime = null,
        .mtime = .zero,
        .ctime = .zero,
        .block_size = 1,
    };
    var changed = base;
    changed.size = 11;
    try std.testing.expect(fileVersion("data.csv", base) != fileVersion("data.csv", changed));
}

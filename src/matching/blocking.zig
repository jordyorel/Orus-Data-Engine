const std = @import("std");

pub const Strategy = union(enum) {
    exact_normalized,
    prefix: usize,
    token_prefix: usize,
};

pub fn key(normalized: []const u8, strategy: Strategy) ![]const u8 {
    return switch (strategy) {
        .exact_normalized => normalized,
        .prefix => |length| blk: {
            if (length == 0) return error.InvalidBlockingPrefix;
            break :blk normalized[0..@min(length, normalized.len)];
        },
        .token_prefix => |length| blk: {
            if (length == 0) return error.InvalidBlockingPrefix;
            const token_end = std.mem.indexOfScalar(u8, normalized, ' ') orelse normalized.len;
            break :blk normalized[0..@min(length, token_end)];
        },
    };
}

test "blocking creates bounded borrowed keys" {
    try std.testing.expectEqualStrings("mtn", try key("mtn congo", .{ .prefix = 3 }));
    try std.testing.expectEqualStrings("mtn", try key("mtn congo", .{ .token_prefix = 8 }));
    try std.testing.expectError(error.InvalidBlockingPrefix, key("mtn", .{ .prefix = 0 }));
}

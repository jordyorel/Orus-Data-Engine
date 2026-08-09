const std = @import("std");

pub const ExactMatchKey = struct {
    hash: u64,
    normalized_value: []const u8,

    pub fn init(normalized_value: []const u8) ExactMatchKey {
        return .{
            .hash = std.hash.Wyhash.hash(0, normalized_value),
            .normalized_value = normalized_value,
        };
    }
};

pub fn matches(left: ExactMatchKey, right: ExactMatchKey) bool {
    return left.hash == right.hash and
        std.mem.eql(u8, left.normalized_value, right.normalized_value);
}

test "exact matching verifies bytes after a hash collision" {
    const left = ExactMatchKey{ .hash = 42, .normalized_value = "alice" };
    const collision = ExactMatchKey{ .hash = 42, .normalized_value = "bob" };
    const equal = ExactMatchKey{ .hash = 42, .normalized_value = "alice" };
    try std.testing.expect(!matches(left, collision));
    try std.testing.expect(matches(left, equal));
}

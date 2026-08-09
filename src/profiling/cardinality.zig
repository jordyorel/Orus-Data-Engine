const std = @import("std");
const hyperloglog = @import("hyperloglog.zig");

pub const switch_threshold: usize = 10_000;

pub const Mode = enum {
    exact,
    approximate,
};

pub const HashVersion = enum(u8) {
    xxh3_v1 = 1,
};

pub const AdaptiveCardinality = struct {
    allocator: std.mem.Allocator,
    mode: Mode = .exact,
    exact_set: std.AutoHashMap(u64, void),
    hll: hyperloglog.HyperLogLog = .{},
    hash_version: HashVersion = .xxh3_v1,

    pub fn init(allocator: std.mem.Allocator) AdaptiveCardinality {
        return .{ .allocator = allocator, .exact_set = std.AutoHashMap(u64, void).init(allocator) };
    }

    pub fn deinit(self: *AdaptiveCardinality) void {
        self.exact_set.deinit();
    }

    pub fn insert(self: *AdaptiveCardinality, hash: u64) !void {
        if (self.mode == .approximate) {
            self.hll.insert(hash);
            return;
        }
        try self.exact_set.put(hash, {});
        if (self.exact_set.count() <= switch_threshold) return;
        var iterator = self.exact_set.keyIterator();
        while (iterator.next()) |item| self.hll.insert(item.*);
        self.exact_set.clearAndFree();
        self.mode = .approximate;
    }

    pub fn distinctCount(self: *const AdaptiveCardinality) usize {
        return switch (self.mode) {
            .exact => self.exact_set.count(),
            .approximate => self.hll.estimate(),
        };
    }
};

pub fn stableHash(bytes: []const u8) u64 {
    return std.hash.XxHash3.hash(0, bytes);
}

test "cardinality switches from exact to approximate" {
    var cardinality = AdaptiveCardinality.init(std.testing.allocator);
    defer cardinality.deinit();
    for (0..switch_threshold + 1) |item| try cardinality.insert(stableHash(std.mem.asBytes(&item)));
    try std.testing.expectEqual(Mode.approximate, cardinality.mode);
    try std.testing.expect(cardinality.distinctCount() > 9_500);
}

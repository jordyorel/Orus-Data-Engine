const std = @import("std");

pub const LengthStats = struct {
    count: u64 = 0,
    min: usize = std.math.maxInt(usize),
    max: usize = 0,
    mean: f64 = 0,

    pub fn updateValue(self: *LengthStats, length: usize) void {
        self.count += 1;
        self.min = @min(self.min, length);
        self.max = @max(self.max, length);
        self.mean += (@as(f64, @floatFromInt(length)) - self.mean) /
            @as(f64, @floatFromInt(self.count));
    }
};

test "length stats use an online mean" {
    var stats = LengthStats{};
    stats.updateValue(2);
    stats.updateValue(4);
    try std.testing.expectEqual(@as(usize, 2), stats.min);
    try std.testing.expectEqual(@as(usize, 4), stats.max);
    try std.testing.expectEqual(@as(f64, 3), stats.mean);
}

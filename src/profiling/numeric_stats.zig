const std = @import("std");
const decimal = @import("../core/decimal.zig");

pub const NumericStats = struct {
    count: u64 = 0,
    min: f64 = std.math.inf(f64),
    max: f64 = -std.math.inf(f64),
    mean: f64 = 0,
    m2: f64 = 0,

    pub fn updateValue(self: *NumericStats, item: f64) void {
        self.count += 1;
        self.min = @min(self.min, item);
        self.max = @max(self.max, item);
        const delta = item - self.mean;
        self.mean += delta / @as(f64, @floatFromInt(self.count));
        self.m2 += delta * (item - self.mean);
    }

    pub fn variance(self: NumericStats) ?f64 {
        if (self.count < 2) return null;
        return self.m2 / @as(f64, @floatFromInt(self.count - 1));
    }
};

pub const DecimalStats = struct {
    count: u64 = 0,
    min: decimal.Decimal128 = .{ .coefficient = 0, .scale = 0 },
    max: decimal.Decimal128 = .{ .coefficient = 0, .scale = 0 },

    pub fn updateValue(self: *DecimalStats, item: decimal.Decimal128) void {
        if (self.count == 0 or decimal.Decimal128.compare(item, self.min) == .lt) self.min = item;
        if (self.count == 0 or decimal.Decimal128.compare(item, self.max) == .gt) self.max = item;
        self.count += 1;
    }
};

test "numeric stats use Welford variance" {
    var stats = NumericStats{};
    stats.updateValue(1);
    stats.updateValue(2);
    stats.updateValue(3);
    try std.testing.expectEqual(@as(f64, 2), stats.mean);
    try std.testing.expectEqual(@as(?f64, 1), stats.variance());
}

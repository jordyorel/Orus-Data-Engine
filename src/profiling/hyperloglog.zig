const std = @import("std");

pub const precision: usize = 14;
pub const register_count: usize = 1 << precision;

pub const HyperLogLog = struct {
    registers: [register_count]u8 = @splat(0),

    pub fn insert(self: *HyperLogLog, hash: u64) void {
        const index: usize = @intCast(hash & (register_count - 1));
        const remaining = hash >> @intCast(precision);
        const leading: usize = @clz(remaining);
        const rank: u8 = @intCast(@min(leading - precision + 1, 64 - precision + 1));
        self.registers[index] = @max(self.registers[index], rank);
    }

    pub fn estimate(self: *const HyperLogLog) usize {
        var sum: f64 = 0;
        var zeroes: usize = 0;
        for (self.registers) |register| {
            sum += std.math.pow(f64, 2, -@as(f64, @floatFromInt(register)));
            if (register == 0) zeroes += 1;
        }
        const m: f64 = register_count;
        var estimate_value = 0.7213 / (1 + 1.079 / m) * m * m / sum;
        if (estimate_value <= 2.5 * m and zeroes != 0) {
            estimate_value = m * @log(m / @as(f64, @floatFromInt(zeroes)));
        }
        return @intFromFloat(@round(estimate_value));
    }
};

test "hyperloglog estimates cardinality within five percent" {
    var hll = HyperLogLog{};
    for (0..100_000) |item| hll.insert(std.hash.XxHash3.hash(0, std.mem.asBytes(&item)));
    const estimate = hll.estimate();
    try std.testing.expect(estimate > 95_000 and estimate < 105_000);
}

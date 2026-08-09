const decimal = @import("../core/decimal.zig");

pub fn parseAmount(text: []const u8, decimal_separator: u8, target_scale: u8) !decimal.Decimal128 {
    const parsed = try decimal.Decimal128.parse(text, .{ .decimal_separator = decimal_separator });
    return parsed.rescale(target_scale);
}

test "currency amount normalization stays exact" {
    const result = try parseAmount("10,25", ',', 2);
    try @import("std").testing.expectEqual(@as(i128, 1025), result.coefficient);
}

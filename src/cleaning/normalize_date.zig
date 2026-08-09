const std = @import("std");

pub fn parseIso(text: []const u8) !i32 {
    if (text.len != 10 or text[4] != '-' or text[7] != '-') return error.InvalidDate;
    const year = try std.fmt.parseInt(i32, text[0..4], 10);
    const month = try std.fmt.parseInt(u8, text[5..7], 10);
    const day = try std.fmt.parseInt(u8, text[8..10], 10);
    if (month == 0 or month > 12 or day == 0) return error.InvalidDate;
    const leap = @mod(year, 4) == 0 and (@mod(year, 100) != 0 or @mod(year, 400) == 0);
    const lengths = [_]u8{ 31, if (leap) 29 else 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
    if (day > lengths[month - 1]) return error.InvalidDate;
    var adjusted_year: i64 = year;
    adjusted_year -= @intFromBool(month <= 2);
    const era = @divFloor(adjusted_year, 400);
    const year_of_era = adjusted_year - era * 400;
    const shifted_month = @as(i64, month) + (if (month > 2) @as(i64, -3) else 9);
    const day_of_year = @divFloor(153 * shifted_month + 2, 5) + day - 1;
    return @intCast(era * 146097 + year_of_era * 365 + @divFloor(year_of_era, 4) -
        @divFloor(year_of_era, 100) + day_of_year - 719468);
}

test "ISO dates normalize to epoch days" {
    try std.testing.expectEqual(@as(i32, 0), try parseIso("1970-01-01"));
    try std.testing.expectError(error.InvalidDate, parseIso("2023-02-29"));
}

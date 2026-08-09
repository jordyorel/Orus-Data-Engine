const std = @import("std");

pub const ParseOptions = struct {
    decimal_separator: u8 = '.',
    allow_plus_sign: bool = true,
    max_scale: u8 = 38,
};

pub const Decimal128 = struct {
    coefficient: i128,
    scale: u8,

    pub fn parse(raw: []const u8, options: ParseOptions) !Decimal128 {
        if (raw.len == 0) return error.EmptyDecimal;
        var index: usize = 0;
        var negative = false;
        if (raw[index] == '-' or raw[index] == '+') {
            negative = raw[index] == '-';
            if (!negative and !options.allow_plus_sign) return error.PlusSignNotAllowed;
            index += 1;
            if (index == raw.len) return error.MissingDigits;
        }

        var coefficient_magnitude: u128 = 0;
        var scale: u8 = 0;
        var digit_count: usize = 0;
        var separator_seen = false;
        const limit: u128 = if (negative)
            @as(u128, @intCast(std.math.maxInt(i128))) + 1
        else
            @intCast(std.math.maxInt(i128));

        while (index < raw.len) : (index += 1) {
            const byte = raw[index];
            if (byte == options.decimal_separator) {
                if (separator_seen) return error.MultipleDecimalSeparators;
                separator_seen = true;
                continue;
            }
            if (byte < '0' or byte > '9') return error.InvalidDecimalCharacter;
            const digit: u8 = byte - '0';
            if (coefficient_magnitude > (limit - digit) / 10) return error.DecimalOverflow;
            coefficient_magnitude = coefficient_magnitude * 10 + digit;
            digit_count += 1;
            if (separator_seen) {
                if (scale == options.max_scale) return error.ScaleTooLarge;
                scale += 1;
            }
        }
        if (digit_count == 0) return error.MissingDigits;

        const coefficient = if (!negative)
            @as(i128, @intCast(coefficient_magnitude))
        else if (coefficient_magnitude == @as(u128, @intCast(std.math.maxInt(i128))) + 1)
            std.math.minInt(i128)
        else
            -@as(i128, @intCast(coefficient_magnitude));
        return .{ .coefficient = coefficient, .scale = scale };
    }

    pub fn compare(left: Decimal128, right: Decimal128) std.math.Order {
        if (left.coefficient < 0 and right.coefficient >= 0) return .lt;
        if (left.coefficient >= 0 and right.coefficient < 0) return .gt;
        const magnitude_order = compareMagnitude(left, right);
        if (left.coefficient >= 0) return magnitude_order;
        return switch (magnitude_order) {
            .lt => .gt,
            .eq => .eq,
            .gt => .lt,
        };
    }

    pub fn rescale(self: Decimal128, target_scale: u8) !Decimal128 {
        if (target_scale == self.scale) return self;
        if (target_scale > 38) return error.ScaleTooLarge;
        const difference = if (target_scale > self.scale)
            target_scale - self.scale
        else
            self.scale - target_scale;
        const factor = try powerOfTen(difference);

        if (target_scale > self.scale) {
            const result = @mulWithOverflow(self.coefficient, factor);
            if (result[1] != 0) return error.DecimalOverflow;
            return .{ .coefficient = result[0], .scale = target_scale };
        }
        if (@rem(self.coefficient, factor) != 0) return error.InexactRescale;
        return .{
            .coefficient = @divExact(self.coefficient, factor),
            .scale = target_scale,
        };
    }

    /// Caller owns the returned bytes.
    pub fn toString(self: Decimal128, allocator: std.mem.Allocator) ![]u8 {
        var buffer: [80]u8 = undefined;
        return allocator.dupe(u8, try self.formatInto(&buffer));
    }

    pub fn formatInto(self: Decimal128, output: []u8) ![]const u8 {
        var digits_buffer: [39]u8 = undefined;
        const digits = writeMagnitudeDigits(magnitude(self.coefficient), &digits_buffer);
        const negative_len: usize = @intFromBool(self.coefficient < 0);
        const integer_digits = if (digits.len > self.scale) digits.len - self.scale else 1;
        const fraction_len: usize = if (self.scale == 0) 0 else 1 + self.scale;
        const required = negative_len + integer_digits + fraction_len;
        if (output.len < required) return error.OutputTooSmall;
        const result = output[0..required];

        var output_index: usize = 0;
        if (self.coefficient < 0) {
            result[output_index] = '-';
            output_index += 1;
        }
        if (self.scale == 0) {
            @memcpy(result[output_index..], digits);
            return result;
        }
        if (digits.len > self.scale) {
            const split = digits.len - self.scale;
            @memcpy(result[output_index .. output_index + split], digits[0..split]);
            output_index += split;
            result[output_index] = '.';
            output_index += 1;
            @memcpy(result[output_index..], digits[split..]);
        } else {
            result[output_index] = '0';
            output_index += 1;
            result[output_index] = '.';
            output_index += 1;
            const zero_count = self.scale - digits.len;
            @memset(result[output_index .. output_index + zero_count], '0');
            output_index += zero_count;
            @memcpy(result[output_index..], digits);
        }
        return result;
    }
};

fn powerOfTen(exponent: u8) !i128 {
    var result: i128 = 1;
    for (0..exponent) |_| {
        const multiplied = @mulWithOverflow(result, 10);
        if (multiplied[1] != 0) return error.DecimalOverflow;
        result = multiplied[0];
    }
    return result;
}

fn magnitude(value: i128) u128 {
    if (value >= 0) return @intCast(value);
    return @as(u128, @intCast(-(value + 1))) + 1;
}

fn writeMagnitudeDigits(value: u128, buffer: *[39]u8) []const u8 {
    var remaining = value;
    var index = buffer.len;
    if (remaining == 0) {
        index -= 1;
        buffer[index] = '0';
    } else {
        while (remaining != 0) {
            index -= 1;
            buffer[index] = @intCast('0' + remaining % 10);
            remaining /= 10;
        }
    }
    return buffer[index..];
}

fn compareMagnitude(left: Decimal128, right: Decimal128) std.math.Order {
    var left_buffer: [39]u8 = undefined;
    var right_buffer: [39]u8 = undefined;
    const left_digits = writeMagnitudeDigits(magnitude(left.coefficient), &left_buffer);
    const right_digits = writeMagnitudeDigits(magnitude(right.coefficient), &right_buffer);
    const left_integer_digits: i16 = @as(i16, @intCast(left_digits.len)) - left.scale;
    const right_integer_digits: i16 = @as(i16, @intCast(right_digits.len)) - right.scale;
    if (left_integer_digits < right_integer_digits) return .lt;
    if (left_integer_digits > right_integer_digits) return .gt;

    const comparison_len = @max(left_digits.len, right_digits.len);
    for (0..comparison_len) |index| {
        const left_digit = if (index < left_digits.len) left_digits[index] else '0';
        const right_digit = if (index < right_digits.len) right_digits[index] else '0';
        if (left_digit < right_digit) return .lt;
        if (left_digit > right_digit) return .gt;
    }
    return .eq;
}

test "decimal parse preserves exact coefficient and scale" {
    try std.testing.expectEqual(
        Decimal128{ .coefficient = -1025, .scale = 2 },
        try Decimal128.parse("-10.25", .{}),
    );
    try std.testing.expectError(error.InvalidDecimalCharacter, Decimal128.parse("1e3", .{}));
    try std.testing.expectError(error.MultipleDecimalSeparators, Decimal128.parse("1.2.3", .{}));
}

test "decimal handles i128 limits and overflow" {
    const maximum = try Decimal128.parse("170141183460469231731687303715884105727", .{});
    const minimum = try Decimal128.parse("-170141183460469231731687303715884105728", .{});
    try std.testing.expectEqual(std.math.maxInt(i128), maximum.coefficient);
    try std.testing.expectEqual(std.math.minInt(i128), minimum.coefficient);
    try std.testing.expectError(
        error.DecimalOverflow,
        Decimal128.parse("170141183460469231731687303715884105728", .{}),
    );
}

test "decimal compare and rescale are exact" {
    const one = try Decimal128.parse("1.2", .{});
    const two = try Decimal128.parse("1.19", .{});
    try std.testing.expectEqual(std.math.Order.gt, Decimal128.compare(one, two));
    try std.testing.expectEqual(
        Decimal128{ .coefficient = 120, .scale = 2 },
        try one.rescale(2),
    );
    try std.testing.expectError(error.InexactRescale, two.rescale(1));
}

test "decimal formats without floating point conversion" {
    const cases = [_]struct { raw: []const u8, expected: []const u8 }{
        .{ .raw = "10.25", .expected = "10.25" },
        .{ .raw = "-0.05", .expected = "-0.05" },
        .{ .raw = "0", .expected = "0" },
    };
    for (cases) |case| {
        const value = try Decimal128.parse(case.raw, .{});
        const formatted = try value.toString(std.testing.allocator);
        defer std.testing.allocator.free(formatted);
        try std.testing.expectEqualStrings(case.expected, formatted);
    }
}

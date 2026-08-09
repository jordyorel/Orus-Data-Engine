const std = @import("std");
const column = @import("../core/column.zig");
const decimal = @import("../core/decimal.zig");
const rule = @import("rule.zig");
const violation = @import("violation.zig");

pub fn evaluate(compiled: rule.CompiledRule, input: *const column.Column, row: usize) ?violation.Code {
    if (input.isNull(row)) return if (compiled.tag == .required) .required_missing else null;
    return switch (compiled.evaluator) {
        .required => null,
        .range_i64 => |range| rangeI64(input.data.i64[row], range),
        .range_f64 => |range| rangeF64(input.data.f64[row], range),
        .range_decimal => |range| rangeDecimal(input.data.decimal[row], range),
        .enum_values => |values| enumValue(input.data.string.get(row), values),
        .string_length => |limits| stringLength(input.data.string.get(row).len, limits),
        .pattern => |pattern| if (matchesPattern(pattern, input.data.string.get(row)))
            null
        else
            .pattern_mismatch,
        .regex => |expression| if (expression.matches(input.data.string.get(row)))
            null
        else
            .regex_mismatch,
        .unique => null,
    };
}

fn matchesPattern(pattern: rule.PatternTag, text: []const u8) bool {
    return switch (pattern) {
        .email => blk: {
            const at = std.mem.indexOfScalar(u8, text, '@') orelse break :blk false;
            break :blk at > 0 and at + 1 < text.len and
                std.mem.indexOfScalar(u8, text[at + 1 ..], '.') != null;
        },
        .phone_e164 => blk: {
            if (text.len < 8 or text.len > 16 or text[0] != '+') break :blk false;
            for (text[1..]) |byte| if (!std.ascii.isDigit(byte)) break :blk false;
            break :blk true;
        },
        .date_iso => blk: {
            if (text.len != 10 or text[4] != '-' or text[7] != '-') break :blk false;
            for (text, 0..) |byte, index| {
                if (index != 4 and index != 7 and !std.ascii.isDigit(byte)) break :blk false;
            }
            break :blk true;
        },
        .uuid => blk: {
            if (text.len != 36) break :blk false;
            for (text, 0..) |byte, index| {
                if (index == 8 or index == 13 or index == 18 or index == 23) {
                    if (byte != '-') break :blk false;
                } else if (!std.ascii.isHex(byte)) break :blk false;
            }
            break :blk true;
        },
        .url => std.mem.startsWith(u8, text, "https://") or
            std.mem.startsWith(u8, text, "http://"),
    };
}

fn rangeI64(item: i64, range: rule.RangeI64) ?violation.Code {
    if (range.min) |minimum| if (item < minimum) return .below_minimum;
    if (range.max) |maximum| if (item > maximum) return .above_maximum;
    return null;
}

fn rangeF64(item: f64, range: rule.RangeF64) ?violation.Code {
    if (range.min) |minimum| if (item < minimum) return .below_minimum;
    if (range.max) |maximum| if (item > maximum) return .above_maximum;
    return null;
}

fn rangeDecimal(item: decimal.Decimal128, range: rule.RangeDecimal) ?violation.Code {
    if (range.min) |minimum| if (decimal.Decimal128.compare(item, minimum) == .lt) return .below_minimum;
    if (range.max) |maximum| if (decimal.Decimal128.compare(item, maximum) == .gt) return .above_maximum;
    return null;
}

fn enumValue(item: []const u8, values: []const []const u8) ?violation.Code {
    for (values) |allowed| if (std.mem.eql(u8, item, allowed)) return null;
    return .enum_mismatch;
}

fn stringLength(length: usize, limits: rule.StringLength) ?violation.Code {
    if (limits.min) |minimum| if (length < minimum) return .invalid_length;
    if (limits.max) |maximum| if (length > maximum) return .invalid_length;
    return null;
}

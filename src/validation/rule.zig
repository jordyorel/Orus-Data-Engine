pub const PatternTag = enum { email, phone_e164, date_iso, uuid, url };

pub const RuleTag = enum {
    required,
    range,
    enum_values,
    string_length,
    pattern,
    regex,
    unique,
};

/// JSON-facing rule definition. Compilation validates payload fields against
/// the inferred column type before any rows are evaluated.
pub const Rule = struct {
    id: u32,
    column: []const u8,
    tag: RuleTag,
    min: ?[]const u8 = null,
    max: ?[]const u8 = null,
    values: ?[]const []const u8 = null,
    min_length: ?usize = null,
    max_length: ?usize = null,
    pattern: ?PatternTag = null,
    regex: ?[]const u8 = null,
};

pub const RangeI64 = struct { min: ?i64, max: ?i64 };
pub const RangeF64 = struct { min: ?f64, max: ?f64 };
pub const RangeDecimal = struct {
    min: ?@import("../core/decimal.zig").Decimal128,
    max: ?@import("../core/decimal.zig").Decimal128,
};
pub const StringLength = struct { min: ?usize, max: ?usize };

pub const Evaluator = union(enum) {
    required,
    range_i64: RangeI64,
    range_f64: RangeF64,
    range_decimal: RangeDecimal,
    enum_values: []const []const u8,
    string_length: StringLength,
    pattern: PatternTag,
    regex: *@import("regex.zig").Regex,
    unique,
};

pub const CompiledRule = struct {
    id: u32,
    column_index: u32,
    tag: RuleTag,
    evaluator: Evaluator,
};

test "JSON rules decode regex and unique tags" {
    const std = @import("std");
    const json =
        \\[
        \\  {"id":1,"column":"code","tag":"regex","regex":"^[A-Z]+$"},
        \\  {"id":2,"column":"code","tag":"unique"}
        \\]
    ;
    const parsed = try std.json.parseFromSlice([]const Rule, std.testing.allocator, json, .{});
    defer parsed.deinit();
    try std.testing.expectEqual(RuleTag.regex, parsed.value[0].tag);
    try std.testing.expectEqualStrings("^[A-Z]+$", parsed.value[0].regex.?);
    try std.testing.expectEqual(RuleTag.unique, parsed.value[1].tag);
}

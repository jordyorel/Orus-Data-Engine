const std = @import("std");
const batch = @import("../core/batch.zig");
const decimal = @import("../core/decimal.zig");
const schema = @import("../core/schema.zig");
const value = @import("../core/value.zig");

pub const Options = struct {
    sample_rows: usize = 4096,
    minimum_confidence: f32 = 1.0,
    prefer_string_on_ambiguity: bool = true,
    preserve_leading_zeroes: bool = true,
    trim_before_parse: bool = true,
};

pub const TypeCandidate = struct {
    tag: value.ValueTag,
    score: f32,
    success_count: u64,
    failure_count: u64,
};

pub const Result = struct {
    selected: value.ValueTag,
    confidence: f32,
    nullable: bool,
    candidates: [6]TypeCandidate,
    has_leading_zeroes: bool,
};

const CandidateCounts = struct {
    successes: [6]u64 = @splat(0),
    failures: [6]u64 = @splat(0),
};

const candidate_tags = [6]value.ValueTag{ .boolean, .i64, .decimal, .f64, .date, .datetime };

pub fn inferColumn(column: *const @import("../core/column.zig").Column, options: Options) !Result {
    if (column.tag != .string) return error.ExpectedStringColumn;
    if (options.sample_rows == 0) return error.InvalidSampleSize;
    if (options.minimum_confidence < 0 or options.minimum_confidence > 1) {
        return error.InvalidMinimumConfidence;
    }

    const limit = @min(column.len, options.sample_rows);
    var counts = CandidateCounts{};
    var nullable = false;
    var has_leading_zeroes = false;
    var observed: u64 = 0;

    for (0..limit) |row| {
        if (column.isNull(row)) {
            nullable = true;
            continue;
        }
        const raw = column.data.string.get(row);
        const text = normalized(raw, options.trim_before_parse);
        observed += 1;
        if (options.preserve_leading_zeroes and hasSignificantLeadingZero(text)) {
            has_leading_zeroes = true;
        }
        record(&counts, 0, parseBoolean(text) != null);
        record(&counts, 1, parseI64(text) != null);
        record(&counts, 2, parseDecimalCandidate(text));
        record(&counts, 3, parseF64(text) != null);
        record(&counts, 4, parseDate(text) != null);
        record(&counts, 5, parseDateTime(text) != null);
    }

    var candidates: [6]TypeCandidate = undefined;
    for (candidate_tags, 0..) |tag, index| {
        const success = counts.successes[index];
        const score = if (observed == 0)
            0
        else
            @as(f32, @floatFromInt(success)) / @as(f32, @floatFromInt(observed));
        candidates[index] = .{
            .tag = tag,
            .score = score,
            .success_count = success,
            .failure_count = counts.failures[index],
        };
    }

    const selected = selectType(candidates, has_leading_zeroes, options);
    const confidence = if (selected == .string) 1 else candidateScore(candidates, selected);
    return .{
        .selected = selected,
        .confidence = confidence,
        .nullable = nullable,
        .candidates = candidates,
        .has_leading_zeroes = has_leading_zeroes,
    };
}

/// Returns an owned schema. Names and fields use `allocator` and remain valid
/// independently of the sampled batch.
pub fn inferSchema(
    allocator: std.mem.Allocator,
    input: *const batch.Batch,
    options: Options,
    force_nullable: bool,
) !schema.Schema {
    const fields = try allocator.alloc(schema.Field, input.columns.len);
    errdefer allocator.free(fields);
    var initialized: usize = 0;
    errdefer for (fields[0..initialized]) |field| allocator.free(field.name);

    for (input.columns, input.schema.fields, 0..) |*column, source_field, index| {
        const result = try inferColumn(column, options);
        fields[index] = .{
            .name = try allocator.dupe(u8, source_field.name),
            .tag = result.selected,
            .nullable = result.nullable or force_nullable,
        };
        initialized += 1;
    }
    return .{ .fields = fields, .hash = schema.Schema.computeHash(fields) };
}

pub fn normalized(raw: []const u8, trim: bool) []const u8 {
    return if (trim) std.mem.trim(u8, raw, &std.ascii.whitespace) else raw;
}

pub fn parseBoolean(text: []const u8) ?bool {
    if (std.ascii.eqlIgnoreCase(text, "true")) return true;
    if (std.ascii.eqlIgnoreCase(text, "false")) return false;
    return null;
}

pub fn parseI64(text: []const u8) ?i64 {
    return std.fmt.parseInt(i64, text, 10) catch null;
}

pub fn parseDecimal(text: []const u8) ?decimal.Decimal128 {
    return decimal.Decimal128.parse(text, .{}) catch null;
}

fn parseDecimalCandidate(text: []const u8) bool {
    return std.mem.indexOfScalar(u8, text, '.') != null and parseDecimal(text) != null;
}

pub fn parseF64(text: []const u8) ?f64 {
    if (std.mem.indexOfAny(u8, text, "eE") == null) return null;
    const parsed = std.fmt.parseFloat(f64, text) catch return null;
    return if (std.math.isFinite(parsed)) parsed else null;
}

pub fn parseDate(text: []const u8) ?i32 {
    if (text.len != 10 or text[4] != '-' or text[7] != '-') return null;
    const year = std.fmt.parseInt(i32, text[0..4], 10) catch return null;
    const month = std.fmt.parseInt(u8, text[5..7], 10) catch return null;
    const day = std.fmt.parseInt(u8, text[8..10], 10) catch return null;
    if (!validDate(year, month, day)) return null;
    return @intCast(daysFromCivil(year, month, day));
}

pub fn parseDateTime(text: []const u8) ?i64 {
    if (text.len != 20 or text[10] != 'T' or text[13] != ':' or text[16] != ':' or text[19] != 'Z') return null;
    const days = parseDate(text[0..10]) orelse return null;
    const hour = std.fmt.parseInt(u8, text[11..13], 10) catch return null;
    const minute = std.fmt.parseInt(u8, text[14..16], 10) catch return null;
    const second = std.fmt.parseInt(u8, text[17..19], 10) catch return null;
    if (hour > 23 or minute > 59 or second > 59) return null;
    return @as(i64, days) * 86_400 + @as(i64, hour) * 3600 + @as(i64, minute) * 60 + second;
}

fn record(counts: *CandidateCounts, index: usize, success: bool) void {
    if (success) counts.successes[index] += 1 else counts.failures[index] += 1;
}

fn selectType(candidates: [6]TypeCandidate, leading_zeroes: bool, options: Options) value.ValueTag {
    if (leading_zeroes) return .string;
    var qualifying: usize = 0;
    for (candidates) |candidate| {
        if (candidate.score >= options.minimum_confidence) qualifying += 1;
    }
    if (qualifying > 1 and options.prefer_string_on_ambiguity) return .string;
    for (candidates) |candidate| {
        if (candidate.score >= options.minimum_confidence) return candidate.tag;
    }
    return .string;
}

fn candidateScore(candidates: [6]TypeCandidate, tag: value.ValueTag) f32 {
    for (candidates) |candidate| if (candidate.tag == tag) return candidate.score;
    return 1;
}

fn validDate(year: i32, month: u8, day: u8) bool {
    if (month == 0 or month > 12 or day == 0) return false;
    const leap = @mod(year, 4) == 0 and (@mod(year, 100) != 0 or @mod(year, 400) == 0);
    const lengths = [_]u8{ 31, if (leap) 29 else 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
    return day <= lengths[month - 1];
}

fn daysFromCivil(year_value: i32, month_value: u8, day: u8) i64 {
    var year: i64 = year_value;
    const month: i64 = month_value;
    year -= @intFromBool(month <= 2);
    const era = @divFloor(year, 400);
    const year_of_era = year - era * 400;
    const shifted_month = month + (if (month > 2) @as(i64, -3) else 9);
    const day_of_year = @divFloor(153 * shifted_month + 2, 5) + day - 1;
    const day_of_era = year_of_era * 365 + @divFloor(year_of_era, 4) -
        @divFloor(year_of_era, 100) + day_of_year;
    return era * 146097 + day_of_era - 719468;
}

fn hasSignificantLeadingZero(text: []const u8) bool {
    const unsigned = if (text.len > 0 and (text[0] == '+' or text[0] == '-')) text[1..] else text;
    return unsigned.len > 1 and unsigned[0] == '0' and unsigned[1] >= '0' and unsigned[1] <= '9';
}

test "inference is conservative with leading zeroes and mixed values" {
    const arena_pool = @import("../core/arena_pool.zig");
    var arena = arena_pool.BatchArena.init(std.testing.allocator);
    defer arena.deinit();
    const fields = [_]schema.Field{.{ .name = "id" }};
    const source_schema = schema.Schema{ .fields = &fields, .hash = schema.Schema.computeHash(&fields) };
    var builder = try batch.Builder.init(&arena, &source_schema);
    try builder.appendString(0, "0012");
    try builder.finishRow();
    try builder.appendString(0, "0013");
    try builder.finishRow();
    const input = try builder.finish(.{});

    const result = try inferColumn(input.column(0), .{});
    try std.testing.expectEqual(value.ValueTag.string, result.selected);
    try std.testing.expect(result.has_leading_zeroes);
}

test "inference selects boolean integer decimal and scientific float" {
    try std.testing.expectEqual(@as(?bool, true), parseBoolean("TRUE"));
    try std.testing.expectEqual(@as(?i64, -42), parseI64("-42"));
    try std.testing.expectEqual(@as(i128, 125), parseDecimal("1.25").?.coefficient);
    try std.testing.expectEqual(@as(i128, -74), parseDecimal("-74").?.coefficient);
    try std.testing.expectEqual(@as(?f64, 1000), parseF64("1e3"));
}

test "inference preserves rare alphanumeric identifiers by default" {
    const arena_pool = @import("../core/arena_pool.zig");
    var arena = arena_pool.BatchArena.init(std.testing.allocator);
    defer arena.deinit();
    const fields = [_]schema.Field{.{ .name = "license_number" }};
    const source_schema = schema.Schema{ .fields = &fields, .hash = schema.Schema.computeHash(&fields) };
    var builder = try batch.Builder.init(&arena, &source_schema);

    for (0..99) |index| {
        var buffer: [32]u8 = undefined;
        const identifier = try std.fmt.bufPrint(&buffer, "{d}", .{index + 1000});
        try builder.appendString(0, identifier);
        try builder.finishRow();
    }
    try builder.appendString(0, "F59583");
    try builder.finishRow();

    const input = try builder.finish(.{});
    const result = try inferColumn(input.column(0), .{});
    try std.testing.expectEqual(value.ValueTag.string, result.selected);
    try std.testing.expectEqual(@as(u64, 1), result.candidates[1].failure_count);
}

const std = @import("std");
const decimal = @import("../core/decimal.zig");
const schema = @import("../core/schema.zig");
const rule = @import("rule.zig");

pub fn compile(
    allocator: std.mem.Allocator,
    source_schema: *const schema.Schema,
    definitions: []const rule.Rule,
) ![]rule.CompiledRule {
    const compiled = try allocator.alloc(rule.CompiledRule, definitions.len);
    var initialized: usize = 0;
    errdefer deinit(allocator, compiled[0..initialized]);
    for (definitions, 0..) |definition, index| {
        for (definitions[0..index]) |previous| {
            if (previous.id == definition.id) return error.DuplicateRuleId;
        }
        const column_index = source_schema.indexOf(definition.column) orelse return error.UnknownColumn;
        const evaluator = try compileEvaluator(allocator, source_schema.fields[column_index].tag, definition);
        try validateEvaluator(evaluator);
        compiled[index] = .{
            .id = definition.id,
            .column_index = @intCast(column_index),
            .tag = definition.tag,
            .evaluator = evaluator,
        };
        initialized += 1;
    }
    return compiled;
}

pub fn deinit(allocator: std.mem.Allocator, compiled: []rule.CompiledRule) void {
    for (compiled) |item| switch (item.evaluator) {
        .regex => |expression| {
            expression.deinit();
            allocator.destroy(expression);
        },
        else => {},
    };
    allocator.free(compiled);
}

fn validateEvaluator(evaluator: rule.Evaluator) !void {
    switch (evaluator) {
        .required, .pattern, .regex, .unique => {},
        .range_i64 => |range| {
            if (range.min == null and range.max == null) return error.MissingRangeBounds;
            if (range.min != null and range.max != null and range.min.? > range.max.?) {
                return error.InvertedRange;
            }
        },
        .range_f64 => |range| {
            if (range.min == null and range.max == null) return error.MissingRangeBounds;
            if (range.min != null and range.max != null and range.min.? > range.max.?) {
                return error.InvertedRange;
            }
        },
        .range_decimal => |range| {
            if (range.min == null and range.max == null) return error.MissingRangeBounds;
            if (range.min != null and range.max != null and
                decimal.Decimal128.compare(range.min.?, range.max.?) == .gt)
            {
                return error.InvertedRange;
            }
        },
        .enum_values => |values| if (values.len == 0) return error.EmptyEnumValues,
        .string_length => |limits| {
            if (limits.min == null and limits.max == null) return error.MissingLengthBounds;
            if (limits.min != null and limits.max != null and limits.min.? > limits.max.?) {
                return error.InvertedLengthRange;
            }
        },
    }
}

fn compileEvaluator(
    allocator: std.mem.Allocator,
    tag: @import("../core/value.zig").ValueTag,
    definition: rule.Rule,
) !rule.Evaluator {
    return switch (definition.tag) {
        .required => .required,
        .range => switch (tag) {
            .i64 => .{ .range_i64 = .{
                .min = try parseOptional(i64, definition.min),
                .max = try parseOptional(i64, definition.max),
            } },
            .f64 => .{ .range_f64 = .{
                .min = try parseOptional(f64, definition.min),
                .max = try parseOptional(f64, definition.max),
            } },
            .decimal => .{ .range_decimal = .{
                .min = try parseOptionalDecimal(definition.min),
                .max = try parseOptionalDecimal(definition.max),
            } },
            else => return error.RangeRequiresNumericColumn,
        },
        .enum_values => if (tag == .string)
            .{ .enum_values = definition.values orelse return error.MissingEnumValues }
        else
            error.EnumRequiresStringColumn,
        .string_length => if (tag == .string)
            .{ .string_length = .{ .min = definition.min_length, .max = definition.max_length } }
        else
            error.LengthRequiresStringColumn,
        .pattern => if (tag == .string)
            .{ .pattern = definition.pattern orelse return error.MissingPattern }
        else
            error.PatternRequiresStringColumn,
        .regex => if (tag == .string) blk: {
            const expression = try allocator.create(@import("regex.zig").Regex);
            errdefer allocator.destroy(expression);
            expression.* = try @import("regex.zig").Regex.init(
                allocator,
                definition.regex orelse return error.MissingRegex,
            );
            break :blk .{ .regex = expression };
        } else error.RegexRequiresStringColumn,
        .unique => .unique,
    };
}

fn parseOptional(comptime T: type, raw: ?[]const u8) !?T {
    const text = raw orelse return null;
    if (T == i64) return @as(?T, try std.fmt.parseInt(i64, text, 10));
    if (T == f64) {
        const result = try std.fmt.parseFloat(f64, text);
        if (!std.math.isFinite(result)) return error.NonFiniteRange;
        return @as(?T, result);
    }
    unreachable;
}

fn parseOptionalDecimal(raw: ?[]const u8) !?decimal.Decimal128 {
    return @as(?decimal.Decimal128, try decimal.Decimal128.parse(raw orelse return null, .{}));
}

test "rules compile column names and typed ranges" {
    const fields = [_]schema.Field{.{ .name = "age", .tag = .i64 }};
    const source_schema = schema.Schema{ .fields = &fields, .hash = schema.Schema.computeHash(&fields) };
    const definitions = [_]rule.Rule{.{
        .id = 1,
        .column = "age",
        .tag = .range,
        .min = "18",
        .max = "120",
    }};
    const compiled = try compile(std.testing.allocator, &source_schema, &definitions);
    defer std.testing.allocator.free(compiled);
    try std.testing.expectEqual(@as(u32, 0), compiled[0].column_index);
    try std.testing.expectEqual(@as(?i64, 18), compiled[0].evaluator.range_i64.min);
}

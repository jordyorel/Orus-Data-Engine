const std = @import("std");
const arena_pool = @import("../core/arena_pool.zig");
const batch = @import("../core/batch.zig");
const schema = @import("../core/schema.zig");
const type_infer = @import("type_infer.zig");

pub const InvalidValuePolicy = enum {
    fail,
    null_value,
};

pub const Options = struct {
    invalid_value_policy: InvalidValuePolicy = .fail,
    trim_before_parse: bool = true,
};

pub const Result = struct {
    output: batch.Batch,
    invalid_values: u64,
};

pub fn convert(
    output_arena: *arena_pool.BatchArena,
    input: *const batch.Batch,
    target_schema: *const schema.Schema,
    options: Options,
) !Result {
    if (input.columns.len != target_schema.fields.len) return error.SchemaMismatch;
    var builder = try batch.Builder.init(output_arena, target_schema);
    var invalid_values: u64 = 0;

    for (0..input.row_count) |row| {
        for (input.columns, target_schema.fields, 0..) |*source, field, column_index| {
            if (source.tag != .string) return error.ExpectedStringColumn;
            if (source.isNull(row)) {
                if (!field.nullable) return error.UnexpectedNull;
                try builder.appendNull(column_index);
                continue;
            }
            const raw = source.data.string.get(row);
            const text = type_infer.normalized(raw, options.trim_before_parse);
            const valid = try appendParsed(&builder, column_index, field.tag, raw, text);
            if (!valid) {
                invalid_values += 1;
                switch (options.invalid_value_policy) {
                    .fail => return error.InvalidValue,
                    .null_value => try builder.appendNull(column_index),
                }
            }
        }
        try builder.finishRow();
    }
    return .{
        .output = try builder.finish(input.metadata),
        .invalid_values = invalid_values,
    };
}

fn appendParsed(
    builder: *batch.Builder,
    index: usize,
    tag: @import("../core/value.zig").ValueTag,
    raw: []const u8,
    text: []const u8,
) !bool {
    switch (tag) {
        .string => try builder.appendString(index, raw),
        .boolean => try builder.appendBoolean(index, type_infer.parseBoolean(text) orelse return false),
        .i64 => try builder.appendI64(index, type_infer.parseI64(text) orelse return false),
        .decimal => try builder.appendDecimal(index, type_infer.parseDecimal(text) orelse return false),
        .f64 => try builder.appendF64(index, type_infer.parseF64(text) orelse return false),
        .date => try builder.appendDate(index, type_infer.parseDate(text) orelse return false),
        .datetime => try builder.appendDateTime(index, type_infer.parseDateTime(text) orelse return false),
    }
    return true;
}

test "converter materializes typed columns and preserves nulls" {
    const decimal = @import("../core/decimal.zig");
    var input_arena = arena_pool.BatchArena.init(std.testing.allocator);
    defer input_arena.deinit();
    var output_arena = arena_pool.BatchArena.init(std.testing.allocator);
    defer output_arena.deinit();
    const raw_fields = [_]schema.Field{ .{ .name = "count" }, .{ .name = "price" } };
    const raw_schema = schema.Schema{ .fields = &raw_fields, .hash = schema.Schema.computeHash(&raw_fields) };
    var raw_builder = try batch.Builder.init(&input_arena, &raw_schema);
    try raw_builder.appendString(0, "42");
    try raw_builder.appendString(1, "10.25");
    try raw_builder.finishRow();
    try raw_builder.appendNull(0);
    try raw_builder.appendString(1, "0.50");
    try raw_builder.finishRow();
    const raw = try raw_builder.finish(.{ .batch_id = 7 });
    const typed_fields = [_]schema.Field{
        .{ .name = "count", .tag = .i64 },
        .{ .name = "price", .tag = .decimal, .nullable = false },
    };
    const typed_schema = schema.Schema{
        .fields = &typed_fields,
        .hash = schema.Schema.computeHash(&typed_fields),
    };

    const result = try convert(&output_arena, &raw, &typed_schema, .{});
    try std.testing.expectEqual(@as(i64, 42), result.output.column(0).get(0).?.i64);
    try std.testing.expect(result.output.column(0).get(1) == null);
    try std.testing.expectEqual(
        decimal.Decimal128{ .coefficient = 1025, .scale = 2 },
        result.output.column(1).get(0).?.decimal,
    );
    try std.testing.expectEqual(@as(u64, 0), result.invalid_values);
    try std.testing.expectEqual(@as(u64, 7), result.output.metadata.batch_id);
}

test "converter applies the invalid value policy" {
    var input_arena = arena_pool.BatchArena.init(std.testing.allocator);
    defer input_arena.deinit();
    var output_arena = arena_pool.BatchArena.init(std.testing.allocator);
    defer output_arena.deinit();
    const raw_fields = [_]schema.Field{.{ .name = "count" }};
    const raw_schema = schema.Schema{ .fields = &raw_fields, .hash = schema.Schema.computeHash(&raw_fields) };
    var raw_builder = try batch.Builder.init(&input_arena, &raw_schema);
    try raw_builder.appendString(0, "bad");
    try raw_builder.finishRow();
    const raw = try raw_builder.finish(.{});
    const typed_fields = [_]schema.Field{.{ .name = "count", .tag = .i64 }};
    const typed_schema = schema.Schema{
        .fields = &typed_fields,
        .hash = schema.Schema.computeHash(&typed_fields),
    };

    try std.testing.expectError(error.InvalidValue, convert(&output_arena, &raw, &typed_schema, .{}));
    output_arena.reset();
    const result = try convert(&output_arena, &raw, &typed_schema, .{
        .invalid_value_policy = .null_value,
    });
    try std.testing.expect(result.output.column(0).get(0) == null);
    try std.testing.expectEqual(@as(u64, 1), result.invalid_values);
}

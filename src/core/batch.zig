const std = @import("std");
const arena_pool = @import("arena_pool.zig");
const column_types = @import("column.zig");
const decimal = @import("decimal.zig");
const metadata = @import("batch_metadata.zig");
const schema = @import("schema.zig");

/// Immutable view over memory owned by a BatchArena. Every slice becomes
/// invalid when that arena is reset.
pub const Batch = struct {
    schema: *const schema.Schema,
    columns: []const column_types.Column,
    row_count: usize,
    metadata: metadata.BatchMetadata,

    pub fn column(self: *const Batch, index: usize) *const column_types.Column {
        return &self.columns[index];
    }

    pub fn columnByName(self: *const Batch, name: []const u8) ?*const column_types.Column {
        const index = self.schema.indexOf(name) orelse return null;
        return self.column(index);
    }
};

/// Mutable batch construction state. All allocations belong to the supplied
/// BatchArena; Builder owns no memory and has no deinit method.
pub const Builder = struct {
    allocator: std.mem.Allocator,
    schema: *const schema.Schema,
    columns: std.ArrayList(column_types.ColumnBuilder) = .empty,
    row_count: usize = 0,

    pub fn init(arena: *arena_pool.BatchArena, source_schema: *const schema.Schema) !Builder {
        var result = Builder{
            .allocator = arena.allocator(),
            .schema = source_schema,
        };
        try result.columns.ensureTotalCapacity(result.allocator, source_schema.fields.len);
        for (source_schema.fields) |field| {
            try result.columns.append(
                result.allocator,
                try column_types.ColumnBuilder.init(result.allocator, field.tag),
            );
        }
        return result;
    }

    pub fn appendNull(self: *Builder, index: usize) !void {
        try (try self.at(index)).appendNull();
    }

    pub fn appendI64(self: *Builder, index: usize, item: i64) !void {
        try (try self.at(index)).appendI64(item);
    }

    pub fn appendF64(self: *Builder, index: usize, item: f64) !void {
        try (try self.at(index)).appendF64(item);
    }

    pub fn appendDecimal(self: *Builder, index: usize, item: decimal.Decimal128) !void {
        try (try self.at(index)).appendDecimal(item);
    }

    pub fn appendBoolean(self: *Builder, index: usize, item: bool) !void {
        try (try self.at(index)).appendBoolean(item);
    }

    pub fn appendString(self: *Builder, index: usize, item: []const u8) !void {
        try (try self.at(index)).appendString(item);
    }

    pub fn appendDate(self: *Builder, index: usize, item: i32) !void {
        try (try self.at(index)).appendDate(item);
    }

    pub fn appendDateTime(self: *Builder, index: usize, item: i64) !void {
        try (try self.at(index)).appendDateTime(item);
    }

    pub fn finishRow(self: *Builder) !void {
        const expected_len = self.row_count + 1;
        for (self.columns.items) |item| {
            if (item.len() != expected_len) return error.IncompleteRow;
        }
        self.row_count = expected_len;
    }

    pub fn finish(self: *Builder, batch_metadata: metadata.BatchMetadata) !Batch {
        var finished: std.ArrayList(column_types.Column) = .empty;
        try finished.ensureTotalCapacity(self.allocator, self.columns.items.len);
        for (self.columns.items) |*item| {
            if (item.len() != self.row_count) return error.InvalidColumnLength;
            try finished.append(self.allocator, try item.finish());
        }
        return .{
            .schema = self.schema,
            .columns = try finished.toOwnedSlice(self.allocator),
            .row_count = self.row_count,
            .metadata = batch_metadata,
        };
    }

    fn at(self: *Builder, index: usize) !*column_types.ColumnBuilder {
        if (index >= self.columns.items.len) return error.ColumnIndexOutOfBounds;
        return &self.columns.items[index];
    }
};

test "builder rejects incomplete rows" {
    const fields = [_]schema.Field{
        .{ .name = "id" },
        .{ .name = "name" },
    };
    const source_schema = schema.Schema{
        .fields = &fields,
        .hash = schema.Schema.computeHash(&fields),
    };
    var arena = arena_pool.BatchArena.init(std.testing.allocator);
    defer arena.deinit();

    var builder = try Builder.init(&arena, &source_schema);
    try builder.appendString(0, "1");
    try std.testing.expectError(error.IncompleteRow, builder.finishRow());
    try builder.appendString(1, "Ada");
    try builder.finishRow();
    const result = try builder.finish(.{});

    try std.testing.expectEqual(@as(usize, 1), result.row_count);
    const name = result.columnByName("name").?.data.string.get(0);
    try std.testing.expectEqualStrings("Ada", name);
}

test "builder rejects an invalid column index" {
    const fields = [_]schema.Field{.{ .name = "name" }};
    const source_schema = schema.Schema{
        .fields = &fields,
        .hash = schema.Schema.computeHash(&fields),
    };
    var arena = arena_pool.BatchArena.init(std.testing.allocator);
    defer arena.deinit();

    var builder = try Builder.init(&arena, &source_schema);
    try std.testing.expectError(error.ColumnIndexOutOfBounds, builder.appendString(1, "Ada"));
}

test "builder creates a mixed typed batch released by one arena reset" {
    const fields = [_]schema.Field{
        .{ .name = "id", .tag = .i64, .nullable = false },
        .{ .name = "amount", .tag = .decimal },
        .{ .name = "active", .tag = .boolean },
        .{ .name = "name", .tag = .string },
    };
    const source_schema = schema.Schema{
        .fields = &fields,
        .hash = schema.Schema.computeHash(&fields),
    };
    var arena = arena_pool.BatchArena.init(std.testing.allocator);
    defer arena.deinit();
    var builder = try Builder.init(&arena, &source_schema);
    try builder.appendI64(0, 42);
    try builder.appendDecimal(1, try decimal.Decimal128.parse("10.25", .{}));
    try builder.appendBoolean(2, true);
    try builder.appendString(3, "Ada");
    try builder.finishRow();
    const result = try builder.finish(.{});

    try std.testing.expectEqual(@as(i64, 42), result.column(0).get(0).?.i64);
    try std.testing.expectEqual(@as(i128, 1025), result.column(1).get(0).?.decimal.coefficient);
    try std.testing.expect(result.column(2).get(0).?.boolean);
    try std.testing.expectEqualStrings("Ada", result.column(3).get(0).?.string);
    arena.reset();
}

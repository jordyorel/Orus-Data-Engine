const std = @import("std");
const bitmap = @import("bitmap.zig");
const decimal = @import("decimal.zig");
const string_column = @import("string_column.zig");
const value = @import("value.zig");

pub const ColumnData = union(value.ValueTag) {
    i64: []const i64,
    f64: []const f64,
    decimal: []const decimal.Decimal128,
    boolean: bitmap.BitVector,
    string: string_column.StringColumn,
    date: []const i32,
    datetime: []const i64,
};

pub const Column = struct {
    tag: value.ValueTag,
    len: usize,
    nulls: bitmap.NullBitmap,
    data: ColumnData,

    pub fn isNull(self: *const Column, row: usize) bool {
        std.debug.assert(row < self.len);
        return self.nulls.isSet(row);
    }

    /// Returns a convenience value that borrows any string bytes from the
    /// batch arena. Hot loops should access data directly.
    pub fn get(self: *const Column, row: usize) ?value.Value {
        if (self.isNull(row)) return null;
        return switch (self.data) {
            .i64 => |items| .{ .i64 = items[row] },
            .f64 => |items| .{ .f64 = items[row] },
            .decimal => |items| .{ .decimal = items[row] },
            .boolean => |items| .{ .boolean = items.isSet(row) },
            .string => |items| .{ .string = items.get(row) },
            .date => |items| .{ .date = items[row] },
            .datetime => |items| .{ .datetime = items[row] },
        };
    }
};

const BuilderData = union(value.ValueTag) {
    i64: std.ArrayList(i64),
    f64: std.ArrayList(f64),
    decimal: std.ArrayList(decimal.Decimal128),
    boolean: bitmap.Builder,
    string: string_column.Builder,
    date: std.ArrayList(i32),
    datetime: std.ArrayList(i64),
};

/// Mutable construction state for exactly one typed column.
pub const ColumnBuilder = struct {
    tag: value.ValueTag,
    allocator: std.mem.Allocator,
    nulls: bitmap.Builder,
    data: BuilderData,

    pub fn init(allocator: std.mem.Allocator, tag: value.ValueTag) !ColumnBuilder {
        return .{
            .tag = tag,
            .allocator = allocator,
            .nulls = bitmap.Builder.init(allocator),
            .data = switch (tag) {
                .i64 => .{ .i64 = .empty },
                .f64 => .{ .f64 = .empty },
                .decimal => .{ .decimal = .empty },
                .boolean => .{ .boolean = bitmap.Builder.init(allocator) },
                .string => .{ .string = try string_column.Builder.init(allocator) },
                .date => .{ .date = .empty },
                .datetime => .{ .datetime = .empty },
            },
        };
    }

    pub fn len(self: *const ColumnBuilder) usize {
        return self.nulls.len;
    }

    pub fn appendNull(self: *ColumnBuilder) !void {
        try self.nulls.append(true);
        switch (self.data) {
            .i64 => |*items| try items.append(self.allocator, 0),
            .f64 => |*items| try items.append(self.allocator, 0),
            .decimal => |*items| try items.append(self.allocator, .{
                .coefficient = 0,
                .scale = 0,
            }),
            .boolean => |*items| try items.append(false),
            .string => |*items| try items.appendNull(),
            .date => |*items| try items.append(self.allocator, 0),
            .datetime => |*items| try items.append(self.allocator, 0),
        }
    }

    pub fn appendI64(self: *ColumnBuilder, item: i64) !void {
        if (self.tag != .i64) return error.ColumnTypeMismatch;
        try self.nulls.append(false);
        try self.data.i64.append(self.allocator, item);
    }

    pub fn appendF64(self: *ColumnBuilder, item: f64) !void {
        if (self.tag != .f64) return error.ColumnTypeMismatch;
        try self.nulls.append(false);
        try self.data.f64.append(self.allocator, item);
    }

    pub fn appendDecimal(self: *ColumnBuilder, item: decimal.Decimal128) !void {
        if (self.tag != .decimal) return error.ColumnTypeMismatch;
        try self.nulls.append(false);
        try self.data.decimal.append(self.allocator, item);
    }

    pub fn appendBoolean(self: *ColumnBuilder, item: bool) !void {
        if (self.tag != .boolean) return error.ColumnTypeMismatch;
        try self.nulls.append(false);
        try self.data.boolean.append(item);
    }

    pub fn appendString(self: *ColumnBuilder, item: []const u8) !void {
        if (self.tag != .string) return error.ColumnTypeMismatch;
        try self.nulls.append(false);
        try self.data.string.append(item);
    }

    pub fn appendDate(self: *ColumnBuilder, item: i32) !void {
        if (self.tag != .date) return error.ColumnTypeMismatch;
        try self.nulls.append(false);
        try self.data.date.append(self.allocator, item);
    }

    pub fn appendDateTime(self: *ColumnBuilder, item: i64) !void {
        if (self.tag != .datetime) return error.ColumnTypeMismatch;
        try self.nulls.append(false);
        try self.data.datetime.append(self.allocator, item);
    }

    pub fn finish(self: *ColumnBuilder) !Column {
        const nulls = try self.nulls.finish();
        const data: ColumnData = switch (self.data) {
            .i64 => |*items| .{ .i64 = try items.toOwnedSlice(self.allocator) },
            .f64 => |*items| .{ .f64 = try items.toOwnedSlice(self.allocator) },
            .decimal => |*items| .{ .decimal = try items.toOwnedSlice(self.allocator) },
            .boolean => |*items| .{ .boolean = try items.finish() },
            .string => |*items| .{ .string = try items.finish() },
            .date => |*items| .{ .date = try items.toOwnedSlice(self.allocator) },
            .datetime => |*items| .{ .datetime = try items.toOwnedSlice(self.allocator) },
        };
        return .{
            .tag = self.tag,
            .len = nulls.len,
            .nulls = nulls,
            .data = data,
        };
    }
};

test "typed column builders preserve values and nulls" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var integers = try ColumnBuilder.init(allocator, .i64);
    try integers.appendI64(std.math.minInt(i64));
    try integers.appendNull();
    try integers.appendI64(std.math.maxInt(i64));
    const column = try integers.finish();

    try std.testing.expectEqual(@as(usize, 3), column.len);
    try std.testing.expectEqual(std.math.minInt(i64), column.get(0).?.i64);
    try std.testing.expect(column.get(1) == null);
    try std.testing.expectEqual(std.math.maxInt(i64), column.get(2).?.i64);
}

test "boolean columns are bit packed" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var builder = try ColumnBuilder.init(arena.allocator(), .boolean);
    try builder.appendBoolean(true);
    try builder.appendBoolean(false);
    try builder.appendNull();
    const column = try builder.finish();

    try std.testing.expect(column.get(0).?.boolean);
    try std.testing.expect(!column.get(1).?.boolean);
    try std.testing.expect(column.get(2) == null);
    try std.testing.expectEqual(@as(usize, 1), column.data.boolean.words.len);
}

test "column builders enforce their physical type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var builder = try ColumnBuilder.init(arena.allocator(), .f64);

    try std.testing.expectError(error.ColumnTypeMismatch, builder.appendI64(1));
    try builder.appendF64(1.5);
    const column = try builder.finish();

    try std.testing.expectEqual(@as(usize, 1), column.len);
    try std.testing.expectEqual(@as(f64, 1.5), column.get(0).?.f64);
}

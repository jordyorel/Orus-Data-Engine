const std = @import("std");
const column = @import("../core/column.zig");
const value = @import("../core/value.zig");
const cardinality = @import("cardinality.zig");
const length_stats = @import("length_stats.zig");
const null_stats = @import("null_stats.zig");
const numeric_stats = @import("numeric_stats.zig");
const pattern_detect = @import("pattern_detect.zig");

pub const ColumnProfiler = struct {
    name: []const u8,
    tag: value.ValueTag,
    nullable: bool,
    nulls: null_stats.NullStats = .{},
    numeric: numeric_stats.NumericStats = .{},
    decimal: numeric_stats.DecimalStats = .{},
    length: length_stats.LengthStats = .{},
    cardinality: cardinality.AdaptiveCardinality,
    patterns: pattern_detect.Detector = .{},

    pub fn init(
        allocator: std.mem.Allocator,
        name: []const u8,
        tag: value.ValueTag,
        nullable: bool,
    ) !ColumnProfiler {
        return .{
            .name = try allocator.dupe(u8, name),
            .tag = tag,
            .nullable = nullable,
            .cardinality = cardinality.AdaptiveCardinality.init(allocator),
        };
    }

    pub fn deinit(self: *ColumnProfiler, allocator: std.mem.Allocator) void {
        self.cardinality.deinit();
        allocator.free(self.name);
    }

    pub fn update(self: *ColumnProfiler, input: *const column.Column) !void {
        if (input.tag != self.tag) return error.ColumnTypeMismatch;
        self.nulls.update(input);
        for (0..input.len) |row| {
            if (input.isNull(row)) continue;
            switch (input.data) {
                .i64 => |items| {
                    self.numeric.updateValue(@floatFromInt(items[row]));
                    var bytes: [8]u8 = undefined;
                    std.mem.writeInt(i64, &bytes, items[row], .little);
                    try self.cardinality.insert(hashValue(.i64, &bytes));
                },
                .f64 => |items| {
                    self.numeric.updateValue(items[row]);
                    var bytes: [8]u8 = undefined;
                    std.mem.writeInt(u64, &bytes, @bitCast(items[row]), .little);
                    try self.cardinality.insert(hashValue(.f64, &bytes));
                },
                .decimal => |items| {
                    self.decimal.updateValue(items[row]);
                    var bytes: [16]u8 = undefined;
                    std.mem.writeInt(i128, &bytes, items[row].coefficient, .little);
                    var hasher = std.hash.XxHash3.init(@intFromEnum(value.ValueTag.decimal));
                    hasher.update(&bytes);
                    hasher.update(std.mem.asBytes(&items[row].scale));
                    try self.cardinality.insert(hasher.final());
                },
                .boolean => |items| {
                    const item: u8 = @intFromBool(items.isSet(row));
                    try self.cardinality.insert(hashValue(.boolean, std.mem.asBytes(&item)));
                },
                .string => |items| {
                    const item = items.get(row);
                    self.length.updateValue(item.len);
                    self.patterns.update(item);
                    try self.cardinality.insert(hashValue(.string, item));
                },
                .date => |items| {
                    self.numeric.updateValue(@floatFromInt(items[row]));
                    var bytes: [4]u8 = undefined;
                    std.mem.writeInt(i32, &bytes, items[row], .little);
                    try self.cardinality.insert(hashValue(.date, &bytes));
                },
                .datetime => |items| {
                    self.numeric.updateValue(@floatFromInt(items[row]));
                    var bytes: [8]u8 = undefined;
                    std.mem.writeInt(i64, &bytes, items[row], .little);
                    try self.cardinality.insert(hashValue(.datetime, &bytes));
                },
            }
        }
    }
};

fn hashValue(tag: value.ValueTag, bytes: []const u8) u64 {
    return std.hash.XxHash3.hash(@intFromEnum(tag), bytes);
}

test "column profiler observes typed numeric data" {
    const arena_pool = @import("../core/arena_pool.zig");
    const batch = @import("../core/batch.zig");
    const schema = @import("../core/schema.zig");
    var arena = arena_pool.BatchArena.init(std.testing.allocator);
    defer arena.deinit();
    const fields = [_]schema.Field{.{ .name = "value", .tag = .i64 }};
    const source_schema = schema.Schema{ .fields = &fields, .hash = schema.Schema.computeHash(&fields) };
    var builder = try batch.Builder.init(&arena, &source_schema);
    try builder.appendI64(0, 10);
    try builder.finishRow();
    try builder.appendI64(0, 20);
    try builder.finishRow();
    const input = try builder.finish(.{});
    var profiler = try ColumnProfiler.init(std.testing.allocator, "value", .i64, false);
    defer profiler.deinit(std.testing.allocator);
    try profiler.update(input.column(0));
    try std.testing.expectEqual(@as(f64, 15), profiler.numeric.mean);
    try std.testing.expectEqual(@as(usize, 2), profiler.cardinality.distinctCount());
}

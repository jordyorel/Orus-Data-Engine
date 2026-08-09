const std = @import("std");
const value = @import("../core/value.zig");
const cardinality = @import("cardinality.zig");
const pattern_detect = @import("pattern_detect.zig");

pub const NumericProfile = struct {
    min: f64,
    max: f64,
    mean: f64,
    variance: ?f64,
};

pub const DecimalProfile = struct {
    min: []const u8,
    max: []const u8,
};

pub const LengthProfile = struct {
    min: usize,
    max: usize,
    mean: f64,
};

pub const ColumnProfile = struct {
    name: []const u8,
    tag: value.ValueTag,
    nullable: bool,
    null_count: u64,
    null_rate: f64,
    distinct_count: usize,
    cardinality_mode: cardinality.Mode,
    numeric: ?NumericProfile = null,
    decimal: ?DecimalProfile = null,
    length: ?LengthProfile = null,
    detected_pattern: ?pattern_detect.PatternTag = null,
};

pub const ProfileReport = struct {
    columns: []const ColumnProfile,
    rows_processed: u64,
    batches_processed: u64,
    source_id: u128,
    schema_hash: u64,

    pub fn deinit(self: *ProfileReport, allocator: std.mem.Allocator) void {
        for (self.columns) |item| {
            allocator.free(item.name);
            if (item.decimal) |decimal| {
                allocator.free(decimal.min);
                allocator.free(decimal.max);
            }
        }
        allocator.free(self.columns);
    }

    /// Caller owns the returned JSON bytes.
    pub fn toJson(self: *const ProfileReport, allocator: std.mem.Allocator) ![]u8 {
        var output: std.Io.Writer.Allocating = .init(allocator);
        errdefer output.deinit();
        var stringify: std.json.Stringify = .{
            .writer = &output.writer,
            .options = .{ .whitespace = .indent_2 },
        };
        try stringify.write(self);
        return output.toOwnedSlice();
    }
};

test "profile report serializes valid JSON" {
    const columns = [_]ColumnProfile{.{
        .name = "id",
        .tag = .i64,
        .nullable = false,
        .null_count = 0,
        .null_rate = 0,
        .distinct_count = 2,
        .cardinality_mode = .exact,
        .numeric = .{ .min = 1, .max = 2, .mean = 1.5, .variance = 0.5 },
    }};
    const report = ProfileReport{
        .columns = &columns,
        .rows_processed = 2,
        .batches_processed = 1,
        .source_id = 0,
        .schema_hash = 1,
    };
    const json = try report.toJson(std.testing.allocator);
    defer std.testing.allocator.free(json);
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json, .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(i64, 2), parsed.value.object.get("rows_processed").?.integer);
}

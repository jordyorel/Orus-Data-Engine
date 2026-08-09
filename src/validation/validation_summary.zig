const std = @import("std");
const violation = @import("violation.zig");

pub const RuleCount = struct { rule_id: u32, count: u64 = 0 };
pub const ColumnCount = struct { column_index: u32, count: u64 = 0 };

pub const ValidationSummary = struct {
    total_violations: u64 = 0,
    violations_by_rule: []RuleCount = &.{},
    violations_by_column: []ColumnCount = &.{},
    rows_with_violations: u64 = 0,
    rows_processed: u64 = 0,
    batches_processed: u64 = 0,
    unique_rules_spilled: u32 = 0,
    output_truncated: bool = false,
    samples: []const violation.Violation = &.{},

    /// Caller owns the returned JSON bytes.
    pub fn toJson(self: *const ValidationSummary, allocator: std.mem.Allocator) ![]u8 {
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

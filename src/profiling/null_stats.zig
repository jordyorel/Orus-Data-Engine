const column = @import("../core/column.zig");

pub const NullStats = struct {
    null_count: u64 = 0,
    total_count: u64 = 0,

    pub fn update(self: *NullStats, input: *const column.Column) void {
        self.null_count += input.nulls.countSet();
        self.total_count += input.len;
    }

    pub fn nullRate(self: NullStats) f64 {
        if (self.total_count == 0) return 0;
        return @as(f64, @floatFromInt(self.null_count)) /
            @as(f64, @floatFromInt(self.total_count));
    }
};

test "null stats accumulate batches" {
    const bitmap = @import("../core/bitmap.zig");
    const words = [_]u64{0b101};
    const input = column.Column{
        .tag = .i64,
        .len = 3,
        .nulls = bitmap.NullBitmap{ .words = &words, .len = 3 },
        .data = .{ .i64 = &.{ 0, 1, 0 } },
    };
    var stats = NullStats{};
    stats.update(&input);
    try @import("std").testing.expectEqual(@as(u64, 2), stats.null_count);
}

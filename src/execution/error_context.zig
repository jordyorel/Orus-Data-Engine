const std = @import("std");

pub const Frame = struct {
    stage: []const u8,
    batch_id: ?u64 = null,
    row_offset: ?u64 = null,
    column_index: ?u32 = null,
};

/// Fixed-capacity diagnostic stack. Frames borrow run-lifetime strings and
/// never grow with the number of processed rows.
pub const ErrorContext = struct {
    pub const capacity = 16;
    frames: [capacity]Frame = undefined,
    len: usize = 0,

    pub fn push(self: *ErrorContext, frame: Frame) !void {
        if (self.len == capacity) return error.ErrorContextFull;
        self.frames[self.len] = frame;
        self.len += 1;
    }

    pub fn pop(self: *ErrorContext) void {
        std.debug.assert(self.len != 0);
        self.len -= 1;
    }

    pub fn clear(self: *ErrorContext) void {
        self.len = 0;
    }

    pub fn items(self: *const ErrorContext) []const Frame {
        return self.frames[0..self.len];
    }
};

test "error context has a fixed capacity" {
    var context = ErrorContext{};
    try context.push(.{ .stage = "csv", .row_offset = 12 });
    try std.testing.expectEqual(@as(usize, 1), context.items().len);
    context.pop();
    try std.testing.expectEqual(@as(usize, 0), context.items().len);
}

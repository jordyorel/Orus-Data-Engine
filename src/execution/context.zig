const std = @import("std");
const allocators = @import("allocators.zig");
const error_context = @import("error_context.zig");
const metrics = @import("metrics.zig");

pub const ExecutionContext = struct {
    allocators: allocators.PipelineAllocators,
    error_context: error_context.ErrorContext = .{},
    metrics: metrics.Metrics = .{},
    run_id: u128,
    temp_dir: []const u8,

    pub fn init(
        backing: std.mem.Allocator,
        run_id: u128,
        temp_dir: []const u8,
    ) !ExecutionContext {
        var result = ExecutionContext{
            .allocators = allocators.PipelineAllocators.init(backing),
            .run_id = run_id,
            .temp_dir = undefined,
        };
        errdefer result.allocators.deinit();
        result.temp_dir = try result.allocators.run().dupe(u8, temp_dir);
        return result;
    }

    pub fn deinit(self: *ExecutionContext) void {
        self.allocators.deinit();
    }
};

test "execution context owns run metadata" {
    var context = try ExecutionContext.init(std.testing.allocator, 42, "/tmp/orus");
    defer context.deinit();
    try std.testing.expectEqual(@as(u128, 42), context.run_id);
    try std.testing.expectEqualStrings("/tmp/orus", context.temp_dir);
}

const std = @import("std");
const match_result = @import("match_result.zig");

pub const MatchSink = struct {
    ptr: *anyopaque,
    write_fn: *const fn (*anyopaque, []const match_result.MatchResult) anyerror!void,
    finish_fn: *const fn (*anyopaque) anyerror!void,
    abort_fn: *const fn (*anyopaque) void,

    pub fn write(self: MatchSink, results: []const match_result.MatchResult) !void {
        try self.write_fn(self.ptr, results);
    }

    pub fn finish(self: MatchSink) !void {
        try self.finish_fn(self.ptr);
    }

    pub fn abort(self: MatchSink) void {
        self.abort_fn(self.ptr);
    }
};

pub const SamplingSink = struct {
    allocator: std.mem.Allocator,
    limit: usize,
    samples: std.ArrayList(match_result.MatchResult) = .empty,
    total: u64 = 0,
    finished: bool = false,
    aborted: bool = false,

    pub fn init(allocator: std.mem.Allocator, limit: usize) SamplingSink {
        return .{ .allocator = allocator, .limit = limit };
    }

    pub fn deinit(self: *SamplingSink) void {
        self.samples.deinit(self.allocator);
    }

    pub fn asSink(self: *SamplingSink) MatchSink {
        return .{ .ptr = self, .write_fn = writeOpaque, .finish_fn = finishOpaque, .abort_fn = abortOpaque };
    }

    pub fn truncated(self: *const SamplingSink) bool {
        return self.total > self.samples.items.len;
    }

    fn writeOpaque(ptr: *anyopaque, results: []const match_result.MatchResult) !void {
        const self: *SamplingSink = @ptrCast(@alignCast(ptr));
        if (self.finished or self.aborted) return error.MatchSinkClosed;
        self.total += results.len;
        const retained = @min(self.limit -| self.samples.items.len, results.len);
        try self.samples.appendSlice(self.allocator, results[0..retained]);
    }

    fn finishOpaque(ptr: *anyopaque) !void {
        const self: *SamplingSink = @ptrCast(@alignCast(ptr));
        if (self.aborted) return error.MatchSinkAborted;
        self.finished = true;
    }

    fn abortOpaque(ptr: *anyopaque) void {
        const self: *SamplingSink = @ptrCast(@alignCast(ptr));
        self.aborted = true;
    }
};

test "sampling match sink bounds retained results" {
    var output = SamplingSink.init(std.testing.allocator, 1);
    defer output.deinit();
    const results = [_]match_result.MatchResult{
        .{ .left = .{}, .right = .{}, .score = 1, .method = .exact, .scorer_version = 1 },
        .{ .left = .{}, .right = .{}, .score = 1, .method = .exact, .scorer_version = 1 },
    };
    try output.asSink().write(&results);
    try std.testing.expect(output.truncated());
    try std.testing.expectEqual(@as(usize, 1), output.samples.items.len);
}

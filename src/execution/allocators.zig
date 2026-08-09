const std = @import("std");
const arena_pool = @import("../core/arena_pool.zig");

pub const ScratchArena = struct {
    arena: std.heap.ArenaAllocator,

    pub fn init(backing: std.mem.Allocator) ScratchArena {
        return .{ .arena = std.heap.ArenaAllocator.init(backing) };
    }

    pub fn allocator(self: *ScratchArena) std.mem.Allocator {
        return self.arena.allocator();
    }

    pub fn reset(self: *ScratchArena) void {
        _ = self.arena.reset(.retain_capacity);
    }

    pub fn deinit(self: *ScratchArena) void {
        self.arena.deinit();
    }
};

/// Owns every allocation domain used by one pipeline execution.
pub const PipelineAllocators = struct {
    run_arena: std.heap.ArenaAllocator,
    batches: arena_pool.BatchArenaPool,
    scratch: ScratchArena,

    pub fn init(backing: std.mem.Allocator) PipelineAllocators {
        return .{
            .run_arena = std.heap.ArenaAllocator.init(backing),
            .batches = arena_pool.BatchArenaPool.init(backing),
            .scratch = ScratchArena.init(backing),
        };
    }

    pub fn run(self: *PipelineAllocators) std.mem.Allocator {
        return self.run_arena.allocator();
    }

    pub fn deinit(self: *PipelineAllocators) void {
        self.scratch.deinit();
        self.batches.deinit();
        self.run_arena.deinit();
    }
};

test "pipeline allocators isolate run, batch, and scratch lifetimes" {
    var allocators = PipelineAllocators.init(std.testing.allocator);
    defer allocators.deinit();

    const persistent = try allocators.run().dupe(u8, "run");
    _ = try allocators.batches.input().allocator().dupe(u8, "batch");
    _ = try allocators.scratch.allocator().dupe(u8, "scratch");

    allocators.batches.input().reset();
    allocators.scratch.reset();
    try std.testing.expectEqualStrings("run", persistent);
}

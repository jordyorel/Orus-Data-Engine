const std = @import("std");

pub const BatchArena = struct {
    arena: std.heap.ArenaAllocator,

    pub fn init(backing: std.mem.Allocator) BatchArena {
        return .{ .arena = std.heap.ArenaAllocator.init(backing) };
    }
    pub fn allocator(self: *BatchArena) std.mem.Allocator {
        return self.arena.allocator();
    }
    pub fn reset(self: *BatchArena) void {
        _ = self.arena.reset(.retain_capacity);
    }
    pub fn deinit(self: *BatchArena) void {
        self.arena.deinit();
    }
};

pub const BatchArenaPool = struct {
    arenas: [2]BatchArena,
    input_index: u1 = 0,

    pub fn init(backing: std.mem.Allocator) BatchArenaPool {
        return .{ .arenas = .{ BatchArena.init(backing), BatchArena.init(backing) } };
    }
    pub fn input(self: *BatchArenaPool) *BatchArena {
        return &self.arenas[self.input_index];
    }
    pub fn output(self: *BatchArenaPool) *BatchArena {
        return &self.arenas[self.input_index ^ 1];
    }
    pub fn swap(self: *BatchArenaPool) void {
        self.input_index ^= 1;
        self.output().reset();
    }
    pub fn deinit(self: *BatchArenaPool) void {
        self.arenas[0].deinit();
        self.arenas[1].deinit();
    }
};

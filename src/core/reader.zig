const arena_pool = @import("arena_pool.zig");
const batch = @import("batch.zig");

/// Pull-based batch reader. The concrete reader owns its state; this value is
/// only a non-owning dispatch handle.
pub const Reader = struct {
    ptr: *anyopaque,
    next_fn: *const fn (*anyopaque, *arena_pool.BatchArena) anyerror!?batch.Batch,

    pub fn next(self: Reader, output: *arena_pool.BatchArena) !?batch.Batch {
        return self.next_fn(self.ptr, output);
    }
};

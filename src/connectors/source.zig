const arena_pool = @import("../core/arena_pool.zig");
const batch = @import("../core/batch.zig");
const schema_mod = @import("../core/schema.zig");
const source_identity = @import("../core/source_identity.zig");

pub const SourceCapabilities = packed struct {
    replayable: bool = false,
    seekable: bool = false,
    bounded: bool = true,
    schema_known: bool = false,
};

/// Non-owning interface over a concrete connector.
pub const Source = struct {
    ptr: *anyopaque,
    next_raw_fn: *const fn (*anyopaque, *arena_pool.BatchArena) anyerror!?batch.Batch,
    schema_fn: *const fn (*anyopaque) ?*const schema_mod.Schema,
    identity_fn: *const fn (*anyopaque) source_identity.SourceIdentity,
    capabilities_fn: *const fn (*anyopaque) SourceCapabilities,
    bytes_read_fn: *const fn (*anyopaque) u64,

    pub fn nextRaw(self: Source, output: *arena_pool.BatchArena) !?batch.Batch {
        return self.next_raw_fn(self.ptr, output);
    }

    pub fn schema(self: Source) ?*const schema_mod.Schema {
        return self.schema_fn(self.ptr);
    }

    pub fn identity(self: Source) source_identity.SourceIdentity {
        return self.identity_fn(self.ptr);
    }

    pub fn capabilities(self: Source) SourceCapabilities {
        return self.capabilities_fn(self.ptr);
    }

    pub fn bytesRead(self: Source) u64 {
        return self.bytes_read_fn(self.ptr);
    }
};

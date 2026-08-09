const std = @import("std");
const blocking = @import("blocking.zig");
const exact_match = @import("exact_match.zig");
const RowId = @import("../validation/violation.zig").RowId;

pub const default_memory_limit = 64 * 1024 * 1024;
const record_header_size = 40;

pub const Entry = struct {
    row_id: RowId,
    key: exact_match.ExactMatchKey,
};

const Bucket = struct { head: ?u32 = null };
const Node = struct { entry: Entry, next: ?u32 };

pub const CandidateIterator = struct {
    nodes: []const Node,
    current: ?u32,

    pub fn next(self: *CandidateIterator) ?Entry {
        const index = self.current orelse return null;
        const node = self.nodes[index];
        self.current = node.next;
        return node.entry;
    }
};

const BoundedAllocator = struct {
    backing: std.mem.Allocator,
    limit: usize,
    live: usize = 0,
    peak: usize = 0,

    fn allocator(self: *BoundedAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable = std.mem.Allocator.VTable{
        .alloc = allocate,
        .resize = resize,
        .remap = remap,
        .free = free,
    };

    fn allocate(
        ptr: *anyopaque,
        len: usize,
        alignment: std.mem.Alignment,
        return_address: usize,
    ) ?[*]u8 {
        const self: *BoundedAllocator = @ptrCast(@alignCast(ptr));
        if (len > self.limit - self.live) return null;
        const result = self.backing.rawAlloc(len, alignment, return_address) orelse return null;
        self.live += len;
        self.peak = @max(self.peak, self.live);
        return result;
    }

    fn resize(
        ptr: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        return_address: usize,
    ) bool {
        const self: *BoundedAllocator = @ptrCast(@alignCast(ptr));
        if (new_len > memory.len and new_len - memory.len > self.limit - self.live) return false;
        if (!self.backing.rawResize(memory, alignment, new_len, return_address)) return false;
        self.live = self.live - memory.len + new_len;
        self.peak = @max(self.peak, self.live);
        return true;
    }

    fn remap(
        ptr: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        return_address: usize,
    ) ?[*]u8 {
        const self: *BoundedAllocator = @ptrCast(@alignCast(ptr));
        if (new_len > memory.len and new_len - memory.len > self.limit - self.live) return null;
        const result = self.backing.rawRemap(memory, alignment, new_len, return_address) orelse return null;
        self.live = self.live - memory.len + new_len;
        self.peak = @max(self.peak, self.live);
        return result;
    }

    fn free(
        ptr: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        return_address: usize,
    ) void {
        const self: *BoundedAllocator = @ptrCast(@alignCast(ptr));
        std.debug.assert(memory.len <= self.live);
        self.live -= memory.len;
        self.backing.rawFree(memory, alignment, return_address);
    }
};

pub const MatchIndex = struct {
    allocator: std.mem.Allocator,
    bounded: BoundedAllocator,
    buckets: std.StringHashMapUnmanaged(Bucket) = .empty,
    nodes: std.ArrayList(Node) = .empty,
    strategy: blocking.Strategy,
    rows_indexed: u64 = 0,
    finalized: bool = false,

    pub fn init(
        allocator: std.mem.Allocator,
        memory_limit: usize,
        strategy: blocking.Strategy,
    ) !MatchIndex {
        if (memory_limit == 0) return error.InvalidMatchIndexMemoryLimit;
        return .{
            .allocator = allocator,
            .bounded = .{ .backing = allocator, .limit = memory_limit },
            .strategy = strategy,
        };
    }

    pub fn deinit(self: *MatchIndex) void {
        const allocator = self.bounded.allocator();
        switch (self.strategy) {
            .exact_normalized => {},
            else => for (self.nodes.items) |node| allocator.free(node.entry.key.normalized_value),
        }
        var keys = self.buckets.keyIterator();
        while (keys.next()) |key| allocator.free(key.*);
        self.nodes.deinit(allocator);
        self.buckets.deinit(allocator);
        std.debug.assert(self.bounded.live == 0);
    }

    pub fn insert(self: *MatchIndex, normalized: []const u8, row_id: RowId) !void {
        if (self.finalized) return error.MatchIndexFinalized;
        const block = try blocking.key(normalized, self.strategy);
        var bucket = self.buckets.getPtr(block);
        if (bucket == null) {
            self.buckets.ensureUnusedCapacity(self.bounded.allocator(), 1) catch
                return error.MatchIndexMemoryLimit;
            const owned_block = self.bounded.allocator().dupe(u8, block) catch
                return error.MatchIndexMemoryLimit;
            self.buckets.putAssumeCapacity(owned_block, .{});
            bucket = self.buckets.getPtr(owned_block).?;
        }
        const owned_value = switch (self.strategy) {
            .exact_normalized => self.buckets.getKey(block).?,
            else => self.bounded.allocator().dupe(u8, normalized) catch
                return error.MatchIndexMemoryLimit,
        };
        const node_index: u32 = std.math.cast(u32, self.nodes.items.len) orelse
            return error.MatchIndexCapacityExceeded;
        self.nodes.append(self.bounded.allocator(), .{
            .entry = .{
                .row_id = row_id,
                .key = exact_match.ExactMatchKey.init(owned_value),
            },
            .next = bucket.?.head,
        }) catch return error.MatchIndexMemoryLimit;
        bucket.?.head = node_index;
        self.rows_indexed += 1;
    }

    pub fn finalize(self: *MatchIndex) void {
        self.finalized = true;
    }

    pub fn candidates(self: *const MatchIndex, normalized: []const u8) !CandidateIterator {
        if (!self.finalized) return error.MatchIndexNotFinalized;
        const block = try blocking.key(normalized, self.strategy);
        const bucket = self.buckets.get(block);
        return .{ .nodes = self.nodes.items, .current = if (bucket) |found| found.head else null };
    }

    pub fn peakMemoryUsed(self: *const MatchIndex) usize {
        return self.bounded.peak;
    }
};

pub const PartitionRecord = struct {
    row_id: RowId,
    normalized: []const u8,
};

pub const PartitionStore = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    prefix: []u8,
    partition_count: usize,
    files: []std.Io.File,
    writers: []std.Io.File.Writer,
    buffers: []u8,
    open_writers: usize = 0,
    bytes_written: u64 = 0,

    pub fn init(
        io: std.Io,
        allocator: std.mem.Allocator,
        prefix: []const u8,
        partition_count: usize,
    ) !PartitionStore {
        if (partition_count == 0 or partition_count > 4096) return error.InvalidPartitionCount;
        const owned_prefix = try allocator.dupe(u8, prefix);
        errdefer allocator.free(owned_prefix);
        const files = try allocator.alloc(std.Io.File, partition_count);
        errdefer allocator.free(files);
        const writers = try allocator.alloc(std.Io.File.Writer, partition_count);
        errdefer allocator.free(writers);
        const buffers = try allocator.alloc(u8, partition_count * 16 * 1024);
        errdefer allocator.free(buffers);
        var self = PartitionStore{
            .allocator = allocator,
            .io = io,
            .prefix = owned_prefix,
            .partition_count = partition_count,
            .files = files,
            .writers = writers,
            .buffers = buffers,
        };
        errdefer {
            const created = self.open_writers;
            self.abort();
            for (0..created) |partition| {
                const created_path = self.partitionPath(partition) catch |err| {
                    std.log.err("cannot build failed spill cleanup path: {s}", .{@errorName(err)});
                    continue;
                };
                defer allocator.free(created_path);
                std.Io.Dir.cwd().deleteFile(io, created_path) catch |err| switch (err) {
                    error.FileNotFound => {},
                    else => std.log.err("cannot remove failed spill file {s}: {s}", .{
                        created_path,
                        @errorName(err),
                    }),
                };
            }
        }
        for (0..partition_count) |partition| {
            const path = try self.partitionPath(partition);
            defer allocator.free(path);
            self.files[partition] = try std.Io.Dir.cwd().createFile(io, path, .{
                .truncate = true,
                .exclusive = true,
            });
            self.open_writers += 1;
            const start = partition * 16 * 1024;
            self.writers[partition] = self.files[partition].writerStreaming(io, self.buffers[start..][0 .. 16 * 1024]);
        }
        return self;
    }

    pub fn write(
        self: *PartitionStore,
        normalized: []const u8,
        row_id: RowId,
        strategy: blocking.Strategy,
    ) !void {
        if (self.open_writers != self.partition_count) return error.PartitionStoreClosed;
        if (normalized.len > std.math.maxInt(u32)) return error.MatchValueTooLong;
        const block = try blocking.key(normalized, strategy);
        const partition = std.hash.Wyhash.hash(0, block) % self.partition_count;
        const writer = &self.writers[partition].interface;
        try writer.writeInt(u128, row_id.source_id, .little);
        try writer.writeInt(u64, row_id.batch_id, .little);
        try writer.writeInt(u32, row_id.row_in_batch, .little);
        try writer.writeInt(u64, row_id.global_offset, .little);
        try writer.writeInt(u32, @intCast(normalized.len), .little);
        try writer.writeAll(normalized);
        self.bytes_written += record_header_size + normalized.len;
    }

    pub fn finish(self: *PartitionStore) !void {
        var first_error: ?anyerror = null;
        for (0..self.open_writers) |partition| {
            self.writers[partition].interface.flush() catch |err| if (first_error == null) {
                first_error = err;
            };
            self.files[partition].close(self.io);
        }
        self.open_writers = 0;
        if (first_error) |err| return err;
    }

    pub fn openReader(self: *const PartitionStore, partition: usize, buffer: []u8) !std.Io.File.Reader {
        if (self.open_writers != 0) return error.PartitionStoreNotFinished;
        if (partition >= self.partition_count) return error.InvalidPartition;
        const path = try self.partitionPath(partition);
        defer self.allocator.free(path);
        const file = try std.Io.Dir.cwd().openFile(self.io, path, .{});
        return file.readerStreaming(self.io, buffer);
    }

    pub fn readRecord(reader: *std.Io.Reader, value_buffer: []u8) !?PartitionRecord {
        var header: [record_header_size]u8 = undefined;
        const read = try reader.readSliceShort(&header);
        if (read == 0) return null;
        if (read != header.len) return error.CorruptMatchPartition;
        const length = std.mem.readInt(u32, header[36..40], .little);
        if (length > value_buffer.len) return error.MatchValueExceedsBuffer;
        try reader.readSliceAll(value_buffer[0..length]);
        return .{
            .row_id = .{
                .source_id = std.mem.readInt(u128, header[0..16], .little),
                .batch_id = std.mem.readInt(u64, header[16..24], .little),
                .row_in_batch = std.mem.readInt(u32, header[24..28], .little),
                .global_offset = std.mem.readInt(u64, header[28..36], .little),
            },
            .normalized = value_buffer[0..length],
        };
    }

    pub fn deinit(self: *PartitionStore) void {
        self.abort();
        for (0..self.partition_count) |partition| {
            const path = self.partitionPath(partition) catch |err| {
                std.log.err("cannot build spill cleanup path: {s}", .{@errorName(err)});
                continue;
            };
            defer self.allocator.free(path);
            std.Io.Dir.cwd().deleteFile(self.io, path) catch |err| switch (err) {
                error.FileNotFound => {},
                else => std.log.err("cannot remove spill file {s}: {s}", .{ path, @errorName(err) }),
            };
        }
        self.allocator.free(self.buffers);
        self.allocator.free(self.writers);
        self.allocator.free(self.files);
        self.allocator.free(self.prefix);
    }

    fn abort(self: *PartitionStore) void {
        for (0..self.open_writers) |partition| self.files[partition].close(self.io);
        self.open_writers = 0;
    }

    fn partitionPath(self: *const PartitionStore, partition: usize) ![]u8 {
        return std.fmt.allocPrint(self.allocator, "{s}-{d}.bin", .{ self.prefix, partition });
    }
};

test "index returns blocked candidates and enforces its memory limit" {
    var index = try MatchIndex.init(std.testing.allocator, 64 * 1024, .{ .prefix = 2 });
    defer index.deinit();
    try index.insert("alice", .{ .global_offset = 1 });
    try index.insert("alina", .{ .global_offset = 2 });
    try index.insert("bob", .{ .global_offset = 3 });
    index.finalize();
    var candidates = try index.candidates("alfred");
    try std.testing.expect(candidates.next() != null);
    try std.testing.expect(candidates.next() != null);
    try std.testing.expect(candidates.next() == null);
    var missing = try index.candidates("charlie");
    try std.testing.expect(missing.next() == null);

    var limited = try MatchIndex.init(std.testing.allocator, 1, .exact_normalized);
    defer limited.deinit();
    try std.testing.expectError(
        error.MatchIndexMemoryLimit,
        limited.insert("value", .{}),
    );
}

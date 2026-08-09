const std = @import("std");
const column_mod = @import("../core/column.zig");
const c = @cImport({
    @cInclude("sqlite3.h");
});

pub const default_memory_limit = 16 * 1024 * 1024;

/// Exact adaptive set. Keys begin in process memory and migrate to a temporary
/// SQLite B-tree when the configured ownership estimate is reached.
pub const Tracker = struct {
    allocator: std.mem.Allocator,
    memory_limit: usize,
    memory: []u8,
    fixed: std.heap.FixedBufferAllocator,
    values: std.StringHashMapUnmanaged(void) = .empty,
    database: ?*c.sqlite3 = null,
    insert: ?*c.sqlite3_stmt = null,
    spilled: bool = false,

    pub fn init(allocator: std.mem.Allocator, memory_limit: usize) !Tracker {
        if (memory_limit == 0) return error.InvalidUniqueMemoryLimit;
        const memory = try allocator.alloc(u8, memory_limit);
        return .{
            .allocator = allocator,
            .memory_limit = memory_limit,
            .memory = memory,
            .fixed = std.heap.FixedBufferAllocator.init(memory),
        };
    }

    pub fn deinit(self: *Tracker) void {
        if (self.insert) |statement| _ = c.sqlite3_finalize(statement);
        if (self.database) |database| _ = c.sqlite3_close(database);
        self.values.deinit(self.fixed.allocator());
        self.allocator.free(self.memory);
    }

    /// Returns true when `key` has already appeared.
    pub fn observe(self: *Tracker, key: []const u8) !bool {
        if (self.database != null) return self.observeSpilled(key);
        if (self.values.contains(key)) return true;
        self.values.ensureUnusedCapacity(self.fixed.allocator(), 1) catch {
            try self.spill();
            return self.observeSpilled(key);
        };
        const owned = self.fixed.allocator().dupe(u8, key) catch {
            try self.spill();
            return self.observeSpilled(key);
        };
        self.values.putAssumeCapacity(owned, {});
        return false;
    }

    fn spill(self: *Tracker) !void {
        var database: ?*c.sqlite3 = null;
        if (c.sqlite3_open("", &database) != c.SQLITE_OK) return error.UniqueSpillOpenFailed;
        errdefer _ = c.sqlite3_close(database);
        if (c.sqlite3_exec(
            database,
            "PRAGMA temp_store=FILE; PRAGMA cache_size=-2048; " ++
                "PRAGMA journal_mode=OFF; PRAGMA synchronous=OFF; " ++
                "CREATE TABLE seen (value BLOB PRIMARY KEY) WITHOUT ROWID; " ++
                "BEGIN IMMEDIATE",
            null,
            null,
            null,
        ) != c.SQLITE_OK) return error.UniqueSpillInitializeFailed;
        var statement: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(
            database,
            "INSERT OR IGNORE INTO seen(value) VALUES (?)",
            -1,
            &statement,
            null,
        ) != c.SQLITE_OK) return error.UniqueSpillPrepareFailed;
        errdefer _ = c.sqlite3_finalize(statement);

        self.database = database;
        self.insert = statement;
        var iterator = self.values.keyIterator();
        while (iterator.next()) |key| {
            _ = try self.observeSpilled(key.*);
        }
        self.values = .empty;
        self.fixed.reset();
        self.spilled = true;
    }

    fn observeSpilled(self: *Tracker, key: []const u8) !bool {
        const statement = self.insert.?;
        // `step` completes before `key` can be released, so SQLITE_STATIC
        // semantics are valid and avoid Zig's invalid -1 function pointer cast.
        if (c.sqlite3_bind_blob(statement, 1, key.ptr, @intCast(key.len), null) != c.SQLITE_OK) {
            return error.UniqueSpillBindFailed;
        }
        defer {
            _ = c.sqlite3_reset(statement);
            _ = c.sqlite3_clear_bindings(statement);
        }
        if (c.sqlite3_step(statement) != c.SQLITE_DONE) return error.UniqueSpillWriteFailed;
        return c.sqlite3_changes(self.database.?) == 0;
    }
};

pub fn canonicalKey(input: *const column_mod.Column, row: usize, buffer: *[80]u8) ![]const u8 {
    return switch (input.data) {
        .string => |values| values.get(row),
        .i64 => |values| std.fmt.bufPrint(buffer, "{d}", .{values[row]}),
        .f64 => |values| std.fmt.bufPrint(buffer, "{x}", .{@as(u64, @bitCast(normalizeFloat(values[row])))}),
        .decimal => |values| normalizeDecimal(values[row]).formatInto(buffer),
        .boolean => |values| if (values.isSet(row)) "1" else "0",
        .date => |values| std.fmt.bufPrint(buffer, "{d}", .{values[row]}),
        .datetime => |values| std.fmt.bufPrint(buffer, "{d}", .{values[row]}),
    };
}

fn normalizeFloat(value: f64) f64 {
    return if (value == 0) 0 else value;
}

fn normalizeDecimal(value: @import("../core/decimal.zig").Decimal128) @TypeOf(value) {
    var result = value;
    while (result.scale > 0 and @rem(result.coefficient, 10) == 0) {
        result.coefficient = @divExact(result.coefficient, 10);
        result.scale -= 1;
    }
    return result;
}

test "unique tracker remains exact after spilling" {
    var tracker = try Tracker.init(std.testing.allocator, 40);
    defer tracker.deinit();
    try std.testing.expect(!try tracker.observe("alpha"));
    try std.testing.expect(!try tracker.observe("beta"));
    try std.testing.expect(!try tracker.observe("gamma"));
    try std.testing.expect(tracker.spilled);
    try std.testing.expect(try tracker.observe("alpha"));
    try std.testing.expect(try tracker.observe("gamma"));
    try std.testing.expect(!try tracker.observe("delta"));
}

test "unique tracker stays in memory below its hard limit" {
    var tracker = try Tracker.init(std.testing.allocator, 64 * 1024);
    defer tracker.deinit();
    try std.testing.expect(!try tracker.observe("alpha"));
    try std.testing.expect(!try tracker.observe("beta"));
    try std.testing.expect(try tracker.observe("alpha"));
    try std.testing.expect(!tracker.spilled);
}

test "canonical decimal keys ignore insignificant trailing zeroes" {
    const decimal = @import("../core/decimal.zig").Decimal128;
    const first = normalizeDecimal(try decimal.parse("1.0", .{}));
    const second = normalizeDecimal(try decimal.parse("1.00", .{}));
    var first_buffer: [80]u8 = undefined;
    var second_buffer: [80]u8 = undefined;
    try std.testing.expectEqualStrings(
        try first.formatInto(&first_buffer),
        try second.formatInto(&second_buffer),
    );
}

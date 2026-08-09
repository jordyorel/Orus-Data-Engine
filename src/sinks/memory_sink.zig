const std = @import("std");
const arena_pool = @import("../core/arena_pool.zig");
const batch_mod = @import("../core/batch.zig");
const schema_mod = @import("../core/schema.zig");
const sink_mod = @import("../core/sink.zig");

pub const MemorySink = struct {
    arena: arena_pool.BatchArena,
    max_rows: usize,
    max_payload_bytes: usize,
    payload_bytes: usize = 0,
    schema_value: ?schema_mod.Schema = null,
    builder: ?batch_mod.Builder = null,
    result: ?batch_mod.Batch = null,
    finished: bool = false,
    aborted: bool = false,

    pub fn init(
        allocator: std.mem.Allocator,
        max_rows: usize,
        max_payload_bytes: usize,
    ) !MemorySink {
        if (max_rows == 0) return error.InvalidMemorySinkRowLimit;
        if (max_payload_bytes == 0) return error.InvalidMemorySinkByteLimit;
        return .{
            .arena = .init(allocator),
            .max_rows = max_rows,
            .max_payload_bytes = max_payload_bytes,
        };
    }

    pub fn deinit(self: *MemorySink) void {
        self.arena.deinit();
    }

    pub fn asSink(self: *MemorySink) sink_mod.Sink {
        return .{ .ptr = self, .write_fn = writeOpaque, .finish_fn = finishOpaque, .abort_fn = abortOpaque };
    }

    pub fn write(self: *MemorySink, input: *const batch_mod.Batch) !void {
        if (self.finished or self.aborted) return error.SinkClosed;
        if (input.row_count > self.max_rows -| self.rowsWritten()) return error.MemorySinkRowLimit;
        const batch_bytes = payloadSize(input);
        if (batch_bytes > self.max_payload_bytes -| self.payload_bytes) return error.MemorySinkByteLimit;
        if (self.schema_value == null) try self.prepareSchema(input.schema);
        if (!self.schema_value.?.equals(input.schema)) return error.MemorySinkSchemaMismatch;
        for (0..input.row_count) |row| {
            for (input.columns, 0..) |*column, index| {
                if (column.isNull(row)) {
                    try self.builder.?.appendNull(index);
                    continue;
                }
                switch (column.data) {
                    .i64 => |items| try self.builder.?.appendI64(index, items[row]),
                    .f64 => |items| try self.builder.?.appendF64(index, items[row]),
                    .decimal => |items| try self.builder.?.appendDecimal(index, items[row]),
                    .boolean => |items| try self.builder.?.appendBoolean(index, items.isSet(row)),
                    .string => |items| try self.builder.?.appendString(index, items.get(row)),
                    .date => |items| try self.builder.?.appendDate(index, items[row]),
                    .datetime => |items| try self.builder.?.appendDateTime(index, items[row]),
                }
            }
            try self.builder.?.finishRow();
        }
        self.payload_bytes += batch_bytes;
    }

    pub fn finish(self: *MemorySink) !void {
        if (self.aborted) return error.SinkAborted;
        if (self.finished) return;
        if (self.builder) |*builder| self.result = try builder.finish(.{});
        self.finished = true;
    }

    /// Returns a stable batch owned by this sink and valid until deinit.
    pub fn batch(self: *const MemorySink) !?*const batch_mod.Batch {
        if (!self.finished) return error.MemorySinkNotFinished;
        return if (self.result) |*result| result else null;
    }

    pub fn rowsWritten(self: *const MemorySink) usize {
        return if (self.builder) |builder| builder.row_count else 0;
    }

    fn prepareSchema(self: *MemorySink, source_schema: *const schema_mod.Schema) !void {
        const allocator = self.arena.allocator();
        const fields = try allocator.alloc(schema_mod.Field, source_schema.fields.len);
        for (source_schema.fields, fields) |source, *field| {
            field.* = source;
            field.name = try allocator.dupe(u8, source.name);
        }
        self.schema_value = .{ .fields = fields, .hash = schema_mod.Schema.computeHash(fields) };
        self.builder = try batch_mod.Builder.init(&self.arena, &self.schema_value.?);
    }

    fn writeOpaque(ptr: *anyopaque, input: *const batch_mod.Batch) !void {
        try (@as(*MemorySink, @ptrCast(@alignCast(ptr)))).write(input);
    }
    fn finishOpaque(ptr: *anyopaque) !void {
        try (@as(*MemorySink, @ptrCast(@alignCast(ptr)))).finish();
    }
    fn abortOpaque(ptr: *anyopaque) void {
        (@as(*MemorySink, @ptrCast(@alignCast(ptr)))).aborted = true;
    }
};

fn payloadSize(input: *const batch_mod.Batch) usize {
    var total: usize = 0;
    for (input.columns) |column| switch (column.data) {
        .i64 => |items| total +|= items.len *| @sizeOf(i64),
        .f64 => |items| total +|= items.len *| @sizeOf(f64),
        .decimal => |items| total +|= items.len *| @sizeOf(@import("../core/decimal.zig").Decimal128),
        .boolean => |items| total +|= items.words.len *| @sizeOf(u64),
        .string => |items| total +|= items.data.len +| items.offsets.len *| @sizeOf(u32),
        .date => |items| total +|= items.len *| @sizeOf(i32),
        .datetime => |items| total +|= items.len *| @sizeOf(i64),
    };
    return total;
}

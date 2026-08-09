const std = @import("std");
const arena_pool = @import("../core/arena_pool.zig");
const batch = @import("../core/batch.zig");
const string_ops = @import("string_ops.zig");

pub const Transform = struct {
    ptr: *const anyopaque,
    id: u128,
    name: []const u8,
    version: u32,
    apply_fn: *const fn (
        *const anyopaque,
        *const batch.Batch,
        *arena_pool.BatchArena,
        std.mem.Allocator,
    ) anyerror!batch.Batch,

    pub fn apply(
        self: Transform,
        input: *const batch.Batch,
        output: *arena_pool.BatchArena,
        scratch: std.mem.Allocator,
    ) !batch.Batch {
        return self.apply_fn(self.ptr, input, output, scratch);
    }
};

pub const StringTransform = struct {
    id: u128,
    column_index: u32,
    operation: string_ops.Operation,

    pub fn asTransform(self: *const StringTransform) Transform {
        return .{
            .ptr = self,
            .id = self.id,
            .name = @tagName(self.operation),
            .version = 1,
            .apply_fn = applyOpaque,
        };
    }

    fn applyOpaque(
        ptr: *const anyopaque,
        input: *const batch.Batch,
        output: *arena_pool.BatchArena,
        scratch: std.mem.Allocator,
    ) !batch.Batch {
        const self: *const StringTransform = @ptrCast(@alignCast(ptr));
        if (self.column_index >= input.columns.len) return error.ColumnIndexOutOfBounds;
        if (input.column(self.column_index).tag != .string) return error.StringColumnRequired;
        var max_output: usize = 0;
        const target = input.column(self.column_index);
        for (0..input.row_count) |row| if (!target.isNull(row)) {
            max_output = @max(max_output, try string_ops.outputLength(
                self.operation,
                target.data.string.get(row),
            ));
        };
        const temporary = try scratch.alloc(u8, max_output);
        var builder = try batch.Builder.init(output, input.schema);
        for (0..input.row_count) |row| {
            for (input.columns, 0..) |*column, index| {
                if (column.isNull(row)) {
                    try builder.appendNull(index);
                } else if (index == self.column_index) {
                    const transformed = try string_ops.apply(
                        self.operation,
                        column.data.string.get(row),
                        temporary,
                    );
                    try builder.appendString(index, transformed);
                } else try appendValue(&builder, index, column, row);
            }
            try builder.finishRow();
        }
        return builder.finish(input.metadata);
    }
};

fn appendValue(builder: *batch.Builder, index: usize, column: *const @import("../core/column.zig").Column, row: usize) !void {
    switch (column.data) {
        .i64 => |items| try builder.appendI64(index, items[row]),
        .f64 => |items| try builder.appendF64(index, items[row]),
        .decimal => |items| try builder.appendDecimal(index, items[row]),
        .boolean => |items| try builder.appendBoolean(index, items.isSet(row)),
        .string => |items| try builder.appendString(index, items.get(row)),
        .date => |items| try builder.appendDate(index, items[row]),
        .datetime => |items| try builder.appendDateTime(index, items[row]),
    }
}

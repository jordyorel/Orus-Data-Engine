const std = @import("std");
const schema_mod = @import("../core/schema.zig");
const string_ops = @import("string_ops.zig");
const transform_mod = @import("transform.zig");

pub const current_format_version: u32 = 1;
pub const string_transform_version: u32 = 1;

pub const Operation = enum { trim, uppercase, lowercase, replace };

pub const TransformSpec = struct {
    id: u128,
    version: u32 = string_transform_version,
    column: []const u8,
    operation: Operation,
    needle: ?[]const u8 = null,
    replacement: ?[]const u8 = null,

    pub fn validate(self: TransformSpec) !void {
        if (self.version != string_transform_version) return error.UnsupportedTransformVersion;
        if (self.column.len == 0) return error.EmptyTransformColumn;
        switch (self.operation) {
            .replace => {
                const needle = self.needle orelse return error.MissingReplaceNeedle;
                _ = self.replacement orelse return error.MissingReplacement;
                if (needle.len == 0) return error.EmptyNeedle;
            },
            else => if (self.needle != null or self.replacement != null) {
                return error.UnexpectedTransformParameter;
            },
        }
    }

    pub fn compile(self: TransformSpec, schema: *const schema_mod.Schema) !transform_mod.StringTransform {
        try self.validate();
        const column_index = schema.indexOf(self.column) orelse return error.UnknownTransformColumn;
        const operation: string_ops.Operation = switch (self.operation) {
            .trim => .trim,
            .uppercase => .uppercase,
            .lowercase => .lowercase,
            .replace => .{ .replace = .{
                .needle = self.needle.?,
                .replacement = self.replacement.?,
            } },
        };
        return .{ .id = self.id, .column_index = @intCast(column_index), .operation = operation };
    }

    pub fn hash(self: TransformSpec, state: *std.hash.XxHash3) void {
        updateInt(state, u128, self.id);
        updateInt(state, u32, self.version);
        updateSlice(state, self.column);
        updateInt(state, u8, @intFromEnum(self.operation));
        updateOptionalSlice(state, self.needle);
        updateOptionalSlice(state, self.replacement);
    }
};

fn updateInt(state: *std.hash.XxHash3, comptime T: type, value: T) void {
    var encoded: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &encoded, value, .little);
    state.update(&encoded);
}

fn updateSlice(state: *std.hash.XxHash3, value: []const u8) void {
    updateInt(state, u64, @intCast(value.len));
    state.update(value);
}

fn updateOptionalSlice(state: *std.hash.XxHash3, value: ?[]const u8) void {
    updateInt(state, u8, @intFromBool(value != null));
    if (value) |present| updateSlice(state, present);
}

pub fn paramsHash(specs: []const TransformSpec) u64 {
    var state = std.hash.XxHash3.init(0);
    for (specs) |spec| spec.hash(&state);
    return state.final();
}

test "transform specs validate compile and hash canonical parameters" {
    const fields = [_]schema_mod.Field{.{ .name = "name" }};
    const schema = schema_mod.Schema{ .fields = &fields, .hash = schema_mod.Schema.computeHash(&fields) };
    const first = TransformSpec{ .id = 1, .column = "name", .operation = .trim };
    const second = TransformSpec{ .id = 1, .column = "name", .operation = .trim };
    const compiled = try first.compile(&schema);
    try std.testing.expectEqual(@as(u32, 0), compiled.column_index);
    try std.testing.expectEqual(paramsHash(&.{first}), paramsHash(&.{second}));
    try std.testing.expectError(
        error.MissingReplaceNeedle,
        (TransformSpec{ .id = 2, .column = "name", .operation = .replace }).validate(),
    );
}

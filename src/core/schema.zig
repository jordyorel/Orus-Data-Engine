const std = @import("std");
const value = @import("value.zig");

pub const Field = struct {
    name: []const u8,
    tag: value.ValueTag = .string,
    nullable: bool = true,
};

pub const Schema = struct {
    fields: []const Field,
    hash: u64,

    /// Releases field names and the field slice with the allocator that built
    /// this schema. The schema owns both.
    pub fn deinit(self: *Schema, allocator: std.mem.Allocator) void {
        for (self.fields) |field| allocator.free(field.name);
        allocator.free(self.fields);
        self.* = undefined;
    }

    pub fn indexOf(self: *const Schema, name: []const u8) ?usize {
        for (self.fields, 0..) |field, index| {
            if (std.mem.eql(u8, field.name, name)) return index;
        }
        return null;
    }

    pub fn equals(self: *const Schema, other: *const Schema) bool {
        if (self.hash != other.hash or self.fields.len != other.fields.len) return false;
        for (self.fields, other.fields) |left, right| {
            if (!std.mem.eql(u8, left.name, right.name)) return false;
            if (left.tag != right.tag or left.nullable != right.nullable) return false;
        }
        return true;
    }

    pub fn computeHash(fields: []const Field) u64 {
        var hash: u64 = 14695981039346656037;
        for (fields) |field| {
            for (field.name) |byte| hash = (hash ^ byte) *% 1099511628211;
            hash = (hash ^ @intFromEnum(field.tag)) *% 1099511628211;
            hash = (hash ^ @intFromBool(field.nullable)) *% 1099511628211;
        }
        return hash;
    }
};

test "schema lookup, hash, and equality include field properties" {
    const fields = [_]Field{
        .{ .name = "id", .nullable = false },
        .{ .name = "name" },
    };
    const same_fields = fields;
    const different_fields = [_]Field{
        .{ .name = "id", .nullable = true },
        .{ .name = "name" },
    };
    const left = Schema{
        .fields = &fields,
        .hash = Schema.computeHash(&fields),
    };
    const same = Schema{
        .fields = &same_fields,
        .hash = Schema.computeHash(&same_fields),
    };
    const different = Schema{
        .fields = &different_fields,
        .hash = Schema.computeHash(&different_fields),
    };

    try std.testing.expectEqual(@as(?usize, 1), left.indexOf("name"));
    try std.testing.expect(left.equals(&same));
    try std.testing.expect(!left.equals(&different));
}

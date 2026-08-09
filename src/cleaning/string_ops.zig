const std = @import("std");

pub const Replace = struct { needle: []const u8, replacement: []const u8 };
pub const Operation = union(enum) {
    trim,
    uppercase,
    lowercase,
    replace: Replace,
};

pub fn outputLength(operation: Operation, input: []const u8) !usize {
    return switch (operation) {
        .trim => std.mem.trim(u8, input, &std.ascii.whitespace).len,
        .uppercase, .lowercase => input.len,
        .replace => |replace| blk: {
            if (replace.needle.len == 0) return error.EmptyNeedle;
            const occurrences = std.mem.count(u8, input, replace.needle);
            const removed = try std.math.mul(usize, occurrences, replace.needle.len);
            const added = try std.math.mul(usize, occurrences, replace.replacement.len);
            break :blk try std.math.add(usize, input.len - removed, added);
        },
    };
}

pub fn apply(operation: Operation, input: []const u8, output: []u8) ![]const u8 {
    const expected = try outputLength(operation, input);
    if (output.len < expected) return error.OutputTooSmall;
    return switch (operation) {
        .trim => std.mem.trim(u8, input, &std.ascii.whitespace),
        .uppercase => mapCase(input, output, true),
        .lowercase => mapCase(input, output, false),
        .replace => |replace| replaceAll(input, output, replace),
    };
}

fn mapCase(input: []const u8, output: []u8, upper: bool) []const u8 {
    for (input, 0..) |byte, index| {
        output[index] = if (upper) std.ascii.toUpper(byte) else std.ascii.toLower(byte);
    }
    return output[0..input.len];
}

fn replaceAll(input: []const u8, output: []u8, replace: Replace) []const u8 {
    var source_index: usize = 0;
    var output_index: usize = 0;
    while (std.mem.indexOfPos(u8, input, source_index, replace.needle)) |match_index| {
        const prefix = input[source_index..match_index];
        @memcpy(output[output_index .. output_index + prefix.len], prefix);
        output_index += prefix.len;
        @memcpy(output[output_index .. output_index + replace.replacement.len], replace.replacement);
        output_index += replace.replacement.len;
        source_index = match_index + replace.needle.len;
    }
    @memcpy(output[output_index..], input[source_index..]);
    return output;
}

test "string operations transform without allocating" {
    var buffer: [32]u8 = undefined;
    try std.testing.expectEqualStrings("ADA", try apply(.uppercase, "Ada", &buffer));
    try std.testing.expectEqualStrings("Ada", try apply(.trim, "  Ada ", &buffer));
    try std.testing.expectEqualStrings(
        "a--b--",
        try apply(.{ .replace = .{ .needle = "_", .replacement = "--" } }, "a_b_", &buffer),
    );
}

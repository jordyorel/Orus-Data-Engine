const std = @import("std");

pub const version: u32 = 1;

pub const Options = struct {
    trim: bool = true,
    lowercase_ascii: bool = true,
    remove_ascii_punctuation: bool = false,
    collapse_whitespace: bool = true,
};

/// Normalizes into caller-owned storage and returns the initialized prefix.
/// The output never exceeds `input.len` bytes.
pub fn apply(input: []const u8, output: []u8, options: Options) ![]const u8 {
    if (output.len < input.len) return error.OutputTooSmall;
    const source = if (options.trim) std.mem.trim(u8, input, &std.ascii.whitespace) else input;
    var written: usize = 0;
    var pending_space = false;
    for (source) |raw| {
        if (options.collapse_whitespace and std.ascii.isWhitespace(raw)) {
            pending_space = written != 0;
            continue;
        }
        if (options.remove_ascii_punctuation and std.ascii.isPunctuation(raw)) continue;
        if (pending_space) {
            output[written] = ' ';
            written += 1;
            pending_space = false;
        }
        output[written] = if (options.lowercase_ascii) std.ascii.toLower(raw) else raw;
        written += 1;
    }
    return output[0..written];
}

test "normalization is deterministic and bounded" {
    var output: [64]u8 = undefined;
    try std.testing.expectEqualStrings(
        "mtn congo",
        try apply("  MTN   Congo  ", &output, .{}),
    );
    try std.testing.expectEqualStrings(
        "inv2026001",
        try apply("INV-2026-001", &output, .{ .remove_ascii_punctuation = true }),
    );
}

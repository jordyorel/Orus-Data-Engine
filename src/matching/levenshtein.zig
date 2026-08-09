const std = @import("std");

/// Returns null when the distance exceeds `max_distance`. `scratch` must hold
/// at least `min(a.len, b.len) + 1` entries and is reused for every comparison.
pub fn boundedLevenshtein(
    a: []const u8,
    b: []const u8,
    max_distance: usize,
    scratch: []usize,
) !?usize {
    if (a.len > b.len) return boundedLevenshtein(b, a, max_distance, scratch);
    if (b.len - a.len > max_distance) return null;
    if (scratch.len < a.len + 1) return error.InsufficientLevenshteinScratch;
    if (a.len == 0) return if (b.len <= max_distance) b.len else null;

    for (scratch[0 .. a.len + 1], 0..) |*cell, index| cell.* = index;
    for (b, 1..) |right, row| {
        var diagonal = scratch[0];
        scratch[0] = row;
        var row_min = scratch[0];
        for (a, 1..) |left, column| {
            const above = scratch[column];
            const substitution = diagonal + @intFromBool(left != right);
            const deletion = above + 1;
            const insertion = scratch[column - 1] + 1;
            scratch[column] = @min(substitution, @min(deletion, insertion));
            row_min = @min(row_min, scratch[column]);
            diagonal = above;
        }
        if (row_min > max_distance) return null;
    }
    const distance = scratch[a.len];
    return if (distance <= max_distance) distance else null;
}

test "bounded Levenshtein rejects by length and stops above threshold" {
    var scratch: [16]usize = undefined;
    try std.testing.expectEqual(@as(?usize, 3), try boundedLevenshtein("kitten", "sitting", 3, &scratch));
    try std.testing.expectEqual(@as(?usize, null), try boundedLevenshtein("kitten", "sitting", 2, &scratch));
    try std.testing.expectEqual(@as(?usize, null), try boundedLevenshtein("a", "abcdef", 2, &scratch));
    try std.testing.expectError(
        error.InsufficientLevenshteinScratch,
        boundedLevenshtein("abc", "abd", 1, scratch[0..2]),
    );
}

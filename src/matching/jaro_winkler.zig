const std = @import("std");

pub const max_input_bytes = 1024;

/// Returns zero for inputs above the documented bound.
pub fn similarity(a: []const u8, b: []const u8) f32 {
    if (a.len > max_input_bytes or b.len > max_input_bytes) return 0;
    if (std.mem.eql(u8, a, b)) return 1;
    if (a.len == 0 or b.len == 0) return 0;

    var a_matched: [max_input_bytes]bool = @splat(false);
    var b_matched: [max_input_bytes]bool = @splat(false);
    const radius = @max(a.len, b.len) / 2 -| 1;
    var matches: usize = 0;
    for (a, 0..) |byte, i| {
        const start = i -| radius;
        const end = @min(i + radius + 1, b.len);
        for (start..end) |j| {
            if (b_matched[j] or byte != b[j]) continue;
            a_matched[i] = true;
            b_matched[j] = true;
            matches += 1;
            break;
        }
    }
    if (matches == 0) return 0;

    var transpositions: usize = 0;
    var j: usize = 0;
    for (a, 0..) |byte, i| {
        if (!a_matched[i]) continue;
        while (!b_matched[j]) j += 1;
        transpositions += @intFromBool(byte != b[j]);
        j += 1;
    }
    const match_count: f32 = @floatFromInt(matches);
    const jaro = (match_count / @as(f32, @floatFromInt(a.len)) +
        match_count / @as(f32, @floatFromInt(b.len)) +
        (match_count - @as(f32, @floatFromInt(transpositions)) / 2) / match_count) / 3;
    var prefix: usize = 0;
    while (prefix < @min(4, @min(a.len, b.len)) and a[prefix] == b[prefix]) prefix += 1;
    return jaro + @as(f32, @floatFromInt(prefix)) * 0.1 * (1 - jaro);
}

test "Jaro-Winkler matches canonical examples" {
    try std.testing.expectApproxEqAbs(@as(f32, 0.961), similarity("martha", "marhta"), 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.84), similarity("dixon", "dicksonx"), 0.01);
    try std.testing.expectEqual(@as(f32, 1), similarity("orus", "orus"));
    try std.testing.expectEqual(@as(f32, 0), similarity("", "orus"));
}

const std = @import("std");
const jaro_winkler = @import("jaro_winkler.zig");
const levenshtein = @import("levenshtein.zig");

pub const exact_score: f32 = 1.0;
pub const exact_version: u32 = 1;
pub const fuzzy_version: u32 = 1;

pub const FuzzyConfig = struct {
    levenshtein_weight: f32 = 0.4,
    jaro_winkler_weight: f32 = 0.6,
    max_distance: usize = 3,
    threshold: f32 = 0.85,

    pub fn validate(self: FuzzyConfig) !void {
        if (!std.math.isFinite(self.levenshtein_weight) or
            !std.math.isFinite(self.jaro_winkler_weight) or
            self.levenshtein_weight < 0 or self.jaro_winkler_weight < 0 or
            self.levenshtein_weight + self.jaro_winkler_weight <= 0)
        {
            return error.InvalidFuzzyWeights;
        }
        if (!std.math.isFinite(self.threshold) or self.threshold < 0 or self.threshold > 1) {
            return error.InvalidFuzzyThreshold;
        }
    }
};

pub const FuzzyScore = struct {
    score: f32,
    levenshtein_distance: ?usize,
    jaro_winkler_score: f32,
};

pub fn fuzzy(
    left: []const u8,
    right: []const u8,
    config: FuzzyConfig,
    scratch: []usize,
) !?FuzzyScore {
    try config.validate();
    const distance = try levenshtein.boundedLevenshtein(left, right, config.max_distance, scratch);
    const maximum_len = @max(left.len, right.len);
    const levenshtein_score: f32 = if (distance) |value|
        if (maximum_len == 0) 1 else 1 - @as(f32, @floatFromInt(value)) /
            @as(f32, @floatFromInt(maximum_len))
    else
        0;
    const jaro_score = jaro_winkler.similarity(left, right);
    const weight_sum = config.levenshtein_weight + config.jaro_winkler_weight;
    const score = (levenshtein_score * config.levenshtein_weight +
        jaro_score * config.jaro_winkler_weight) / weight_sum;
    if (score < config.threshold) return null;
    return .{
        .score = score,
        .levenshtein_distance = distance,
        .jaro_winkler_score = jaro_score,
    };
}

test "composite fuzzy score applies threshold and weights" {
    var scratch: [32]usize = undefined;
    const accepted = (try fuzzy("martha", "marhta", .{ .threshold = 0.8 }, &scratch)).?;
    try std.testing.expect(accepted.score >= 0.8);
    try std.testing.expect((try fuzzy("martha", "zulu", .{ .threshold = 0.8 }, &scratch)) == null);
    try std.testing.expectError(
        error.InvalidFuzzyThreshold,
        fuzzy("a", "a", .{ .threshold = 2 }, &scratch),
    );
}

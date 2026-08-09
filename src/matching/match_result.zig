const RowId = @import("../validation/violation.zig").RowId;

pub const Method = enum { exact, levenshtein, jaro_winkler, composite };

pub const MatchResult = struct {
    left: RowId,
    right: RowId,
    score: f32,
    method: Method,
    scorer_version: u32,
};

pub const MatchSummary = struct {
    reference_rows: u64 = 0,
    candidate_rows: u64 = 0,
    reference_batches: u64 = 0,
    candidate_batches: u64 = 0,
    matches: u64 = 0,
    partitions_processed: u32 = 0,
    spill_bytes: u64 = 0,
    peak_index_bytes: usize = 0,
};

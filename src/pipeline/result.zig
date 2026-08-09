const profile_report = @import("../profiling/profile_report.zig");
const validation_summary = @import("../validation/validation_summary.zig");

pub const PipelineResult = struct {
    profile: ?profile_report.ProfileReport = null,
    validation: ?validation_summary.ValidationSummary = null,
    rows_read: u64,
    rows_written: u64,
    batches_processed: u64,
    invalid_values: u64,
    bytes_read: u64,
    started_at_ms: i64,
    completed_at_ms: i64,
};

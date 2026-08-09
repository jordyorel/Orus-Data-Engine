const batch = @import("../core/batch.zig");

pub const Metrics = struct {
    batches_read: u64 = 0,
    rows_read: u64 = 0,
    rows_written: u64 = 0,
    batches_processed: u64 = 0,
    bytes_read: u64 = 0,
    largest_batch_rows: usize = 0,

    pub fn observeBatch(self: *Metrics, input: *const batch.Batch) void {
        self.batches_read += 1;
        self.rows_read += input.row_count;
        self.largest_batch_rows = @max(self.largest_batch_rows, input.row_count);
    }

    pub fn observeWrite(self: *Metrics, input: *const batch.Batch) void {
        self.rows_written += input.row_count;
        self.batches_processed += 1;
    }
};

pub const BenchmarkResult = struct {
    rows: u64,
    batches: u64,
    bytes: u64,
    invalid_values: u64,
    largest_batch_rows: usize,
    elapsed_seconds: f64,
    cpu_seconds: f64,
    rows_per_second: f64,
    mib_per_second: f64,
    peak_rss_bytes: ?u64,

    pub fn init(
        measured: Metrics,
        bytes: u64,
        invalid_values: u64,
        elapsed_nanoseconds: i96,
        cpu_nanoseconds: i96,
        peak_rss_bytes: ?u64,
    ) BenchmarkResult {
        const elapsed_seconds = seconds(elapsed_nanoseconds);
        return .{
            .rows = measured.rows_read,
            .batches = measured.batches_read,
            .bytes = bytes,
            .invalid_values = invalid_values,
            .largest_batch_rows = measured.largest_batch_rows,
            .elapsed_seconds = elapsed_seconds,
            .cpu_seconds = seconds(cpu_nanoseconds),
            .rows_per_second = rate(@floatFromInt(measured.rows_read), elapsed_seconds),
            .mib_per_second = rate(@as(f64, @floatFromInt(bytes)) / (1024 * 1024), elapsed_seconds),
            .peak_rss_bytes = peak_rss_bytes,
        };
    }
};

fn seconds(nanoseconds: i96) f64 {
    return @as(f64, @floatFromInt(@max(nanoseconds, 0))) / 1_000_000_000;
}

fn rate(amount: f64, elapsed_seconds: f64) f64 {
    return if (elapsed_seconds == 0) 0 else amount / elapsed_seconds;
}

test "benchmark result calculates stable rates" {
    const result = BenchmarkResult.init(
        .{ .rows_read = 2_000_000, .batches_read = 245, .largest_batch_rows = 8192 },
        200 * 1024 * 1024,
        3,
        2_000_000_000,
        1_500_000_000,
        64 * 1024 * 1024,
    );
    try @import("std").testing.expectEqual(@as(f64, 1_000_000), result.rows_per_second);
    try @import("std").testing.expectEqual(@as(f64, 100), result.mib_per_second);
    try @import("std").testing.expectEqual(@as(f64, 1.5), result.cpu_seconds);
}

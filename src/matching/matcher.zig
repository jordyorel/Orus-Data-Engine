const std = @import("std");
const arena_pool = @import("../core/arena_pool.zig");
const reader_mod = @import("../core/reader.zig");
const execution_allocators = @import("../execution/allocators.zig");
const blocking = @import("blocking.zig");
const exact_match = @import("exact_match.zig");
const index_mod = @import("index.zig");
const match_result = @import("match_result.zig");
const match_sink = @import("match_sink.zig");
const normalization = @import("normalization.zig");
const scorer = @import("scorer.zig");

pub const Scoring = union(enum) {
    exact,
    fuzzy: scorer.FuzzyConfig,
};

pub const Options = struct {
    reference_column: u32,
    candidate_column: u32,
    normalization: normalization.Options = .{},
    blocking: blocking.Strategy = .exact_normalized,
    index_memory_limit: usize = index_mod.default_memory_limit,
    match_empty: bool = false,
    scoring: Scoring = .exact,
    max_candidates_per_row: usize = 10_000,
    max_matches_per_row: usize = 1_000,
};

pub const Matcher = struct {
    index: index_mod.MatchIndex,
    options: Options,
    sink: match_sink.MatchSink,
    summary: match_result.MatchSummary = .{},
    has_run: bool = false,

    pub fn init(
        allocator: std.mem.Allocator,
        options: Options,
        sink: match_sink.MatchSink,
    ) !Matcher {
        try validateOptions(options);
        return .{
            .index = try index_mod.MatchIndex.init(
                allocator,
                options.index_memory_limit,
                options.blocking,
            ),
            .options = options,
            .sink = sink,
        };
    }

    pub fn deinit(self: *Matcher) void {
        self.index.deinit();
    }

    pub fn run(
        self: *Matcher,
        reference: reader_mod.Reader,
        candidates: reader_mod.Reader,
        arena: *arena_pool.BatchArena,
        scratch: *execution_allocators.ScratchArena,
    ) !match_result.MatchSummary {
        if (self.has_run) return error.MatcherAlreadyRun;
        self.has_run = true;
        var sink_finished = false;
        errdefer if (!sink_finished) self.sink.abort();
        try self.buildReference(reference, arena, scratch);
        self.index.finalize();
        try self.matchCandidates(candidates, arena, scratch);
        try self.sink.finish();
        sink_finished = true;
        return self.summary;
    }

    fn buildReference(
        self: *Matcher,
        source: reader_mod.Reader,
        arena: *arena_pool.BatchArena,
        scratch: *execution_allocators.ScratchArena,
    ) !void {
        while (try source.next(arena)) |input| {
            const column = try stringColumn(&input, self.options.reference_column);
            const temporary = try scratch.allocator().alloc(u8, maxStringLength(column));
            for (0..input.row_count) |row| {
                if (column.isNull(row)) continue;
                const normalized = try normalization.apply(
                    column.data.string.get(row),
                    temporary,
                    self.options.normalization,
                );
                if (normalized.len == 0 and !self.options.match_empty) continue;
                try self.index.insert(normalized, rowId(&input, row));
            }
            self.summary.reference_rows += input.row_count;
            self.summary.reference_batches += 1;
            arena.reset();
            scratch.reset();
        }
    }

    fn matchCandidates(
        self: *Matcher,
        source: reader_mod.Reader,
        arena: *arena_pool.BatchArena,
        scratch: *execution_allocators.ScratchArena,
    ) !void {
        var output: [256]match_result.MatchResult = undefined;
        var output_len: usize = 0;
        while (try source.next(arena)) |input| {
            const column = try stringColumn(&input, self.options.candidate_column);
            const temporary = try scratch.allocator().alloc(u8, maxStringLength(column));
            const distance_scratch = try scratch.allocator().alloc(usize, maxStringLength(column) + 1);
            for (0..input.row_count) |row| {
                if (column.isNull(row)) continue;
                const normalized = try normalization.apply(
                    column.data.string.get(row),
                    temporary,
                    self.options.normalization,
                );
                if (normalized.len == 0 and !self.options.match_empty) continue;
                const candidate_key = exact_match.ExactMatchKey.init(normalized);
                var candidates = try self.index.candidates(normalized);
                var candidates_seen: usize = 0;
                var matches_emitted: usize = 0;
                while (candidates.next()) |entry| {
                    candidates_seen += 1;
                    if (candidates_seen > self.options.max_candidates_per_row) {
                        return error.MatchCandidateLimitExceeded;
                    }
                    const score: f32 = switch (self.options.scoring) {
                        .exact => blk: {
                            if (!exact_match.matches(entry.key, candidate_key)) continue;
                            break :blk scorer.exact_score;
                        },
                        .fuzzy => |config| (try scorer.fuzzy(
                            entry.key.normalized_value,
                            normalized,
                            config,
                            distance_scratch,
                        ) orelse continue).score,
                    };
                    matches_emitted += 1;
                    if (matches_emitted > self.options.max_matches_per_row) {
                        return error.MatchResultLimitExceeded;
                    }
                    output[output_len] = .{
                        .left = entry.row_id,
                        .right = rowId(&input, row),
                        .score = score,
                        .method = switch (self.options.scoring) {
                            .exact => .exact,
                            .fuzzy => .composite,
                        },
                        .scorer_version = switch (self.options.scoring) {
                            .exact => scorer.exact_version,
                            .fuzzy => scorer.fuzzy_version,
                        },
                    };
                    output_len += 1;
                    self.summary.matches += 1;
                    if (output_len == output.len) {
                        try self.sink.write(&output);
                        output_len = 0;
                    }
                }
            }
            self.summary.candidate_rows += input.row_count;
            self.summary.candidate_batches += 1;
            arena.reset();
            scratch.reset();
        }
        if (output_len != 0) try self.sink.write(output[0..output_len]);
    }
};

pub const PartitionedOptions = struct {
    matching: Options,
    partition_count: u16 = 64,
    max_value_bytes: usize = 1024 * 1024,
    temp_prefix: []const u8 = ".orus-match-spill",
};

pub const PartitionedMatcher = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    options: PartitionedOptions,
    sink: match_sink.MatchSink,
    has_run: bool = false,

    pub fn init(
        io: std.Io,
        allocator: std.mem.Allocator,
        options: PartitionedOptions,
        sink: match_sink.MatchSink,
    ) !PartitionedMatcher {
        if (options.partition_count == 0) return error.InvalidPartitionCount;
        if (options.max_value_bytes == 0) return error.InvalidMatchValueLimit;
        try validateOptions(options.matching);
        return .{ .allocator = allocator, .io = io, .options = options, .sink = sink };
    }

    pub fn run(
        self: *PartitionedMatcher,
        reference: reader_mod.Reader,
        candidates: reader_mod.Reader,
        arena: *arena_pool.BatchArena,
        scratch: *execution_allocators.ScratchArena,
    ) !match_result.MatchSummary {
        if (self.has_run) return error.MatcherAlreadyRun;
        self.has_run = true;
        var sink_finished = false;
        errdefer if (!sink_finished) self.sink.abort();

        const reference_prefix = try std.fmt.allocPrint(self.allocator, "{s}-reference", .{self.options.temp_prefix});
        defer self.allocator.free(reference_prefix);
        const candidate_prefix = try std.fmt.allocPrint(self.allocator, "{s}-candidate", .{self.options.temp_prefix});
        defer self.allocator.free(candidate_prefix);
        var reference_store = try index_mod.PartitionStore.init(
            self.io,
            self.allocator,
            reference_prefix,
            self.options.partition_count,
        );
        defer reference_store.deinit();
        var candidate_store = try index_mod.PartitionStore.init(
            self.io,
            self.allocator,
            candidate_prefix,
            self.options.partition_count,
        );
        defer candidate_store.deinit();

        var summary: match_result.MatchSummary = .{};
        try self.spool(reference, self.options.matching.reference_column, &reference_store, arena, scratch, true, &summary);
        try reference_store.finish();
        try self.spool(candidates, self.options.matching.candidate_column, &candidate_store, arena, scratch, false, &summary);
        try candidate_store.finish();
        summary.spill_bytes = reference_store.bytes_written + candidate_store.bytes_written;
        try self.processPartitions(&reference_store, &candidate_store, &summary);
        try self.sink.finish();
        sink_finished = true;
        return summary;
    }

    fn spool(
        self: *PartitionedMatcher,
        source: reader_mod.Reader,
        column_index: u32,
        store: *index_mod.PartitionStore,
        arena: *arena_pool.BatchArena,
        scratch: *execution_allocators.ScratchArena,
        is_reference: bool,
        summary: *match_result.MatchSummary,
    ) !void {
        while (try source.next(arena)) |input| {
            const column = try stringColumn(&input, column_index);
            const temporary = try scratch.allocator().alloc(u8, maxStringLength(column));
            for (0..input.row_count) |row| {
                if (column.isNull(row)) continue;
                const normalized = try normalization.apply(column.data.string.get(row), temporary, self.options.matching.normalization);
                if (normalized.len > self.options.max_value_bytes) return error.MatchValueExceedsLimit;
                if (normalized.len == 0 and !self.options.matching.match_empty) continue;
                try store.write(normalized, rowId(&input, row), self.options.matching.blocking);
            }
            if (is_reference) {
                summary.reference_rows += input.row_count;
                summary.reference_batches += 1;
            } else {
                summary.candidate_rows += input.row_count;
                summary.candidate_batches += 1;
            }
            arena.reset();
            scratch.reset();
        }
    }

    fn processPartitions(
        self: *PartitionedMatcher,
        reference_store: *const index_mod.PartitionStore,
        candidate_store: *const index_mod.PartitionStore,
        summary: *match_result.MatchSummary,
    ) !void {
        const read_buffer = try self.allocator.alloc(u8, 64 * 1024);
        defer self.allocator.free(read_buffer);
        const value_buffer = try self.allocator.alloc(u8, self.options.max_value_bytes);
        defer self.allocator.free(value_buffer);
        const distance_scratch = try self.allocator.alloc(usize, switch (self.options.matching.scoring) {
            .exact => 0,
            .fuzzy => self.options.max_value_bytes + 1,
        });
        defer self.allocator.free(distance_scratch);
        var output: [256]match_result.MatchResult = undefined;
        var output_len: usize = 0;

        for (0..self.options.partition_count) |partition| {
            var index = try index_mod.MatchIndex.init(
                self.allocator,
                self.options.matching.index_memory_limit,
                self.options.matching.blocking,
            );
            defer index.deinit();
            var reference_reader = try reference_store.openReader(partition, read_buffer);
            defer reference_reader.file.close(self.io);
            while (try index_mod.PartitionStore.readRecord(&reference_reader.interface, value_buffer)) |record| {
                try index.insert(record.normalized, record.row_id);
            }
            index.finalize();
            summary.peak_index_bytes = @max(summary.peak_index_bytes, index.peakMemoryUsed());

            var candidate_reader = try candidate_store.openReader(partition, read_buffer);
            defer candidate_reader.file.close(self.io);
            while (try index_mod.PartitionStore.readRecord(&candidate_reader.interface, value_buffer)) |record| {
                const candidate_key = exact_match.ExactMatchKey.init(record.normalized);
                var blocked = try index.candidates(record.normalized);
                var candidates_seen: usize = 0;
                var matches_emitted: usize = 0;
                while (blocked.next()) |entry| {
                    candidates_seen += 1;
                    if (candidates_seen > self.options.matching.max_candidates_per_row) return error.MatchCandidateLimitExceeded;
                    const score: f32 = switch (self.options.matching.scoring) {
                        .exact => blk: {
                            if (!exact_match.matches(entry.key, candidate_key)) continue;
                            break :blk scorer.exact_score;
                        },
                        .fuzzy => |config| (try scorer.fuzzy(
                            entry.key.normalized_value,
                            record.normalized,
                            config,
                            distance_scratch,
                        ) orelse continue).score,
                    };
                    matches_emitted += 1;
                    if (matches_emitted > self.options.matching.max_matches_per_row) return error.MatchResultLimitExceeded;
                    output[output_len] = .{
                        .left = entry.row_id,
                        .right = record.row_id,
                        .score = score,
                        .method = switch (self.options.matching.scoring) {
                            .exact => .exact,
                            .fuzzy => .composite,
                        },
                        .scorer_version = switch (self.options.matching.scoring) {
                            .exact => scorer.exact_version,
                            .fuzzy => scorer.fuzzy_version,
                        },
                    };
                    output_len += 1;
                    summary.matches += 1;
                    if (output_len == output.len) {
                        try self.sink.write(&output);
                        output_len = 0;
                    }
                }
            }
            summary.partitions_processed += 1;
        }
        if (output_len != 0) try self.sink.write(output[0..output_len]);
    }
};

fn validateOptions(options: Options) !void {
    if (options.max_candidates_per_row == 0) return error.InvalidCandidateLimit;
    if (options.max_matches_per_row == 0) return error.InvalidMatchLimit;
    switch (options.scoring) {
        .exact => {},
        .fuzzy => |config| {
            try config.validate();
            switch (options.blocking) {
                .exact_normalized => return error.FuzzyRequiresBlocking,
                else => {},
            }
        },
    }
}

fn stringColumn(input: *const @import("../core/batch.zig").Batch, index: u32) !*const @import("../core/column.zig").Column {
    if (index >= input.columns.len) return error.MatchColumnOutOfBounds;
    const column = input.column(index);
    if (column.tag != .string) return error.MatchRequiresStringColumn;
    return column;
}

fn maxStringLength(column: *const @import("../core/column.zig").Column) usize {
    var maximum: usize = 0;
    for (0..column.len) |row| if (!column.isNull(row)) {
        maximum = @max(maximum, column.data.string.get(row).len);
    };
    return maximum;
}

fn rowId(input: *const @import("../core/batch.zig").Batch, row: usize) @import("../validation/violation.zig").RowId {
    return .{
        .source_id = input.metadata.source_id,
        .batch_id = input.metadata.batch_id,
        .row_in_batch = @intCast(row),
        .global_offset = input.metadata.global_row_offset + row,
    };
}

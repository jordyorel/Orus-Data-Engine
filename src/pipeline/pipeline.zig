const std = @import("std");
const context_mod = @import("../execution/context.zig");
const plan_mod = @import("../execution/plan.zig");
const ingest_reader = @import("../ingestion/ingest_reader.zig");
const profile_reader = @import("../profiling/profile_reader.zig");
const rule_engine = @import("../validation/rule_engine.zig");
const rule_mod = @import("../validation/rule.zig");
const violation_sink_mod = @import("../validation/violation_sink.zig");
const validation_summary = @import("../validation/validation_summary.zig");
const executor = @import("executor.zig");
const result_mod = @import("result.zig");

pub const ValidationConfig = struct {
    rules: []const rule_mod.Rule,
    sink: violation_sink_mod.ViolationSink,
};

pub const Pipeline = struct {
    allocator: std.mem.Allocator,
    plan: plan_mod.ExecutionPlan,
    ingest: *ingest_reader.IngestReader,
    profiler: ?*profile_reader.ProfileReader,
    validator: ?*rule_engine.RuleEngine,
    final_reader: @import("../core/reader.zig").Reader,
    has_run: bool = false,

    pub fn init(
        allocator: std.mem.Allocator,
        plan: plan_mod.ExecutionPlan,
        validation: ?ValidationConfig,
    ) !Pipeline {
        const ingest = try allocator.create(ingest_reader.IngestReader);
        ingest.* = ingest_reader.IngestReader.init(allocator, plan.source, .{});
        var final_reader = ingest.asReader();
        var profiler: ?*profile_reader.ProfileReader = null;
        if (plan.profiling_enabled) {
            profiler = try allocator.create(profile_reader.ProfileReader);
            profiler.?.* = profile_reader.ProfileReader.init(allocator, final_reader);
            final_reader = profiler.?.asReader();
        }
        var validator: ?*rule_engine.RuleEngine = null;
        if (validation) |config| {
            validator = try allocator.create(rule_engine.RuleEngine);
            validator.?.* = rule_engine.RuleEngine.init(
                allocator,
                final_reader,
                config.rules,
                config.sink,
                .{},
            );
            final_reader = validator.?.asReader();
        }
        return .{
            .allocator = allocator,
            .plan = plan,
            .ingest = ingest,
            .profiler = profiler,
            .validator = validator,
            .final_reader = final_reader,
        };
    }

    pub fn deinit(self: *Pipeline) void {
        if (self.validator) |validator| validator.deinit();
        if (self.profiler) |profiler| profiler.deinit();
        self.ingest.deinit();
    }

    /// Returned report slices live until the execution context is deinitialized.
    pub fn run(
        self: *Pipeline,
        context: *context_mod.ExecutionContext,
        io: std.Io,
    ) !result_mod.PipelineResult {
        if (self.has_run) return error.PipelineAlreadyRun;
        self.has_run = true;
        const started = std.Io.Timestamp.now(io, .real).toMilliseconds();
        try executor.execute(self.final_reader, self.plan.transforms, self.plan.sink, context);
        context.metrics.bytes_read = self.plan.source.bytesRead();
        if (self.ingest.inferredSchema()) |schema| {
            self.plan.source_schema_hash = schema.hash;
            self.plan.output_schema_hash = schema.hash;
        }

        var profile = if (self.profiler) |profiler|
            try profiler.finalize(context.allocators.run())
        else
            null;
        errdefer if (profile) |*report| report.deinit(context.allocators.run());
        const validation = if (self.validator) |validator|
            try cloneValidation(context.allocators.run(), try validator.finalize())
        else
            null;
        const completed = std.Io.Timestamp.now(io, .real).toMilliseconds();
        return .{
            .profile = profile,
            .validation = validation,
            .rows_read = context.metrics.rows_read,
            .rows_written = context.metrics.rows_written,
            .batches_processed = context.metrics.batches_processed,
            .invalid_values = self.ingest.invalid_values,
            .bytes_read = context.metrics.bytes_read,
            .started_at_ms = started,
            .completed_at_ms = completed,
        };
    }
};

fn cloneValidation(
    allocator: std.mem.Allocator,
    source: *const validation_summary.ValidationSummary,
) !validation_summary.ValidationSummary {
    var result = source.*;
    result.violations_by_rule = try allocator.dupe(validation_summary.RuleCount, source.violations_by_rule);
    result.violations_by_column = try allocator.dupe(
        validation_summary.ColumnCount,
        source.violations_by_column,
    );
    result.samples = try allocator.dupe(@import("../validation/violation.zig").Violation, source.samples);
    return result;
}

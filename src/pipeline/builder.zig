const std = @import("std");
const context_mod = @import("../execution/context.zig");
const plan_mod = @import("../execution/plan.zig");
const source_mod = @import("../connectors/source.zig");
const sink_mod = @import("../core/sink.zig");
const transform_mod = @import("../cleaning/transform.zig");
const rule_mod = @import("../validation/rule.zig");
const violation_sink_mod = @import("../validation/violation_sink.zig");
const unique = @import("../validation/unique.zig");
const pipeline_mod = @import("pipeline.zig");

const ValidationConfig = struct {
    rules: []const rule_mod.Rule,
    sink: violation_sink_mod.ViolationSink,
};

pub const PipelineBuilder = struct {
    allocator: std.mem.Allocator,
    source: source_mod.Source,
    profiling_enabled: bool = false,
    validation: ?ValidationConfig = null,
    transforms: std.ArrayList(transform_mod.Transform) = .empty,
    sink: ?sink_mod.Sink = null,

    pub fn init(allocator: std.mem.Allocator, source: source_mod.Source) PipelineBuilder {
        return .{ .allocator = allocator, .source = source };
    }

    pub fn deinit(self: *PipelineBuilder) void {
        self.transforms.deinit(self.allocator);
    }

    pub fn withProfiling(self: *PipelineBuilder) *PipelineBuilder {
        self.profiling_enabled = true;
        return self;
    }

    /// `rules` and the concrete violation sink must remain valid until build.
    pub fn withValidation(
        self: *PipelineBuilder,
        rules: []const rule_mod.Rule,
        sink: violation_sink_mod.ViolationSink,
    ) *PipelineBuilder {
        self.validation = .{ .rules = rules, .sink = sink };
        return self;
    }

    /// The concrete transform state must remain valid through pipeline run.
    pub fn withTransform(self: *PipelineBuilder, operation: transform_mod.Transform) !*PipelineBuilder {
        for (self.transforms.items) |existing| {
            if (existing.id == operation.id) return error.DuplicateTransformId;
        }
        try self.transforms.append(self.allocator, operation);
        return self;
    }

    pub fn withSink(self: *PipelineBuilder, sink: sink_mod.Sink) *PipelineBuilder {
        self.sink = sink;
        return self;
    }

    pub fn build(
        self: *const PipelineBuilder,
        context: *context_mod.ExecutionContext,
    ) !pipeline_mod.Pipeline {
        const output = self.sink orelse return error.MissingSink;
        const allocator = context.allocators.run();
        const transforms = try allocator.dupe(transform_mod.Transform, self.transforms.items);
        const validation = if (self.validation) |config| pipeline_mod.ValidationConfig{
            .rules = try cloneRules(allocator, config.rules),
            .sink = config.sink,
        } else null;
        var unique_rule_count: usize = 0;
        if (validation) |config| for (config.rules) |definition| {
            unique_rule_count += @intFromBool(definition.tag == .unique);
        };
        const estimated_memory = std.math.mul(usize, unique_rule_count, unique.default_memory_limit) catch
            return error.EstimatedMemoryOverflow;
        const stage_count = @as(usize, 1) +
            @as(usize, @intFromBool(self.profiling_enabled)) +
            @as(usize, @intFromBool(validation != null));
        const reader_stages = try allocator.alloc(plan_mod.ReaderStage, stage_count);
        var stage_index: usize = 0;
        reader_stages[stage_index] = .ingestion;
        stage_index += 1;
        if (self.profiling_enabled) {
            reader_stages[stage_index] = .profiling;
            stage_index += 1;
        }
        if (validation != null) reader_stages[stage_index] = .validation;
        return pipeline_mod.Pipeline.init(
            allocator,
            .{
                .source = self.source,
                .reader_stages = reader_stages,
                .transforms = transforms,
                .sink = output,
                .profiling_enabled = self.profiling_enabled,
                .validation_enabled = validation != null,
                .estimated_memory = estimated_memory,
                .requires_spill = unique_rule_count != 0,
            },
            validation,
        );
    }
};

fn cloneRules(allocator: std.mem.Allocator, rules: []const rule_mod.Rule) ![]rule_mod.Rule {
    const cloned = try allocator.alloc(rule_mod.Rule, rules.len);
    for (rules, 0..) |definition, index| {
        cloned[index] = definition;
        cloned[index].column = try allocator.dupe(u8, definition.column);
        if (definition.min) |value| cloned[index].min = try allocator.dupe(u8, value);
        if (definition.max) |value| cloned[index].max = try allocator.dupe(u8, value);
        if (definition.regex) |value| cloned[index].regex = try allocator.dupe(u8, value);
        if (definition.values) |values| {
            const copied_values = try allocator.alloc([]const u8, values.len);
            for (values, 0..) |value, value_index| {
                copied_values[value_index] = try allocator.dupe(u8, value);
            }
            cloned[index].values = copied_values;
        }
    }
    return cloned;
}

const source_mod = @import("../connectors/source.zig");
const sink_mod = @import("../core/sink.zig");
const transform_mod = @import("../cleaning/transform.zig");

pub const ReaderStage = enum { ingestion, profiling, validation };

pub const ExecutionPlan = struct {
    source: source_mod.Source,
    reader_stages: []const ReaderStage,
    transforms: []const transform_mod.Transform,
    sink: sink_mod.Sink,
    profiling_enabled: bool,
    validation_enabled: bool,
    estimated_memory: usize,
    requires_spill: bool,
    source_schema_hash: ?u64 = null,
    output_schema_hash: ?u64 = null,
};

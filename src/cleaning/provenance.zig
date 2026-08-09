const batch = @import("../core/batch.zig");
const registry = @import("transform_registry.zig");

pub const Entry = struct {
    format_version: u32 = registry.current_format_version,
    pipeline_run_id: u128,
    source_id: u128,
    source_version: u64,
    batch_id: u64,
    global_row_range: [2]u64,
    transforms: []const registry.TransformSpec,
    params_hash: u64,
    input_schema_hash: u64,
    output_schema_hash: u64,
    timestamp_ms: i64,
};

pub fn create(
    run_id: u128,
    specs: []const registry.TransformSpec,
    input: *const batch.Batch,
    output: *const batch.Batch,
    timestamp_ms: i64,
) Entry {
    return .{
        .pipeline_run_id = run_id,
        .source_id = input.metadata.source_id,
        .source_version = input.metadata.source_version,
        .batch_id = input.metadata.batch_id,
        .global_row_range = .{
            input.metadata.global_row_offset,
            input.metadata.global_row_offset + input.row_count,
        },
        .transforms = specs,
        .params_hash = registry.paramsHash(specs),
        .input_schema_hash = input.schema.hash,
        .output_schema_hash = output.schema.hash,
        .timestamp_ms = timestamp_ms,
    };
}

pub const core = struct {
    pub const value = @import("core/value.zig");
    pub const decimal = @import("core/decimal.zig");
    pub const bitmap = @import("core/bitmap.zig");
    pub const string_column = @import("core/string_column.zig");
    pub const column = @import("core/column.zig");
    pub const schema = @import("core/schema.zig");
    pub const batch = @import("core/batch.zig");
    pub const batch_metadata = @import("core/batch_metadata.zig");
    pub const source_identity = @import("core/source_identity.zig");
    pub const arena_pool = @import("core/arena_pool.zig");
    pub const reader = @import("core/reader.zig");
    pub const sink = @import("core/sink.zig");
};
pub const connectors = struct {
    pub const source = @import("connectors/source.zig");
    pub const csv_source = @import("connectors/csv_source.zig");
    pub const jsonl_source = @import("connectors/jsonl_source.zig");
    pub const postgres_source = @import("connectors/postgres_source.zig");
};
pub const execution = struct {
    pub const allocators = @import("execution/allocators.zig");
    pub const context = @import("execution/context.zig");
    pub const error_context = @import("execution/error_context.zig");
    pub const metrics = @import("execution/metrics.zig");
    pub const plan = @import("execution/plan.zig");
};
pub const cleaning = struct {
    pub const string_ops = @import("cleaning/string_ops.zig");
    pub const transform = @import("cleaning/transform.zig");
    pub const transform_registry = @import("cleaning/transform_registry.zig");
    pub const normalize_date = @import("cleaning/normalize_date.zig");
    pub const normalize_currency = @import("cleaning/normalize_currency.zig");
    pub const provenance = @import("cleaning/provenance.zig");
    pub const audit_log = @import("cleaning/audit_log.zig");
    pub const replay = @import("cleaning/replay.zig");
};
pub const sinks = struct {
    pub const csv_sink = @import("sinks/csv_sink.zig");
    pub const jsonl_sink = @import("sinks/jsonl_sink.zig");
    pub const memory_sink = @import("sinks/memory_sink.zig");
    pub const null_sink = @import("sinks/null_sink.zig");
};
pub const pipeline = struct {
    pub const builder = @import("pipeline/builder.zig");
    pub const pipeline = @import("pipeline/pipeline.zig");
    pub const executor = @import("pipeline/executor.zig");
    pub const result = @import("pipeline/result.zig");
};
pub const matching = struct {
    pub const normalization = @import("matching/normalization.zig");
    pub const exact_match = @import("matching/exact_match.zig");
    pub const blocking = @import("matching/blocking.zig");
    pub const index = @import("matching/index.zig");
    pub const scorer = @import("matching/scorer.zig");
    pub const levenshtein = @import("matching/levenshtein.zig");
    pub const jaro_winkler = @import("matching/jaro_winkler.zig");
    pub const matcher = @import("matching/matcher.zig");
    pub const match_result = @import("matching/match_result.zig");
    pub const match_sink = @import("matching/match_sink.zig");
};
pub const ingestion = struct {
    pub const type_infer = @import("ingestion/type_infer.zig");
    pub const converter = @import("ingestion/converter.zig");
    pub const ingest_reader = @import("ingestion/ingest_reader.zig");
};
pub const profiling = struct {
    pub const null_stats = @import("profiling/null_stats.zig");
    pub const length_stats = @import("profiling/length_stats.zig");
    pub const numeric_stats = @import("profiling/numeric_stats.zig");
    pub const hyperloglog = @import("profiling/hyperloglog.zig");
    pub const cardinality = @import("profiling/cardinality.zig");
    pub const pattern_detect = @import("profiling/pattern_detect.zig");
    pub const column_profiler = @import("profiling/column_profiler.zig");
    pub const profile_reader = @import("profiling/profile_reader.zig");
    pub const profile_report = @import("profiling/profile_report.zig");
};
pub const validation = struct {
    pub const rule = @import("validation/rule.zig");
    pub const compile = @import("validation/compile.zig");
    pub const evaluator = @import("validation/evaluator.zig");
    pub const regex = @import("validation/regex.zig");
    pub const unique = @import("validation/unique.zig");
    pub const violation = @import("validation/violation.zig");
    pub const violation_sink = @import("validation/violation_sink.zig");
    pub const validation_summary = @import("validation/validation_summary.zig");
    pub const rule_engine = @import("validation/rule_engine.zig");
};

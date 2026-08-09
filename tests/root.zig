comptime {
    _ = @import("core/batch_test.zig");
    _ = @import("ingestion/stream_test.zig");
    _ = @import("cleaning/transform_test.zig");
    _ = @import("cleaning/replay_test.zig");
    _ = @import("pipeline/pipeline_test.zig");
    _ = @import("matching/exact_test.zig");
    _ = @import("connectors/jsonl_test.zig");
    _ = @import("connectors/identity_test.zig");
    _ = @import("sinks/memory_test.zig");
    _ = @import("sinks/atomic_test.zig");
}

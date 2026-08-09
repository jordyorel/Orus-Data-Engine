const std = @import("std");
const engine = @import("orus_data_engine");

test "public core exposes all seven physical types" {
    try std.testing.expectEqual(@as(usize, 7), @typeInfo(engine.core.value.ValueTag).@"enum".fields.len);
}

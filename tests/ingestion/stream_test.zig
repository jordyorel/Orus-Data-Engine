const std = @import("std");
const engine = @import("orus_data_engine");

test "public date parser rejects invalid calendar dates" {
    try std.testing.expect(engine.ingestion.type_infer.parseDate("2024-02-29") != null);
    try std.testing.expect(engine.ingestion.type_infer.parseDate("2023-02-29") == null);
}

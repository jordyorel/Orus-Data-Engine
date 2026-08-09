const std = @import("std");
const engine = @import("orus_data_engine");

test "public cleaning operation is allocation free" {
    var output: [16]u8 = undefined;
    try std.testing.expectEqualStrings(
        "ORUS",
        try engine.cleaning.string_ops.apply(.uppercase, "Orus", &output),
    );
}

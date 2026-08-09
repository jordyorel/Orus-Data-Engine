const std = @import("std");
const engine = @import("orus_data_engine");

pub fn main() !void {
    var output: [64]u8 = undefined;
    var bytes: usize = 0;
    for (0..10_000_000) |_| {
        bytes += (try engine.cleaning.string_ops.apply(.uppercase, "customer name", &output)).len;
    }
    std.debug.print("cleaning operations=10000000 bytes={d}\n", .{bytes});
}

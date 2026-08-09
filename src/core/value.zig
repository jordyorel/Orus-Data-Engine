const decimal = @import("decimal.zig");

pub const ValueTag = enum(u8) {
    i64,
    f64,
    decimal,
    boolean,
    string,
    date,
    datetime,
};

/// Convenience representation for tests, debugging, and occasional access.
/// Hot loops access column buffers directly.
pub const Value = union(ValueTag) {
    i64: i64,
    f64: f64,
    decimal: decimal.Decimal128,
    boolean: bool,
    string: []const u8,
    date: i32,
    datetime: i64,
};

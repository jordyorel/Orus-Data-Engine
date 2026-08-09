pub const RowId = struct {
    source_id: u128,
    batch_id: u64,
    row_in_batch: u32,
    global_offset: u64,
};

pub const Code = enum(u16) {
    required_missing,
    enum_mismatch,
    below_minimum,
    above_maximum,
    pattern_mismatch,
    invalid_length,
    regex_mismatch,
    duplicate_value,
};

pub const Violation = struct {
    row_id: RowId,
    column_index: u32,
    rule_id: u32,
    code: Code,
};

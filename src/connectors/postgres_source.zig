const std = @import("std");
const arena_pool = @import("../core/arena_pool.zig");
const batch_mod = @import("../core/batch.zig");
const reader_mod = @import("../core/reader.zig");
const schema_mod = @import("../core/schema.zig");
const source_identity = @import("../core/source_identity.zig");
const value_mod = @import("../core/value.zig");
const source_mod = @import("source.zig");

const PGconn = opaque {};
const PGresult = opaque {};

extern fn PQconnectdb(conninfo: [*:0]const u8) ?*PGconn;
extern fn PQstatus(connection: *const PGconn) c_int;
extern fn PQerrorMessage(connection: *const PGconn) [*:0]const u8;
extern fn PQfinish(connection: *PGconn) void;
extern fn PQsendQuery(connection: *PGconn, query: [*:0]const u8) c_int;
extern fn PQsetSingleRowMode(connection: *PGconn) c_int;
extern fn PQgetResult(connection: *PGconn) ?*PGresult;
extern fn PQresultStatus(result: *const PGresult) c_int;
extern fn PQnfields(result: *const PGresult) c_int;
extern fn PQfname(result: *const PGresult, column: c_int) ?[*:0]const u8;
extern fn PQftype(result: *const PGresult, column: c_int) u32;
extern fn PQgetisnull(result: *const PGresult, row: c_int, column: c_int) c_int;
extern fn PQgetvalue(result: *const PGresult, row: c_int, column: c_int) [*]const u8;
extern fn PQgetlength(result: *const PGresult, row: c_int, column: c_int) c_int;
extern fn PQclear(result: *PGresult) void;

const connection_ok = 0;
const tuples_ok = 2;
const single_tuple = 9;

pub const PostgresOptions = struct {
    batch_size: usize = 8192,
    source_name: []const u8 = "postgres",
};

pub const PostgresSource = struct {
    allocator: std.mem.Allocator,
    connection: *PGconn,
    query: [:0]u8,
    identity_value: source_identity.SourceIdentity,
    options: PostgresOptions,
    schema_value: ?schema_mod.Schema = null,
    started: bool = false,
    complete: bool = false,
    next_batch_id: u64 = 0,
    global_row_offset: u64 = 0,
    bytes_consumed: u64 = 0,

    /// Opens a PostgreSQL connection. `source_name` is public metadata; the
    /// connection string is never retained or exposed after PQconnectdb.
    pub fn init(
        allocator: std.mem.Allocator,
        conninfo: []const u8,
        query: []const u8,
        options: PostgresOptions,
    ) !PostgresSource {
        if (options.batch_size == 0) return error.InvalidBatchSize;
        if (conninfo.len == 0) return error.EmptyPostgresConnection;
        if (query.len == 0) return error.EmptyPostgresQuery;
        const conninfo_z = try allocator.dupeZ(u8, conninfo);
        defer allocator.free(conninfo_z);
        const connection = PQconnectdb(conninfo_z.ptr) orelse return error.PostgresConnectionFailed;
        errdefer PQfinish(connection);
        if (PQstatus(connection) != connection_ok) return error.PostgresConnectionFailed;
        const query_z = try allocator.dupeZ(u8, query);
        errdefer allocator.free(query_z);
        const source_name = try allocator.dupe(u8, options.source_name);
        errdefer allocator.free(source_name);
        return .{
            .allocator = allocator,
            .connection = connection,
            .query = query_z,
            .identity_value = .{
                .id = @as(u128, std.hash.Wyhash.hash(0, options.source_name)),
                .version = std.hash.XxHash3.hash(0, query),
                .uri = source_name,
            },
            .options = options,
        };
    }

    pub fn deinit(self: *PostgresSource) void {
        if (self.schema_value) |*schema_value| schema_value.deinit(self.allocator);
        self.allocator.free(self.identity_value.uri);
        self.allocator.free(self.query);
        PQfinish(self.connection);
    }

    /// Returns the latest libpq diagnostic. The slice is borrowed until the
    /// next libpq call or deinit and may contain server-provided details.
    pub fn lastError(self: *const PostgresSource) []const u8 {
        return std.mem.span(PQerrorMessage(self.connection));
    }

    pub fn nextRaw(self: *PostgresSource, output: *arena_pool.BatchArena) !?batch_mod.Batch {
        if (self.complete) return null;
        if (!self.started) {
            if (PQsendQuery(self.connection, self.query.ptr) != 1) return error.PostgresQueryFailed;
            if (PQsetSingleRowMode(self.connection) != 1) return error.PostgresSingleRowModeFailed;
            self.started = true;
        }

        var builder: ?batch_mod.Builder = null;
        while (builder == null or builder.?.row_count < self.options.batch_size) {
            const result = PQgetResult(self.connection) orelse {
                self.complete = true;
                break;
            };
            defer PQclear(result);
            switch (PQresultStatus(result)) {
                single_tuple => {
                    if (self.schema_value == null) self.schema_value = try buildSchema(self.allocator, result);
                    if (builder == null) builder = try batch_mod.Builder.init(output, &self.schema_value.?);
                    try appendRow(&builder.?, result, &self.bytes_consumed);
                    try builder.?.finishRow();
                },
                tuples_ok => {},
                else => return error.PostgresQueryFailed,
            }
        }
        if (builder == null or builder.?.row_count == 0) return null;
        const output_batch = try builder.?.finish(.{
            .source_id = self.identity_value.id,
            .source_version = self.identity_value.version,
            .batch_id = self.next_batch_id,
            .global_row_offset = self.global_row_offset,
        });
        self.next_batch_id += 1;
        self.global_row_offset += output_batch.row_count;
        return output_batch;
    }

    pub fn asReader(self: *PostgresSource) reader_mod.Reader {
        return .{ .ptr = self, .next_fn = nextOpaque };
    }

    pub fn asSource(self: *PostgresSource) source_mod.Source {
        return .{
            .ptr = self,
            .next_raw_fn = nextOpaque,
            .schema_fn = schemaOpaque,
            .identity_fn = identityOpaque,
            .capabilities_fn = capabilitiesOpaque,
            .bytes_read_fn = bytesReadOpaque,
        };
    }

    fn nextOpaque(ptr: *anyopaque, output: *arena_pool.BatchArena) anyerror!?batch_mod.Batch {
        return (@as(*PostgresSource, @ptrCast(@alignCast(ptr)))).nextRaw(output);
    }
    fn schemaOpaque(ptr: *anyopaque) ?*const schema_mod.Schema {
        const self: *PostgresSource = @ptrCast(@alignCast(ptr));
        return if (self.schema_value) |*value| value else null;
    }
    fn identityOpaque(ptr: *anyopaque) source_identity.SourceIdentity {
        return (@as(*PostgresSource, @ptrCast(@alignCast(ptr)))).identity_value;
    }
    fn capabilitiesOpaque(_: *anyopaque) source_mod.SourceCapabilities {
        return .{ .replayable = false, .seekable = false, .bounded = false, .schema_known = false };
    }
    fn bytesReadOpaque(ptr: *anyopaque) u64 {
        return (@as(*PostgresSource, @ptrCast(@alignCast(ptr)))).bytes_consumed;
    }
};

fn buildSchema(allocator: std.mem.Allocator, result: *const PGresult) !schema_mod.Schema {
    const field_count: usize = @intCast(PQnfields(result));
    if (field_count == 0) return error.EmptyPostgresSchema;
    const fields = try allocator.alloc(schema_mod.Field, field_count);
    errdefer allocator.free(fields);
    var initialized: usize = 0;
    errdefer for (fields[0..initialized]) |field| allocator.free(field.name);
    for (fields, 0..) |*field, index| {
        const name = PQfname(result, @intCast(index)) orelse return error.InvalidPostgresField;
        const name_slice = std.mem.span(name);
        for (fields[0..initialized]) |previous| {
            if (std.mem.eql(u8, previous.name, name_slice)) return error.DuplicatePostgresField;
        }
        field.* = .{
            .name = try allocator.dupe(u8, name_slice),
            .tag = tagForOid(PQftype(result, @intCast(index))),
            .nullable = true,
        };
        initialized += 1;
    }
    return .{ .fields = fields, .hash = schema_mod.Schema.computeHash(fields) };
}

fn appendRow(builder: *batch_mod.Builder, result: *const PGresult, bytes: *u64) !void {
    for (builder.schema.fields, 0..) |field, index| {
        if (PQgetisnull(result, 0, @intCast(index)) != 0) {
            try builder.appendNull(index);
            continue;
        }
        const length: usize = @intCast(PQgetlength(result, 0, @intCast(index)));
        const text = PQgetvalue(result, 0, @intCast(index))[0..length];
        bytes.* += length;
        switch (field.tag) {
            .i64 => try builder.appendI64(index, try std.fmt.parseInt(i64, text, 10)),
            .f64 => try builder.appendF64(index, try std.fmt.parseFloat(f64, text)),
            .boolean => if (std.mem.eql(u8, text, "t"))
                try builder.appendBoolean(index, true)
            else if (std.mem.eql(u8, text, "f"))
                try builder.appendBoolean(index, false)
            else
                return error.InvalidPostgresBoolean,
            .string => try builder.appendString(index, text),
            .decimal, .date, .datetime => unreachable,
        }
    }
}

fn tagForOid(oid: u32) value_mod.ValueTag {
    return switch (oid) {
        16 => .boolean,
        20, 21, 23 => .i64,
        700, 701 => .f64,
        else => .string,
    };
}

test "PostgreSQL OIDs map only lossless primitive types" {
    try std.testing.expectEqual(value_mod.ValueTag.boolean, tagForOid(16));
    try std.testing.expectEqual(value_mod.ValueTag.i64, tagForOid(20));
    try std.testing.expectEqual(value_mod.ValueTag.f64, tagForOid(701));
    try std.testing.expectEqual(value_mod.ValueTag.string, tagForOid(1700));
    try std.testing.expectEqual(value_mod.ValueTag.string, tagForOid(1184));
}

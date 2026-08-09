const std = @import("std");
const engine = @import("orus_data_engine");

pub fn main(init: std.process.Init) !void {
    var source = engine.connectors.postgres_source.PostgresSource.init(
        init.gpa,
        "host=/tmp port=55432 dbname=postgres",
        \\SELECT value::bigint AS id,
        \\       CASE WHEN value % 7 = 0 THEN NULL ELSE 'customer-' || value END AS name,
        \\       (value % 2 = 0) AS active,
        \\       value::double precision / 10 AS score
        \\FROM generate_series(1, 20000) AS value
        \\ORDER BY value
    ,
        .{ .batch_size = 1024, .source_name = "integration/customers" },
    ) catch |err| {
        if (err == error.PostgresConnectionFailed) {
            std.debug.print(
                "PostgreSQL integration server is unavailable. Start it with:\n" ++
                    "  /opt/homebrew/opt/postgresql@18/bin/pg_ctl -D /opt/homebrew/var/postgresql@18 " ++
                    "-l /tmp/orus-postgres.log -o \"-p 55432 -k /tmp\" start\n",
                .{},
            );
        }
        return err;
    };
    defer source.deinit();
    var arena = engine.core.arena_pool.BatchArena.init(init.gpa);
    defer arena.deinit();
    var rows: u64 = 0;
    var batches: u64 = 0;
    while (try source.nextRaw(&arena)) |input| {
        if (input.metadata.global_row_offset != rows) return error.InvalidGlobalOffset;
        if (input.schema.fields[0].tag != .i64 or
            input.schema.fields[1].tag != .string or
            input.schema.fields[2].tag != .boolean or
            input.schema.fields[3].tag != .f64)
        {
            return error.InvalidPostgresSchema;
        }
        rows += input.row_count;
        batches += 1;
        arena.reset();
    }
    if (rows != 20_000 or batches != 20) return error.InvalidPostgresStreamingResult;
    if (source.bytes_consumed == 0) return error.MissingPostgresByteMetric;
    if (!std.mem.eql(u8, source.identity_value.uri, "integration/customers")) {
        return error.PostgresIdentityLeaksConnection;
    }
    std.debug.print("postgres rows={d} batches={d} bytes={d}\n", .{
        rows,
        batches,
        source.bytes_consumed,
    });
}

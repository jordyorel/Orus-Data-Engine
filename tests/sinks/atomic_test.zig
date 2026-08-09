const std = @import("std");
const engine = @import("orus_data_engine");

test "CSV and JSONL abort preserve an existing destination" {
    const csv_path = ".zig-cache/atomic-abort.csv";
    const jsonl_path = ".zig-cache/atomic-abort.jsonl";
    defer remove(csv_path);
    defer remove(jsonl_path);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = csv_path, .data = "existing-csv\n" });
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = jsonl_path, .data = "existing-jsonl\n" });

    var source = try engine.connectors.jsonl_source.JsonlSource.init(
        std.testing.io,
        std.testing.allocator,
        "fixtures/jsonl/customers.jsonl",
        .{},
    );
    defer source.deinit();
    var arena = engine.core.arena_pool.BatchArena.init(std.testing.allocator);
    defer arena.deinit();
    const input = (try source.nextRaw(&arena)).?;

    var csv = try engine.sinks.csv_sink.CsvSink.open(std.testing.io, std.testing.allocator, csv_path);
    try csv.write(&input);
    csv.asSink().abort();
    csv.deinit();
    try expectFile(csv_path, "existing-csv\n");

    var jsonl = try engine.sinks.jsonl_sink.JsonlSink.open(std.testing.io, std.testing.allocator, jsonl_path);
    try jsonl.write(&input);
    jsonl.asSink().abort();
    jsonl.deinit();
    try expectFile(jsonl_path, "existing-jsonl\n");
}

test "finish atomically replaces an existing CSV destination" {
    const path = ".zig-cache/atomic-finish.csv";
    defer remove(path);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = path, .data = "old\n" });
    var source = try engine.connectors.jsonl_source.JsonlSource.init(
        std.testing.io,
        std.testing.allocator,
        "fixtures/jsonl/customers.jsonl",
        .{},
    );
    defer source.deinit();
    var arena = engine.core.arena_pool.BatchArena.init(std.testing.allocator);
    defer arena.deinit();
    const input = (try source.nextRaw(&arena)).?;
    var csv = try engine.sinks.csv_sink.CsvSink.open(std.testing.io, std.testing.allocator, path);
    try csv.write(&input);
    try csv.finish();
    csv.deinit();
    const contents = try read(path);
    defer std.testing.allocator.free(contents);
    try std.testing.expect(std.mem.startsWith(u8, contents, "id,name,active,score\n"));
    try std.testing.expect(!std.mem.eql(u8, contents, "old\n"));
}

test "unfinished audit log preserves an existing destination" {
    const path = ".zig-cache/atomic-audit.jsonl";
    defer remove(path);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = path, .data = "existing-audit\n" });
    var audit = try engine.cleaning.audit_log.AuditLog.open(std.testing.io, std.testing.allocator, path);
    audit.deinit();
    try expectFile(path, "existing-audit\n");
}

test "violation file sink is atomic on finish and abort" {
    const path = ".zig-cache/atomic-violations.jsonl";
    defer remove(path);
    const item = engine.validation.violation.Violation{
        .row_id = .{ .source_id = 1, .batch_id = 2, .row_in_batch = 3, .global_offset = 4 },
        .column_index = 5,
        .rule_id = 6,
        .code = .required_missing,
    };
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = path, .data = "existing\n" });
    var aborted = try engine.validation.violation_sink.JsonlFileSink.open(
        std.testing.io,
        std.testing.allocator,
        path,
    );
    try aborted.asSink().write(&.{item});
    aborted.asSink().abort();
    aborted.deinit();
    try expectFile(path, "existing\n");

    var finished = try engine.validation.violation_sink.JsonlFileSink.open(
        std.testing.io,
        std.testing.allocator,
        path,
    );
    try finished.asSink().write(&.{item});
    try finished.asSink().finish();
    finished.deinit();
    const contents = try read(path);
    defer std.testing.allocator.free(contents);
    try std.testing.expect(std.mem.indexOf(u8, contents, "required_missing") != null);
    try std.testing.expect(!std.mem.eql(u8, contents, "existing\n"));
}

test "JSONL serialization failure cannot publish a partial file" {
    const path = ".zig-cache/atomic-json-error.jsonl";
    defer remove(path);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = path, .data = "stable\n" });
    const fields = [_]engine.core.schema.Field{.{ .name = "value", .tag = .f64 }};
    const schema = engine.core.schema.Schema{
        .fields = &fields,
        .hash = engine.core.schema.Schema.computeHash(&fields),
    };
    var arena = engine.core.arena_pool.BatchArena.init(std.testing.allocator);
    defer arena.deinit();
    var builder = try engine.core.batch.Builder.init(&arena, &schema);
    try builder.appendF64(0, std.math.nan(f64));
    try builder.finishRow();
    const input = try builder.finish(.{});
    var output = try engine.sinks.jsonl_sink.JsonlSink.open(
        std.testing.io,
        std.testing.allocator,
        path,
    );
    try std.testing.expectError(error.NonFiniteJsonNumber, output.write(&input));
    output.deinit();
    try expectFile(path, "stable\n");
}

fn expectFile(path: []const u8, expected: []const u8) !void {
    const contents = try read(path);
    defer std.testing.allocator.free(contents);
    try std.testing.expectEqualStrings(expected, contents);
}

fn read(path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, std.testing.allocator, .limited(1024 * 1024));
}

fn remove(path: []const u8) void {
    std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => std.debug.panic("cannot remove atomic test output: {s}", .{@errorName(err)}),
    };
}

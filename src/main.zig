const std = @import("std");
const engine = @import("orus_data_engine");

pub fn main(init: std.process.Init) !void {
    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.next();
    const command = args.next() orelse return usage();
    const path = args.next() orelse return usage();
    if (std.mem.eql(u8, command, "replay")) {
        const audit_path = args.next() orelse return usage();
        const output_path = args.next() orelse return usage();
        const batch_size = if (args.next()) |raw| try std.fmt.parseInt(usize, raw, 10) else 1024;
        return runReplay(init, path, audit_path, output_path, batch_size);
    }
    if (std.mem.eql(u8, command, "clean")) {
        const output_path = args.next() orelse return usage();
        const column_name = args.next() orelse return usage();
        const operation_name = args.next() orelse return usage();
        const batch_size = if (args.next()) |raw| try std.fmt.parseInt(usize, raw, 10) else 1024;
        return runClean(init, path, output_path, column_name, operation_name, batch_size);
    }
    if (std.mem.eql(u8, command, "validate")) {
        const rules_path = args.next() orelse return usage();
        const batch_size = if (args.next()) |raw| try std.fmt.parseInt(usize, raw, 10) else 1024;
        return runValidate(init, path, rules_path, batch_size);
    }
    if (std.mem.eql(u8, command, "export-jsonl")) {
        const source_id = args.next() orelse return usage();
        const run_id = args.next() orelse return usage();
        const observed_at = args.next() orelse return usage();
        const batch_size = if (args.next()) |raw| try std.fmt.parseInt(usize, raw, 10) else 1024;
        const start_offset = if (args.next()) |raw| try std.fmt.parseInt(u64, raw, 10) else 0;
        const max_rows = if (args.next()) |raw| try std.fmt.parseInt(u64, raw, 10) else null;
        return runExportJsonl(
            init,
            path,
            source_id,
            run_id,
            observed_at,
            batch_size,
            start_offset,
            max_rows,
        );
    }
    const batch_size = if (args.next()) |raw| try std.fmt.parseInt(usize, raw, 10) else 1024;
    if (std.mem.eql(u8, command, "benchmark")) return runBenchmark(init, path, batch_size);
    if (std.mem.eql(u8, command, "profile")) return runProfile(init, path, batch_size);
    if (std.mem.eql(u8, command, "infer")) return runInfer(init, path, batch_size);
    return usage();
}

fn runExportJsonl(
    init: std.process.Init,
    path: []const u8,
    source_id: []const u8,
    run_id: []const u8,
    observed_at: []const u8,
    batch_size: usize,
    start_offset: u64,
    max_rows: ?u64,
) !void {
    var allocators = engine.execution.allocators.PipelineAllocators.init(init.gpa);
    defer allocators.deinit();
    var csv_source = try engine.connectors.csv_source.CsvSource.init(
        init.io,
        allocators.run(),
        path,
        .{ .batch_size = batch_size },
    );
    defer csv_source.deinit();
    var ingest = engine.ingestion.ingest_reader.IngestReader.init(
        allocators.run(),
        csv_source.asSource(),
        .{},
    );
    defer ingest.deinit();

    var output_buffer: [64 * 1024]u8 = undefined;
    var output = std.Io.File.stdout().writerStreaming(init.io, &output_buffer);
    var batch_id: u64 = 0;
    var global_offset: u64 = 0;
    var rows_emitted: u64 = 0;
    while (try ingest.next(allocators.batches.input())) |typed| {
        for (0..typed.row_count) |row| {
            if (global_offset < start_offset) {
                global_offset += 1;
                continue;
            }
            if (max_rows != null and rows_emitted >= max_rows.?) {
                try output.interface.flush();
                return;
            }
            try output.interface.print(
                "{{\"contract_version\":1,\"record\":",
                .{},
            );
            try engine.sinks.jsonl_sink.writeRowObject(&output.interface, &typed, row);
            try output.interface.print(
                ",\"source\":{{\"source_id\":{f},\"batch_id\":{d},\"row_id\":{d}," ++
                    "\"global_offset\":{d},\"observed_at\":{f}}},\"run_id\":{f}}}\n",
                .{
                    std.json.fmt(source_id, .{}),
                    batch_id,
                    row,
                    global_offset,
                    std.json.fmt(observed_at, .{}),
                    std.json.fmt(run_id, .{}),
                },
            );
            global_offset += 1;
            rows_emitted += 1;
        }
        batch_id += 1;
        try output.interface.flush();
        allocators.batches.input().reset();
    }
    try output.interface.flush();
}

fn runReplay(
    init: std.process.Init,
    path: []const u8,
    audit_path: []const u8,
    output_path: []const u8,
    batch_size: usize,
) !void {
    var allocators = engine.execution.allocators.PipelineAllocators.init(init.gpa);
    defer allocators.deinit();
    var csv_source = try engine.connectors.csv_source.CsvSource.init(
        init.io,
        allocators.run(),
        path,
        .{ .batch_size = batch_size },
    );
    defer csv_source.deinit();
    var ingest = engine.ingestion.ingest_reader.IngestReader.init(
        allocators.run(),
        csv_source.asSource(),
        .{},
    );
    defer ingest.deinit();
    var replay = try engine.cleaning.replay.ReplayReader.init(
        init.io,
        allocators.run(),
        ingest.asReader(),
        audit_path,
        .{},
    );
    defer replay.deinit();
    var output = try engine.sinks.csv_sink.CsvSink.open(
        init.io,
        allocators.run(),
        output_path,
    );
    defer output.deinit();
    var rows: u64 = 0;
    var batches: u64 = 0;
    while (try replay.next(allocators.batches.input())) |replayed| {
        try output.write(&replayed);
        rows += replayed.row_count;
        batches += 1;
        allocators.batches.input().reset();
    }
    try output.finish();
    std.debug.print("replayed: rows={d} batches={d} output={s}\n", .{ rows, batches, output_path });
}

fn runBenchmark(init: std.process.Init, path: []const u8, batch_size: usize) !void {
    var allocators = engine.execution.allocators.PipelineAllocators.init(init.gpa);
    defer allocators.deinit();
    var csv_source = try engine.connectors.csv_source.CsvSource.init(
        init.io,
        allocators.run(),
        path,
        .{ .batch_size = batch_size },
    );
    defer csv_source.deinit();
    var ingest = engine.ingestion.ingest_reader.IngestReader.init(
        allocators.run(),
        csv_source.asSource(),
        .{},
    );
    defer ingest.deinit();

    const wall_start = std.Io.Timestamp.now(init.io, .awake);
    const cpu_start = std.Io.Timestamp.now(init.io, .cpu_process);
    var measured = engine.execution.metrics.Metrics{};
    var next_progress_bytes: u64 = 1024 * 1024 * 1024;
    while (try ingest.next(allocators.batches.input())) |typed_batch| {
        measured.observeBatch(&typed_batch);
        if (csv_source.bytes_consumed >= next_progress_bytes) {
            const elapsed = wall_start.durationTo(std.Io.Timestamp.now(init.io, .awake));
            const elapsed_seconds = @as(f64, @floatFromInt(elapsed.nanoseconds)) / 1_000_000_000;
            const mib = csv_source.bytes_consumed / (1024 * 1024);
            const mib_per_second = if (elapsed_seconds == 0)
                0
            else
                @as(f64, @floatFromInt(mib)) / elapsed_seconds;
            std.debug.print("progress: rows={d} read_mib={d} mib_per_second={d:.2}\n", .{
                measured.rows_read,
                mib,
                mib_per_second,
            });
            while (next_progress_bytes <= csv_source.bytes_consumed) {
                next_progress_bytes += 1024 * 1024 * 1024;
            }
        }
        allocators.batches.input().reset();
    }
    const wall_end = std.Io.Timestamp.now(init.io, .awake);
    const cpu_end = std.Io.Timestamp.now(init.io, .cpu_process);
    measured.bytes_read = csv_source.bytes_consumed;
    const result = engine.execution.metrics.BenchmarkResult.init(
        measured,
        csv_source.bytes_consumed,
        ingest.invalid_values,
        wall_start.durationTo(wall_end).nanoseconds,
        cpu_start.durationTo(cpu_end).nanoseconds,
        peakResidentBytes(),
    );

    const json = try std.json.Stringify.valueAlloc(allocators.run(), result, .{ .whitespace = .indent_2 });
    var output_buffer: [4096]u8 = undefined;
    var output = std.Io.File.stdout().writerStreaming(init.io, &output_buffer);
    try output.interface.print("{{\n  \"file\": {f},\n  \"batch_size\": {d},\n  \"mode\": \"typed_ingestion\",\n", .{
        std.json.fmt(path, .{}),
        batch_size,
    });
    try output.interface.writeAll(json[1..]);
    try output.interface.writeByte('\n');
    try output.interface.flush();
}

fn peakResidentBytes() ?u64 {
    return switch (@import("builtin").os.tag) {
        .linux => @as(u64, @intCast(std.posix.getrusage(std.c.rusage.SELF).maxrss)) * 1024,
        .driverkit, .ios, .maccatalyst, .macos, .tvos, .visionos, .watchos => @intCast(std.posix.getrusage(std.c.rusage.SELF).maxrss),
        else => null,
    };
}

fn runClean(
    init: std.process.Init,
    path: []const u8,
    output_path: []const u8,
    column_name: []const u8,
    operation_name: []const u8,
    batch_size: usize,
) !void {
    var context = try engine.execution.context.ExecutionContext.init(init.gpa, 1, "/tmp");
    defer context.deinit();
    var csv_source = try engine.connectors.csv_source.CsvSource.init(
        init.io,
        context.allocators.run(),
        path,
        .{ .batch_size = batch_size },
    );
    defer csv_source.deinit();
    var ingest = engine.ingestion.ingest_reader.IngestReader.init(
        context.allocators.run(),
        csv_source.asSource(),
        .{},
    );
    defer ingest.deinit();
    var output_sink = try engine.sinks.csv_sink.CsvSink.open(
        init.io,
        context.allocators.run(),
        output_path,
    );
    defer output_sink.deinit();
    const audit_path = try std.fmt.allocPrint(context.allocators.run(), "{s}.audit.jsonl", .{output_path});
    var audit = try engine.cleaning.audit_log.AuditLog.open(
        init.io,
        context.allocators.run(),
        audit_path,
    );
    defer audit.deinit();
    var compiled: ?engine.cleaning.transform.StringTransform = null;
    var spec: ?engine.cleaning.transform_registry.TransformSpec = null;
    while (try ingest.next(context.allocators.batches.input())) |typed| {
        if (compiled == null) {
            spec = .{
                .id = 1,
                .column = column_name,
                .operation = try parseRegistryOperation(operation_name),
            };
            compiled = try spec.?.compile(typed.schema);
        }
        const cleaned = try compiled.?.asTransform().apply(
            &typed,
            context.allocators.batches.output(),
            context.allocators.scratch.allocator(),
        );
        try output_sink.write(&cleaned);
        const specs = [_]engine.cleaning.transform_registry.TransformSpec{spec.?};
        const entry = engine.cleaning.provenance.create(
            context.run_id,
            &specs,
            &typed,
            &cleaned,
            std.Io.Timestamp.now(init.io, .real).toMilliseconds(),
        );
        try audit.record(&entry);
        context.metrics.observeBatch(&cleaned);
        context.allocators.batches.input().reset();
        context.allocators.batches.output().reset();
        context.allocators.scratch.reset();
    }
    try output_sink.finish();
    _ = try audit.finish();
    std.debug.print("cleaned: rows={d} batches={d} output={s}\n", .{
        context.metrics.rows_read,
        context.metrics.batches_read,
        output_path,
    });
}

fn parseRegistryOperation(name: []const u8) !engine.cleaning.transform_registry.Operation {
    if (std.mem.eql(u8, name, "trim")) return .trim;
    if (std.mem.eql(u8, name, "uppercase")) return .uppercase;
    if (std.mem.eql(u8, name, "lowercase")) return .lowercase;
    return error.UnknownOperation;
}

fn runValidate(
    init: std.process.Init,
    path: []const u8,
    rules_path: []const u8,
    batch_size: usize,
) !void {
    var allocators = engine.execution.allocators.PipelineAllocators.init(init.gpa);
    defer allocators.deinit();
    const rules_json = try std.Io.Dir.cwd().readFileAlloc(
        init.io,
        rules_path,
        allocators.run(),
        .limited(16 * 1024 * 1024),
    );
    const definitions = try std.json.parseFromSliceLeaky(
        []const engine.validation.rule.Rule,
        allocators.run(),
        rules_json,
        .{},
    );
    var csv_source = try engine.connectors.csv_source.CsvSource.init(
        init.io,
        allocators.run(),
        path,
        .{ .batch_size = batch_size },
    );
    defer csv_source.deinit();
    var ingest = engine.ingestion.ingest_reader.IngestReader.init(
        allocators.run(),
        csv_source.asSource(),
        .{},
    );
    defer ingest.deinit();
    var samples = engine.validation.violation_sink.SamplingSink.init(allocators.run(), 100);
    defer samples.deinit();
    var validator = engine.validation.rule_engine.RuleEngine.init(
        allocators.run(),
        ingest.asReader(),
        definitions,
        samples.asSink(),
        .{},
    );
    defer validator.deinit();
    while (try validator.next(allocators.batches.input())) |_| {
        if (validator.summary.batches_processed % 100 == 0) {
            std.debug.print("progress: rows={d} violations={d}\n", .{
                validator.summary.rows_processed,
                validator.summary.total_violations,
            });
        }
        allocators.batches.input().reset();
    }
    var summary = (try validator.finalize()).*;
    summary.output_truncated = samples.truncated();
    summary.samples = samples.samples.items;
    const json = try summary.toJson(allocators.run());
    var output_buffer: [64 * 1024]u8 = undefined;
    var output = std.Io.File.stdout().writerStreaming(init.io, &output_buffer);
    try output.interface.writeAll(json);
    try output.interface.writeByte('\n');
    try output.interface.flush();
}

fn runProfile(init: std.process.Init, path: []const u8, batch_size: usize) !void {
    var allocators = engine.execution.allocators.PipelineAllocators.init(init.gpa);
    defer allocators.deinit();
    var csv_source = try engine.connectors.csv_source.CsvSource.init(
        init.io,
        allocators.run(),
        path,
        .{ .batch_size = batch_size },
    );
    defer csv_source.deinit();
    var ingest = engine.ingestion.ingest_reader.IngestReader.init(
        allocators.run(),
        csv_source.asSource(),
        .{},
    );
    defer ingest.deinit();
    var profiler = engine.profiling.profile_reader.ProfileReader.init(
        allocators.run(),
        ingest.asReader(),
    );
    defer profiler.deinit();
    while (try profiler.next(allocators.batches.input())) |_| {
        if (profiler.batches_processed % 100 == 0) {
            std.debug.print("progress: rows={d} read_mib={d}\n", .{
                profiler.rows_processed,
                csv_source.bytes_consumed / (1024 * 1024),
            });
        }
        allocators.batches.input().reset();
    }
    var report = try profiler.finalize(allocators.run());
    defer report.deinit(allocators.run());
    const json = try report.toJson(allocators.run());
    var output_buffer: [64 * 1024]u8 = undefined;
    var output = std.Io.File.stdout().writerStreaming(init.io, &output_buffer);
    try output.interface.writeAll(json);
    try output.interface.writeByte('\n');
    try output.interface.flush();
}

fn runInfer(init: std.process.Init, path: []const u8, batch_size: usize) !void {
    var allocators = engine.execution.allocators.PipelineAllocators.init(init.gpa);
    defer allocators.deinit();
    var csv_source = try engine.connectors.csv_source.CsvSource.init(
        init.io,
        allocators.run(),
        path,
        .{ .batch_size = batch_size },
    );
    defer csv_source.deinit();
    var ingest = engine.ingestion.ingest_reader.IngestReader.init(
        allocators.run(),
        csv_source.asSource(),
        .{},
    );
    defer ingest.deinit();
    var metrics = engine.execution.metrics.Metrics{};
    while (try ingest.next(allocators.batches.input())) |typed_batch| {
        metrics.observeBatch(&typed_batch);
        if (metrics.batches_read % 100 == 0) {
            std.debug.print("progress: rows={d} read_mib={d}\n", .{
                metrics.rows_read,
                csv_source.bytes_consumed / (1024 * 1024),
            });
        }
        allocators.batches.input().reset();
    }

    var output_buffer: [4096]u8 = undefined;
    var output = std.Io.File.stdout().writerStreaming(init.io, &output_buffer);
    try output.interface.print("file: {s}\n", .{path});
    try output.interface.print("rows={d} batches={d} invalid_values={d}\n", .{
        metrics.rows_read,
        metrics.batches_read,
        ingest.invalid_values,
    });
    if (ingest.inferredSchema()) |inferred| {
        for (inferred.fields) |field| {
            try output.interface.print("{s}: type={s} nullable={}\n", .{
                field.name,
                @tagName(field.tag),
                field.nullable,
            });
        }
    }
    try output.interface.flush();
}

fn usage() !void {
    std.debug.print(
        "usage:\n  orusdata <profile|infer> <file.csv> [batch_size]\n" ++
            "  orusdata benchmark <file.csv> [batch_size]\n" ++
            "  orusdata validate <file.csv> <rules.json> [batch_size]\n" ++
            "  orusdata export-jsonl <file.csv> <source_id> <run_id> <observed_at> " ++
            "[batch_size] [start_offset] [max_rows]\n" ++
            "  orusdata clean <file.csv> <output.csv> <column> <trim|uppercase|lowercase> [batch_size]\n" ++
            "  orusdata replay <file.csv> <audit.jsonl> <output.csv> [batch_size]\n",
        .{},
    );
    return error.InvalidArguments;
}

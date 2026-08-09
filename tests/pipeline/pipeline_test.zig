const std = @import("std");
const engine = @import("orus_data_engine");

const CaptureSink = struct {
    rows: u64 = 0,
    batches: u64 = 0,
    names_lowercase: bool = true,
    finished: bool = false,
    aborted: bool = false,
    fail_write: bool = false,

    fn asSink(self: *CaptureSink) engine.core.sink.Sink {
        return .{
            .ptr = self,
            .write_fn = write,
            .finish_fn = finish,
            .abort_fn = abort,
        };
    }

    fn write(ptr: *anyopaque, input: *const engine.core.batch.Batch) !void {
        const self: *CaptureSink = @ptrCast(@alignCast(ptr));
        if (self.fail_write) return error.InjectedSinkFailure;
        const names = input.column(1).data.string;
        for (0..input.row_count) |row| {
            const name = names.get(row);
            self.names_lowercase = self.names_lowercase and name.len != 0 and std.ascii.isLower(name[0]);
        }
        self.rows += input.row_count;
        self.batches += 1;
    }

    fn finish(ptr: *anyopaque) !void {
        const self: *CaptureSink = @ptrCast(@alignCast(ptr));
        self.finished = true;
    }

    fn abort(ptr: *anyopaque) void {
        const self: *CaptureSink = @ptrCast(@alignCast(ptr));
        self.aborted = true;
    }
};

test "pipeline runs profile validation transform and sink end to end" {
    var csv = try engine.connectors.csv_source.CsvSource.init(
        std.testing.io,
        std.testing.allocator,
        "fixtures/sample.csv",
        .{ .batch_size = 2 },
    );
    defer csv.deinit();
    var context = try engine.execution.context.ExecutionContext.init(
        std.testing.allocator,
        42,
        "/tmp",
    );
    defer context.deinit();
    var violations = engine.validation.violation_sink.SamplingSink.init(std.testing.allocator, 10);
    defer violations.deinit();
    const rules = [_]engine.validation.rule.Rule{
        .{ .id = 1, .column = "id", .tag = .unique },
        .{ .id = 2, .column = "name", .tag = .regex, .regex = "^[A-Z][a-z]+$" },
    };
    const lowercase = engine.cleaning.transform.StringTransform{
        .id = 7,
        .column_index = 1,
        .operation = .lowercase,
    };
    const trim = engine.cleaning.transform.StringTransform{
        .id = 8,
        .column_index = 1,
        .operation = .trim,
    };
    var capture = CaptureSink{};
    var builder = engine.pipeline.builder.PipelineBuilder.init(std.testing.allocator, csv.asSource());
    defer builder.deinit();
    _ = builder.withProfiling();
    _ = builder.withValidation(&rules, violations.asSink());
    _ = try builder.withTransform(trim.asTransform());
    _ = try builder.withTransform(lowercase.asTransform());
    _ = builder.withSink(capture.asSink());
    var pipeline = try builder.build(&context);
    defer pipeline.deinit();

    try std.testing.expect(pipeline.plan.profiling_enabled);
    try std.testing.expect(pipeline.plan.validation_enabled);
    try std.testing.expect(pipeline.plan.requires_spill);
    try std.testing.expectEqual(@as(usize, 3), pipeline.plan.reader_stages.len);
    const result = try pipeline.run(&context, std.testing.io);

    try std.testing.expectEqual(@as(u64, 3), result.rows_read);
    try std.testing.expectEqual(@as(u64, 3), result.rows_written);
    try std.testing.expectEqual(@as(u64, 2), result.batches_processed);
    try std.testing.expectEqual(@as(u64, 0), result.invalid_values);
    try std.testing.expect(result.bytes_read > 0);
    try std.testing.expect(pipeline.plan.source_schema_hash != null);
    try std.testing.expectEqual(pipeline.plan.source_schema_hash, pipeline.plan.output_schema_hash);
    try std.testing.expectEqual(@as(u64, 3), result.profile.?.rows_processed);
    try std.testing.expectEqual(@as(u64, 0), result.validation.?.total_violations);
    try std.testing.expectEqual(@as(u64, 3), capture.rows);
    try std.testing.expect(capture.names_lowercase);
    try std.testing.expect(capture.finished);
    try std.testing.expect(violations.finished);
}

test "pipeline builder rejects incomplete and ambiguous plans" {
    var csv = try engine.connectors.csv_source.CsvSource.init(
        std.testing.io,
        std.testing.allocator,
        "fixtures/sample.csv",
        .{},
    );
    defer csv.deinit();
    var context = try engine.execution.context.ExecutionContext.init(
        std.testing.allocator,
        44,
        "/tmp",
    );
    defer context.deinit();
    var builder = engine.pipeline.builder.PipelineBuilder.init(std.testing.allocator, csv.asSource());
    defer builder.deinit();
    try std.testing.expectError(error.MissingSink, builder.build(&context));

    const first = engine.cleaning.transform.StringTransform{
        .id = 1,
        .column_index = 1,
        .operation = .trim,
    };
    const duplicate = engine.cleaning.transform.StringTransform{
        .id = 1,
        .column_index = 1,
        .operation = .lowercase,
    };
    _ = try builder.withTransform(first.asTransform());
    try std.testing.expectError(
        error.DuplicateTransformId,
        builder.withTransform(duplicate.asTransform()),
    );
}

test "pipeline aborts sink and records context on failure" {
    var csv = try engine.connectors.csv_source.CsvSource.init(
        std.testing.io,
        std.testing.allocator,
        "fixtures/sample.csv",
        .{ .batch_size = 2 },
    );
    defer csv.deinit();
    var context = try engine.execution.context.ExecutionContext.init(
        std.testing.allocator,
        43,
        "/tmp",
    );
    defer context.deinit();
    var capture = CaptureSink{ .fail_write = true };
    var builder = engine.pipeline.builder.PipelineBuilder.init(std.testing.allocator, csv.asSource());
    defer builder.deinit();
    _ = builder.withSink(capture.asSink());
    var pipeline = try builder.build(&context);
    defer pipeline.deinit();

    try std.testing.expectError(error.InjectedSinkFailure, pipeline.run(&context, std.testing.io));
    try std.testing.expect(capture.aborted);
    try std.testing.expectEqualStrings("sink", context.error_context.items()[0].stage);
    try std.testing.expectEqual(@as(?u64, 0), context.error_context.items()[0].batch_id);
}

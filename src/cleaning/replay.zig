const std = @import("std");
const arena_pool = @import("../core/arena_pool.zig");
const batch_mod = @import("../core/batch.zig");
const reader_mod = @import("../core/reader.zig");
const allocators = @import("../execution/allocators.zig");
const provenance = @import("provenance.zig");
const registry = @import("transform_registry.zig");

pub const Options = struct {
    max_record_bytes: usize = 1024 * 1024,
    max_transforms_per_batch: usize = 64,
};

pub const ReplayReader = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    source: reader_mod.Reader,
    file: std.Io.File,
    stream: std.Io.File.Reader,
    buffer: []u8,
    record: std.ArrayList(u8) = .empty,
    parse_arena: std.heap.ArenaAllocator,
    batches: arena_pool.BatchArenaPool,
    scratch: allocators.ScratchArena,
    options: Options,
    expected_run_id: ?u128 = null,
    completed: bool = false,

    pub fn init(
        io: std.Io,
        allocator: std.mem.Allocator,
        source: reader_mod.Reader,
        audit_path: []const u8,
        options: Options,
    ) !ReplayReader {
        if (options.max_record_bytes == 0) return error.InvalidReplayRecordLimit;
        if (options.max_transforms_per_batch == 0) return error.InvalidReplayTransformLimit;
        const file = try std.Io.Dir.cwd().openFile(io, audit_path, .{});
        errdefer file.close(io);
        const buffer = try allocator.alloc(u8, 64 * 1024);
        errdefer allocator.free(buffer);
        var self = ReplayReader{
            .allocator = allocator,
            .io = io,
            .source = source,
            .file = file,
            .stream = undefined,
            .buffer = buffer,
            .parse_arena = .init(allocator),
            .batches = .init(allocator),
            .scratch = .init(allocator),
            .options = options,
        };
        self.stream = file.readerStreaming(io, buffer);
        return self;
    }

    pub fn deinit(self: *ReplayReader) void {
        self.scratch.deinit();
        self.batches.deinit();
        self.parse_arena.deinit();
        self.record.deinit(self.allocator);
        self.allocator.free(self.buffer);
        self.file.close(self.io);
    }

    pub fn asReader(self: *ReplayReader) reader_mod.Reader {
        return .{ .ptr = self, .next_fn = nextOpaque };
    }

    pub fn next(self: *ReplayReader, output: *arena_pool.BatchArena) !?batch_mod.Batch {
        if (self.completed) return null;
        self.batches.input().reset();
        self.batches.output().reset();
        self.scratch.reset();
        _ = self.parse_arena.reset(.retain_capacity);

        const input = try self.source.next(self.batches.input()) orelse {
            if (try self.readRecord() != null) return error.ReplayHasExtraAuditEntries;
            self.completed = true;
            return null;
        };
        const encoded = try self.readRecord() orelse return error.ReplayAuditEndedEarly;
        const parsed = try std.json.parseFromSlice(
            provenance.Entry,
            self.parse_arena.allocator(),
            encoded,
            .{ .max_value_len = self.options.max_record_bytes },
        );
        const entry = parsed.value;
        try self.validateEntry(&input, entry);

        var current = input;
        for (entry.transforms, 0..) |spec, index| {
            const operation = try spec.compile(current.schema);
            const last = index + 1 == entry.transforms.len;
            const target = if (last) output else self.batches.output();
            const transformed = try operation.asTransform().apply(
                &current,
                target,
                self.scratch.allocator(),
            );
            current = transformed;
            self.scratch.reset();
            if (!last) self.batches.swap();
        }
        if (current.schema.hash != entry.output_schema_hash) return error.ReplayOutputSchemaMismatch;
        return current;
    }

    fn validateEntry(self: *ReplayReader, input: *const batch_mod.Batch, entry: provenance.Entry) !void {
        if (entry.format_version != registry.current_format_version) return error.UnsupportedAuditFormat;
        if (entry.transforms.len == 0) return error.EmptyReplayTransformList;
        if (entry.transforms.len > self.options.max_transforms_per_batch) return error.ReplayTransformLimit;
        if (entry.params_hash != registry.paramsHash(entry.transforms)) return error.ReplayParamsHashMismatch;
        if (entry.source_id != input.metadata.source_id or
            entry.source_version != input.metadata.source_version)
        {
            return error.ReplaySourceMismatch;
        }
        if (entry.batch_id != input.metadata.batch_id) return error.ReplayBatchMismatch;
        const end = std.math.add(u64, input.metadata.global_row_offset, input.row_count) catch
            return error.ReplayRowRangeOverflow;
        if (entry.global_row_range[0] != input.metadata.global_row_offset or
            entry.global_row_range[1] != end)
        {
            return error.ReplayRowRangeMismatch;
        }
        if (entry.input_schema_hash != input.schema.hash) return error.ReplayInputSchemaMismatch;
        if (self.expected_run_id) |run_id| {
            if (entry.pipeline_run_id != run_id) return error.ReplayRunMismatch;
        } else self.expected_run_id = entry.pipeline_run_id;
    }

    fn readRecord(self: *ReplayReader) !?[]const u8 {
        self.record.clearRetainingCapacity();
        const written = blk: {
            var writer: std.Io.Writer.Allocating = .fromArrayList(self.allocator, &self.record);
            defer self.record = writer.toArrayList();
            break :blk self.stream.interface.streamDelimiterLimit(
                &writer.writer,
                '\n',
                .limited(self.options.max_record_bytes),
            ) catch |err| switch (err) {
                error.StreamTooLong => return error.ReplayRecordTooLarge,
                else => |other| return other,
            };
        };
        const ended = self.stream.atEnd();
        if (!ended) self.stream.interface.toss(1);
        if (ended and written == 0) return null;
        if (self.record.getLastOrNull() == '\r') _ = self.record.pop();
        if (self.record.items.len == 0) return error.EmptyReplayRecord;
        return self.record.items;
    }

    fn nextOpaque(ptr: *anyopaque, output: *arena_pool.BatchArena) anyerror!?batch_mod.Batch {
        return (@as(*ReplayReader, @ptrCast(@alignCast(ptr)))).next(output);
    }
};

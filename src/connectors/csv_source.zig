const std = @import("std");
const arena_pool = @import("../core/arena_pool.zig");
const batch_mod = @import("../core/batch.zig");
const reader_mod = @import("../core/reader.zig");
const schema_mod = @import("../core/schema.zig");
const source_identity = @import("../core/source_identity.zig");
const source_mod = @import("source.zig");
const Io = std.Io;

pub const CsvOptions = struct {
    delimiter: u8 = ',',
    quote: u8 = '"',
    has_header: bool = true,
    batch_size: usize = 8192,
    max_record_bytes: usize = 16 * 1024 * 1024,
    malformed_row: MalformedRowPolicy = .fail,
    extra_columns: ExtraColumnPolicy = .fail,
    missing_columns: MissingColumnPolicy = .pad_null,
    invalid_utf8: InvalidUtf8Policy = .fail,
};

pub const MalformedRowPolicy = enum { fail, skip };
pub const ExtraColumnPolicy = enum { fail, ignore };
pub const MissingColumnPolicy = enum { fail, pad_null };
pub const InvalidUtf8Policy = enum { fail, allow };

pub const CsvSource = struct {
    io: Io,
    file: Io.File,
    stream: Io.File.Reader,
    buffer: []u8,
    allocator: std.mem.Allocator,
    options: CsvOptions,
    identity_value: source_identity.SourceIdentity,
    schema: ?schema_mod.Schema = null,
    record_scratch: std.ArrayList(u8) = .empty,
    field_scratch: std.ArrayList(u8) = .empty,
    next_batch_id: u64 = 0,
    global_row_offset: u64 = 0,
    bytes_consumed: u64 = 0,
    content_hasher: std.crypto.hash.sha2.Sha256 = .init(.{}),
    content_hash_finalized: bool = false,

    /// Opens a CSV file. The source owns its URI, schema, parsing buffers, and
    /// file handle until deinit.
    pub fn init(
        io: Io,
        allocator: std.mem.Allocator,
        path: []const u8,
        options: CsvOptions,
    ) !CsvSource {
        if (options.batch_size == 0) return error.InvalidBatchSize;
        if (options.max_record_bytes == 0) return error.InvalidRecordLimit;
        const file = try Io.Dir.cwd().openFile(io, path, .{});
        errdefer file.close(io);
        const stat = try file.stat(io);
        const uri = try allocator.dupe(u8, path);
        errdefer allocator.free(uri);
        const buffer = try allocator.alloc(u8, 64 * 1024);
        errdefer allocator.free(buffer);

        var result = CsvSource{
            .io = io,
            .file = file,
            .stream = undefined,
            .allocator = allocator,
            .options = options,
            .buffer = buffer,
            .identity_value = .{
                .id = @as(u128, std.hash.Wyhash.hash(0, path)),
                .version = source_identity.fileVersion(path, stat),
                .uri = uri,
            },
        };
        result.stream = result.file.readerStreaming(io, result.buffer);
        return result;
    }

    pub fn deinit(self: *CsvSource) void {
        self.record_scratch.deinit(self.allocator);
        self.field_scratch.deinit(self.allocator);
        if (self.schema) |*source_schema| source_schema.deinit(self.allocator);
        self.allocator.free(self.buffer);
        self.allocator.free(self.identity_value.uri);
        self.file.close(self.io);
    }

    pub fn nextRaw(self: *CsvSource, output: *arena_pool.BatchArena) !?batch_mod.Batch {
        if (self.schema == null) {
            if (!self.options.has_header) return error.SchemaRequired;
            const header = try self.readRecord() orelse return null;
            self.schema = try parseSchema(self.allocator, header, self.options);
        }

        var builder = try batch_mod.Builder.init(output, &self.schema.?);
        while (builder.row_count < self.options.batch_size) {
            const record = try self.readRecord() orelse break;
            if (self.options.invalid_utf8 == .fail and !std.unicode.utf8ValidateSlice(record)) {
                if (self.options.malformed_row == .skip) continue;
                return error.InvalidUtf8;
            }
            const field_count = parseFields(
                self.allocator,
                record,
                self.options,
                null,
                null,
                &self.field_scratch,
            ) catch |err| {
                if (self.options.malformed_row == .skip) continue;
                return err;
            };
            if (field_count > self.schema.?.fields.len and self.options.extra_columns == .fail) {
                return error.ExtraColumns;
            }
            if (field_count < self.schema.?.fields.len and self.options.missing_columns == .fail) {
                return error.MissingColumns;
            }
            try parseRow(
                &builder,
                record,
                self.options,
                &self.field_scratch,
                self.allocator,
            );
            var missing = field_count;
            while (missing < self.schema.?.fields.len) : (missing += 1) {
                try builder.appendNull(missing);
            }
            try builder.finishRow();
        }
        if (builder.row_count == 0) return null;
        const output_batch = try builder.finish(.{
            .source_id = self.identity_value.id,
            .source_version = self.identity_value.version,
            .batch_id = self.next_batch_id,
            .global_row_offset = self.global_row_offset,
        });
        self.next_batch_id += 1;
        self.global_row_offset += output_batch.row_count;
        return output_batch;
    }

    pub fn asReader(self: *CsvSource) reader_mod.Reader {
        return .{ .ptr = self, .next_fn = nextOpaque };
    }

    pub fn asSource(self: *CsvSource) source_mod.Source {
        return .{
            .ptr = self,
            .next_raw_fn = nextOpaque,
            .schema_fn = schemaOpaque,
            .identity_fn = identityOpaque,
            .capabilities_fn = capabilitiesOpaque,
            .bytes_read_fn = bytesReadOpaque,
        };
    }

    fn nextOpaque(
        ptr: *anyopaque,
        output: *arena_pool.BatchArena,
    ) anyerror!?batch_mod.Batch {
        const self: *CsvSource = @ptrCast(@alignCast(ptr));
        return self.nextRaw(output);
    }

    fn schemaOpaque(ptr: *anyopaque) ?*const schema_mod.Schema {
        const self: *CsvSource = @ptrCast(@alignCast(ptr));
        return if (self.schema) |*source_schema| source_schema else null;
    }

    fn identityOpaque(ptr: *anyopaque) source_identity.SourceIdentity {
        const self: *CsvSource = @ptrCast(@alignCast(ptr));
        return self.identity_value;
    }

    fn capabilitiesOpaque(ptr: *anyopaque) source_mod.SourceCapabilities {
        const self: *CsvSource = @ptrCast(@alignCast(ptr));
        return .{
            .replayable = true,
            .seekable = false,
            .bounded = true,
            .schema_known = self.schema != null,
        };
    }

    fn bytesReadOpaque(ptr: *anyopaque) u64 {
        const self: *CsvSource = @ptrCast(@alignCast(ptr));
        return self.bytes_consumed;
    }

    fn readRecord(self: *CsvSource) !?[]const u8 {
        self.record_scratch.clearRetainingCapacity();
        var in_quotes = false;
        var have_data = false;
        while (true) {
            const line_start = self.record_scratch.items.len;
            const line_available = try self.readPhysicalLine();
            if (!line_available) return if (have_data) self.record_scratch.items else null;
            have_data = true;
            if (self.record_scratch.getLastOrNull() == '\r') {
                _ = self.record_scratch.pop();
            }
            in_quotes = advanceQuoteState(
                self.record_scratch.items[line_start..],
                self.options.quote,
                in_quotes,
            );
            if (!in_quotes) return self.record_scratch.items;
            if (self.record_scratch.items.len == self.options.max_record_bytes) {
                return error.RecordTooLarge;
            }
            try self.record_scratch.append(self.allocator, '\n');
        }
    }

    fn readPhysicalLine(self: *CsvSource) !bool {
        const before = self.record_scratch.items.len;
        if (before >= self.options.max_record_bytes) return error.RecordTooLarge;

        const written = blk: {
            var writer: std.Io.Writer.Allocating = .fromArrayList(self.allocator, &self.record_scratch);
            defer self.record_scratch = writer.toArrayList();
            break :blk self.stream.interface.streamDelimiterLimit(
                &writer.writer,
                '\n',
                .limited(self.options.max_record_bytes - before),
            ) catch |err| switch (err) {
                error.StreamTooLong => return error.RecordTooLarge,
                else => |other| return other,
            };
        };

        self.content_hasher.update(self.record_scratch.items[before..]);

        if (self.stream.atEnd()) {
            self.bytes_consumed += written;
            self.finalizeContentHash();
            return written != 0;
        }
        const delimiter = try self.stream.interface.peekByte();
        std.debug.assert(delimiter == '\n');
        self.stream.interface.toss(1);
        self.content_hasher.update("\n");
        self.bytes_consumed += written + 1;
        return true;
    }

    fn finalizeContentHash(self: *CsvSource) void {
        if (self.content_hash_finalized) return;
        self.content_hasher.final(&self.identity_value.content_hash);
        self.content_hash_finalized = true;
    }
};

fn parseSchema(
    allocator: std.mem.Allocator,
    record: []const u8,
    options: CsvOptions,
) !schema_mod.Schema {
    var names: std.ArrayList(schema_mod.Field) = .empty;
    errdefer {
        for (names.items) |field| allocator.free(field.name);
        names.deinit(allocator);
    }
    _ = try parseFields(allocator, record, options, null, &names, null);
    for (names.items, 0..) |field, index| {
        for (names.items[0..index]) |previous| {
            if (std.mem.eql(u8, field.name, previous.name)) {
                return error.DuplicateHeaderName;
            }
        }
    }
    const fields = try names.toOwnedSlice(allocator);
    return .{
        .fields = fields,
        .hash = schema_mod.Schema.computeHash(fields),
    };
}

fn parseRow(
    builder: *batch_mod.Builder,
    record: []const u8,
    options: CsvOptions,
    scratch: *std.ArrayList(u8),
    scratch_allocator: std.mem.Allocator,
) !void {
    _ = try parseFields(scratch_allocator, record, options, builder, null, scratch);
}

fn parseFields(
    allocator: std.mem.Allocator,
    record: []const u8,
    options: CsvOptions,
    builder: ?*batch_mod.Builder,
    fields: ?*std.ArrayList(schema_mod.Field),
    scratch: ?*std.ArrayList(u8),
) !usize {
    var local_field: std.ArrayList(u8) = .empty;
    defer if (scratch == null) local_field.deinit(allocator);
    const field = scratch orelse &local_field;
    field.clearRetainingCapacity();
    var quoted = false;
    var started = false;
    var quote_closed = false;
    var index: usize = 0;
    var i: usize = 0;
    while (true) : (i += 1) {
        const at_end = i == record.len;
        const byte = if (at_end) 0 else record[i];
        if (!at_end and byte == options.quote) {
            if (quoted and i + 1 < record.len and record[i + 1] == options.quote) {
                try field.append(allocator, options.quote);
                i += 1;
            } else if (quoted) {
                quoted = false;
                quote_closed = true;
            } else {
                if (field.items.len != 0 or started or quote_closed) {
                    return error.UnexpectedQuote;
                }
                quoted = true;
                started = true;
            }
        } else if (at_end or (!quoted and byte == options.delimiter)) {
            if (builder) |target| {
                if (index >= target.schema.fields.len) {
                    if (options.extra_columns == .fail) return error.ExtraColumns;
                    index += 1;
                    field.clearRetainingCapacity();
                    quoted = false;
                    started = false;
                    quote_closed = false;
                    if (at_end) break;
                    continue;
                }
                const value = if (field.items.len == 0 and !started) null else field.items;
                if (value) |text| {
                    try target.appendString(index, text);
                } else {
                    try target.appendNull(index);
                }
            } else if (fields) |target| {
                if (field.items.len == 0) return error.EmptyHeaderName;
                try target.append(allocator, .{
                    .name = try allocator.dupe(u8, field.items),
                });
            }
            index += 1;
            field.clearRetainingCapacity();
            quoted = false;
            started = false;
            quote_closed = false;
            if (at_end) break;
        } else {
            if (quote_closed) return error.CharactersAfterClosingQuote;
            try field.append(allocator, byte);
        }
    }
    if (quoted) return error.UnterminatedQuotedField;
    return index;
}

fn advanceQuoteState(record: []const u8, quote: u8, initial_state: bool) bool {
    var quoted = initial_state;
    var i: usize = 0;
    while (i < record.len) : (i += 1) if (record[i] == quote) {
        if (quoted and i + 1 < record.len and record[i + 1] == quote) i += 1 else quoted = !quoted;
    };
    return quoted;
}

test "csv reader uses schema and bounded batches" {
    var reader = try CsvSource.init(
        std.testing.io,
        std.testing.allocator,
        "fixtures/sample.csv",
        .{ .batch_size = 2 },
    );
    defer reader.deinit();
    var arena = arena_pool.BatchArena.init(std.testing.allocator);
    defer arena.deinit();
    const source = reader.asSource();
    try std.testing.expect(source.schema() == null);
    try std.testing.expect(source.capabilities().replayable);
    try std.testing.expectEqualStrings("fixtures/sample.csv", source.identity().uri);
    const first = (try source.nextRaw(&arena)).?;
    try std.testing.expectEqual(@as(usize, 2), first.row_count);
    try std.testing.expectEqualStrings("0012", first.column(0).data.string.get(0));
    try std.testing.expect(source.schema() != null);
    try std.testing.expect(source.capabilities().schema_known);
    arena.reset();
    const second = (try source.nextRaw(&arena)).?;
    try std.testing.expectEqual(@as(usize, 1), second.row_count);
}

test "csv reader handles quoted delimiters, escaped quotes, and multiline fields" {
    var reader = try CsvSource.init(
        std.testing.io,
        std.testing.allocator,
        "fixtures/quoted.csv",
        .{ .batch_size = 8 },
    );
    defer reader.deinit();
    var arena = arena_pool.BatchArena.init(std.testing.allocator);
    defer arena.deinit();
    const output_batch = (try reader.asReader().next(&arena)).?;
    try std.testing.expectEqual(@as(usize, 3), output_batch.row_count);
    const descriptions = output_batch.column(1).data.string;
    try std.testing.expectEqualStrings("hello, world", descriptions.get(0));
    try std.testing.expectEqualStrings("line one\nline two", descriptions.get(1));
    try std.testing.expectEqualStrings("escaped \"quote\"", descriptions.get(2));
}

test "csv reader rejects structurally malformed rows" {
    const cases = [_]struct {
        path: []const u8,
        expected: anyerror,
    }{
        .{
            .path = "fixtures/csv/missing_column.csv",
            .expected = error.MissingColumns,
        },
        .{
            .path = "fixtures/csv/extra_column.csv",
            .expected = error.ExtraColumns,
        },
        .{
            .path = "fixtures/csv/unterminated_quote.csv",
            .expected = error.UnterminatedQuotedField,
        },
        .{
            .path = "fixtures/csv/duplicate_header.csv",
            .expected = error.DuplicateHeaderName,
        },
        .{
            .path = "fixtures/csv/characters_after_quote.csv",
            .expected = error.CharactersAfterClosingQuote,
        },
    };

    for (cases) |case| {
        var source = try CsvSource.init(
            std.testing.io,
            std.testing.allocator,
            case.path,
            .{ .missing_columns = .fail },
        );
        defer source.deinit();
        var arena = arena_pool.BatchArena.init(std.testing.allocator);
        defer arena.deinit();
        try std.testing.expectError(case.expected, source.nextRaw(&arena));
    }
}

test "csv reader enforces the configured record limit" {
    var source = try CsvSource.init(
        std.testing.io,
        std.testing.allocator,
        "fixtures/sample.csv",
        .{ .max_record_bytes = 4 },
    );
    defer source.deinit();
    var arena = arena_pool.BatchArena.init(std.testing.allocator);
    defer arena.deinit();

    try std.testing.expectError(error.RecordTooLarge, source.nextRaw(&arena));
}

test "csv reader pads missing columns when configured" {
    var source = try CsvSource.init(
        std.testing.io,
        std.testing.allocator,
        "fixtures/csv/missing_column.csv",
        .{ .missing_columns = .pad_null },
    );
    defer source.deinit();
    var arena = arena_pool.BatchArena.init(std.testing.allocator);
    defer arena.deinit();
    const input = (try source.nextRaw(&arena)).?;
    try std.testing.expect(input.column(input.columns.len - 1).isNull(0));
}

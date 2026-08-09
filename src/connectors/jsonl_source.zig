const std = @import("std");
const arena_pool = @import("../core/arena_pool.zig");
const batch_mod = @import("../core/batch.zig");
const reader_mod = @import("../core/reader.zig");
const schema_mod = @import("../core/schema.zig");
const source_identity = @import("../core/source_identity.zig");
const value_mod = @import("../core/value.zig");
const source_mod = @import("source.zig");

pub const UnknownFieldPolicy = enum { fail, ignore };

pub const JsonlOptions = struct {
    batch_size: usize = 8192,
    max_record_bytes: usize = 16 * 1024 * 1024,
    unknown_fields: UnknownFieldPolicy = .fail,
};

pub const JsonlSource = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    file: std.Io.File,
    stream: std.Io.File.Reader,
    buffer: []u8,
    options: JsonlOptions,
    identity_value: source_identity.SourceIdentity,
    schema_value: ?schema_mod.Schema = null,
    record: std.ArrayList(u8) = .empty,
    parse_arena: std.heap.ArenaAllocator,
    pending_first: ?std.json.Value = null,
    next_batch_id: u64 = 0,
    global_row_offset: u64 = 0,
    bytes_consumed: u64 = 0,
    content_hasher: std.crypto.hash.sha2.Sha256 = .init(.{}),
    content_hash_finalized: bool = false,

    /// Opens a JSON Lines file. Each non-empty line must contain one flat JSON object.
    pub fn init(
        io: std.Io,
        allocator: std.mem.Allocator,
        path: []const u8,
        options: JsonlOptions,
    ) !JsonlSource {
        if (options.batch_size == 0) return error.InvalidBatchSize;
        if (options.max_record_bytes == 0) return error.InvalidRecordLimit;
        const file = try std.Io.Dir.cwd().openFile(io, path, .{});
        errdefer file.close(io);
        const stat = try file.stat(io);
        const uri = try allocator.dupe(u8, path);
        errdefer allocator.free(uri);
        const buffer = try allocator.alloc(u8, 64 * 1024);
        errdefer allocator.free(buffer);
        var self = JsonlSource{
            .io = io,
            .allocator = allocator,
            .file = file,
            .stream = undefined,
            .buffer = buffer,
            .options = options,
            .identity_value = .{
                .id = @as(u128, std.hash.Wyhash.hash(0, path)),
                .version = source_identity.fileVersion(path, stat),
                .uri = uri,
            },
            .parse_arena = .init(allocator),
        };
        self.stream = file.readerStreaming(io, buffer);
        return self;
    }

    pub fn deinit(self: *JsonlSource) void {
        self.parse_arena.deinit();
        self.record.deinit(self.allocator);
        if (self.schema_value) |*schema_value| schema_value.deinit(self.allocator);
        self.allocator.free(self.buffer);
        self.allocator.free(self.identity_value.uri);
        self.file.close(self.io);
    }

    pub fn nextRaw(self: *JsonlSource, output: *arena_pool.BatchArena) !?batch_mod.Batch {
        if (self.schema_value == null) try self.prepareFirst();
        if (self.schema_value == null) return null;
        var builder = try batch_mod.Builder.init(output, &self.schema_value.?);
        while (builder.row_count < self.options.batch_size) {
            const parsed = if (self.pending_first) |first| blk: {
                self.pending_first = null;
                break :blk first;
            } else blk: {
                _ = self.parse_arena.reset(.retain_capacity);
                const line = try self.readNonEmptyLine() orelse break;
                break :blk try self.parse(line);
            };
            try self.appendObject(&builder, parsed);
            try builder.finishRow();
        }
        if (builder.row_count == 0) return null;
        const result = try builder.finish(.{
            .source_id = self.identity_value.id,
            .source_version = self.identity_value.version,
            .batch_id = self.next_batch_id,
            .global_row_offset = self.global_row_offset,
        });
        self.next_batch_id += 1;
        self.global_row_offset += result.row_count;
        return result;
    }

    pub fn asReader(self: *JsonlSource) reader_mod.Reader {
        return .{ .ptr = self, .next_fn = nextOpaque };
    }

    pub fn asSource(self: *JsonlSource) source_mod.Source {
        return .{
            .ptr = self,
            .next_raw_fn = nextOpaque,
            .schema_fn = schemaOpaque,
            .identity_fn = identityOpaque,
            .capabilities_fn = capabilitiesOpaque,
            .bytes_read_fn = bytesReadOpaque,
        };
    }

    fn prepareFirst(self: *JsonlSource) !void {
        _ = self.parse_arena.reset(.retain_capacity);
        const line = try self.readNonEmptyLine() orelse return;
        const parsed = try self.parse(line);
        const object = switch (parsed) {
            .object => |items| items,
            else => return error.JsonlRecordMustBeObject,
        };
        var fields: std.ArrayList(schema_mod.Field) = .empty;
        errdefer {
            for (fields.items) |field| self.allocator.free(field.name);
            fields.deinit(self.allocator);
        }
        var iterator = object.iterator();
        while (iterator.next()) |entry| {
            const tag = try inferTag(entry.value_ptr.*);
            try fields.append(self.allocator, .{
                .name = try self.allocator.dupe(u8, entry.key_ptr.*),
                .tag = tag,
                .nullable = true,
            });
        }
        if (fields.items.len == 0) return error.EmptyJsonObject;
        const owned = try fields.toOwnedSlice(self.allocator);
        self.schema_value = .{ .fields = owned, .hash = schema_mod.Schema.computeHash(owned) };
        self.pending_first = parsed;
    }

    fn parse(self: *JsonlSource, line: []const u8) !std.json.Value {
        const parsed = try std.json.parseFromSlice(
            std.json.Value,
            self.parse_arena.allocator(),
            line,
            .{ .max_value_len = self.options.max_record_bytes },
        );
        return parsed.value;
    }

    fn appendObject(self: *JsonlSource, builder: *batch_mod.Builder, parsed: std.json.Value) !void {
        const object = switch (parsed) {
            .object => |items| items,
            else => return error.JsonlRecordMustBeObject,
        };
        if (self.options.unknown_fields == .fail) {
            var iterator = object.iterator();
            while (iterator.next()) |entry| {
                if (self.schema_value.?.indexOf(entry.key_ptr.*) == null) return error.UnknownJsonField;
            }
        }
        for (self.schema_value.?.fields, 0..) |field, index| {
            const item = object.get(field.name) orelse {
                try builder.appendNull(index);
                continue;
            };
            try appendValue(builder, index, field.tag, item);
        }
    }

    fn readNonEmptyLine(self: *JsonlSource) !?[]const u8 {
        while (true) {
            self.record.clearRetainingCapacity();
            const written = blk: {
                var writer: std.Io.Writer.Allocating = .fromArrayList(self.allocator, &self.record);
                defer self.record = writer.toArrayList();
                break :blk self.stream.interface.streamDelimiterLimit(
                    &writer.writer,
                    '\n',
                    .limited(self.options.max_record_bytes),
                ) catch |err| switch (err) {
                    error.StreamTooLong => return error.RecordTooLarge,
                    else => |other| return other,
                };
            };
            const ended = self.stream.atEnd();
            self.content_hasher.update(self.record.items);
            self.bytes_consumed += written;
            if (!ended) {
                self.stream.interface.toss(1);
                self.content_hasher.update("\n");
                self.bytes_consumed += 1;
            }
            if (ended and written == 0) {
                self.finalizeContentHash();
                return null;
            }
            if (self.record.getLastOrNull() == '\r') _ = self.record.pop();
            if (std.mem.trim(u8, self.record.items, " \t").len != 0) return self.record.items;
        }
    }

    fn finalizeContentHash(self: *JsonlSource) void {
        if (self.content_hash_finalized) return;
        self.content_hasher.final(&self.identity_value.content_hash);
        self.content_hash_finalized = true;
    }

    fn nextOpaque(ptr: *anyopaque, output: *arena_pool.BatchArena) anyerror!?batch_mod.Batch {
        return (@as(*JsonlSource, @ptrCast(@alignCast(ptr)))).nextRaw(output);
    }
    fn schemaOpaque(ptr: *anyopaque) ?*const schema_mod.Schema {
        const self: *JsonlSource = @ptrCast(@alignCast(ptr));
        return if (self.schema_value) |*value| value else null;
    }
    fn identityOpaque(ptr: *anyopaque) source_identity.SourceIdentity {
        return (@as(*JsonlSource, @ptrCast(@alignCast(ptr)))).identity_value;
    }
    fn capabilitiesOpaque(ptr: *anyopaque) source_mod.SourceCapabilities {
        const self: *JsonlSource = @ptrCast(@alignCast(ptr));
        return .{ .replayable = true, .seekable = false, .bounded = true, .schema_known = self.schema_value != null };
    }
    fn bytesReadOpaque(ptr: *anyopaque) u64 {
        return (@as(*JsonlSource, @ptrCast(@alignCast(ptr)))).bytes_consumed;
    }
};

fn inferTag(value: std.json.Value) !value_mod.ValueTag {
    return switch (value) {
        .integer => .i64,
        .float => .f64,
        .bool => .boolean,
        .string, .null => .string,
        .number_string => |text| if (std.mem.indexOfAny(u8, text, ".eE") == null) .i64 else .f64,
        .array, .object => error.NestedJsonValueUnsupported,
    };
}

fn appendValue(builder: *batch_mod.Builder, index: usize, tag: value_mod.ValueTag, value: std.json.Value) !void {
    if (value == .null) return builder.appendNull(index);
    switch (tag) {
        .i64 => switch (value) {
            .integer => |item| try builder.appendI64(index, item),
            .number_string => |text| try builder.appendI64(index, try std.fmt.parseInt(i64, text, 10)),
            else => return error.JsonTypeMismatch,
        },
        .f64 => switch (value) {
            .integer => |item| try builder.appendF64(index, @floatFromInt(item)),
            .float => |item| try builder.appendF64(index, item),
            .number_string => |text| try builder.appendF64(index, try std.fmt.parseFloat(f64, text)),
            else => return error.JsonTypeMismatch,
        },
        .boolean => switch (value) {
            .bool => |item| try builder.appendBoolean(index, item),
            else => return error.JsonTypeMismatch,
        },
        .string => switch (value) {
            .string => |item| try builder.appendString(index, item),
            else => return error.JsonTypeMismatch,
        },
        .decimal, .date, .datetime => return error.JsonSchemaTypeUnsupported,
    }
}

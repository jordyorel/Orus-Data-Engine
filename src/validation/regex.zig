const std = @import("std");
const c = @cImport({
    @cInclude("regex.h");
});

pub const max_pattern_bytes = 1024;
pub const max_input_bytes = 1024 * 1024;

pub const Regex = struct {
    compiled: c.regex_t,

    pub fn init(allocator: std.mem.Allocator, pattern: []const u8) !Regex {
        if (pattern.len == 0) return error.EmptyRegex;
        if (pattern.len > max_pattern_bytes) return error.RegexTooLarge;
        const terminated = try allocator.dupeZ(u8, pattern);
        defer allocator.free(terminated);
        var result: Regex = undefined;
        if (c.regcomp(&result.compiled, terminated.ptr, c.REG_EXTENDED) != 0) {
            return error.InvalidRegex;
        }
        return result;
    }

    pub fn deinit(self: *Regex) void {
        c.regfree(&self.compiled);
    }

    pub fn matches(self: *const Regex, text: []const u8) bool {
        if (text.len > max_input_bytes) return false;
        var bounds = c.regmatch_t{ .rm_so = 0, .rm_eo = @intCast(text.len) };
        return c.regexec(&self.compiled, text.ptr, 1, &bounds, c.REG_STARTEND) == 0;
    }
};

test "POSIX ERE is compiled once and matches bounded input" {
    var expression = try Regex.init(std.testing.allocator, "^[A-Z]{2}-[0-9]{4}$");
    defer expression.deinit();
    try std.testing.expect(expression.matches("CG-2026"));
    try std.testing.expect(!expression.matches("cg-2026"));
    try std.testing.expectError(error.InvalidRegex, Regex.init(std.testing.allocator, "["));
}

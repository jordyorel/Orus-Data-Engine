const std = @import("std");

pub const PatternTag = enum {
    email,
    phone_e164,
    date_iso,
    uuid,
    url,
};

pub fn matches(tag: PatternTag, text: []const u8) bool {
    return switch (tag) {
        .email => isEmail(text),
        .phone_e164 => isPhoneE164(text),
        .date_iso => isDateIso(text),
        .uuid => isUuid(text),
        .url => isUrl(text),
    };
}

pub const Detector = struct {
    pub const sample_limit: usize = 4096;
    counts: [5]u32 = @splat(0),
    sampled: u32 = 0,

    pub fn update(self: *Detector, text: []const u8) void {
        if (self.sampled == sample_limit) return;
        self.sampled += 1;
        if (isEmail(text)) self.counts[@intFromEnum(PatternTag.email)] += 1;
        if (isPhoneE164(text)) self.counts[@intFromEnum(PatternTag.phone_e164)] += 1;
        if (isDateIso(text)) self.counts[@intFromEnum(PatternTag.date_iso)] += 1;
        if (isUuid(text)) self.counts[@intFromEnum(PatternTag.uuid)] += 1;
        if (isUrl(text)) self.counts[@intFromEnum(PatternTag.url)] += 1;
    }

    pub fn detected(self: Detector) ?PatternTag {
        if (self.sampled == 0) return null;
        var best: u32 = 0;
        var tag: ?PatternTag = null;
        for (self.counts, 0..) |count, index| if (count > best) {
            best = count;
            tag = @enumFromInt(index);
        };
        return if (best * 10 >= self.sampled * 9) tag else null;
    }
};

fn isEmail(text: []const u8) bool {
    const at = std.mem.indexOfScalar(u8, text, '@') orelse return false;
    return at > 0 and at + 1 < text.len and std.mem.indexOfScalar(u8, text[at + 1 ..], '.') != null;
}

fn isPhoneE164(text: []const u8) bool {
    if (text.len < 8 or text.len > 16 or text[0] != '+') return false;
    for (text[1..]) |byte| if (!std.ascii.isDigit(byte)) return false;
    return true;
}

fn isDateIso(text: []const u8) bool {
    if (text.len != 10 or text[4] != '-' or text[7] != '-') return false;
    for (text, 0..) |byte, index| if (index != 4 and index != 7 and !std.ascii.isDigit(byte)) return false;
    return true;
}

fn isUuid(text: []const u8) bool {
    if (text.len != 36) return false;
    for (text, 0..) |byte, index| {
        if (index == 8 or index == 13 or index == 18 or index == 23) {
            if (byte != '-') return false;
        } else if (!std.ascii.isHex(byte)) return false;
    }
    return true;
}

fn isUrl(text: []const u8) bool {
    return std.mem.startsWith(u8, text, "https://") or std.mem.startsWith(u8, text, "http://");
}

test "pattern detector requires ninety percent agreement" {
    var detector = Detector{};
    detector.update("a@example.com");
    detector.update("b@example.com");
    try std.testing.expectEqual(PatternTag.email, detector.detected().?);
}

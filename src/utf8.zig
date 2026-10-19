//! UTF-8 helpers with Rust `str` semantics, so that checks agree with
//! yorc-rs: validation that reports how many bytes were valid
//! (`valid_up_to`), code point iteration, `chars().count()`, `char::is_whitespace`
//! trimming, and the XML 1.0 character rule the writers enforce.
const std = @import("std");

/// Index of the first byte that does not start a valid UTF-8 sequence, or
/// null if all of `s` is valid (no overlongs, no surrogates, at most U+10FFFF).
pub fn invalidIndex(s: []const u8) ?usize {
    var i: usize = 0;
    while (i < s.len) {
        const n = seqLen(s, i) orelse return i;
        i += n;
    }
    return null;
}

pub fn isValid(s: []const u8) bool {
    return invalidIndex(s) == null;
}

/// Length of the valid sequence starting at `s[i]`, or null if invalid.
fn seqLen(s: []const u8, i: usize) ?usize {
    const b0 = s[i];
    if (b0 < 0x80) return 1;
    const rest = s.len - i;
    if (b0 >= 0xC2 and b0 <= 0xDF) {
        if (rest < 2 or !cont(s[i + 1])) return null;
        return 2;
    }
    if (b0 >= 0xE0 and b0 <= 0xEF) {
        if (rest < 3) return null;
        const b1 = s[i + 1];
        const lo: u8 = if (b0 == 0xE0) 0xA0 else 0x80;
        const hi: u8 = if (b0 == 0xED) 0x9F else 0xBF;
        if (b1 < lo or b1 > hi or !cont(s[i + 2])) return null;
        return 3;
    }
    if (b0 >= 0xF0 and b0 <= 0xF4) {
        if (rest < 4) return null;
        const b1 = s[i + 1];
        const lo: u8 = if (b0 == 0xF0) 0x90 else 0x80;
        const hi: u8 = if (b0 == 0xF4) 0x8F else 0xBF;
        if (b1 < lo or b1 > hi or !cont(s[i + 2]) or !cont(s[i + 3])) return null;
        return 4;
    }
    return null;
}

fn cont(b: u8) bool {
    return b & 0xC0 == 0x80;
}

/// Decodes the code point at `s[i]`; null if the sequence is invalid.
pub fn decodeAt(s: []const u8, i: usize) ?struct { cp: u21, len: usize } {
    const n = seqLen(s, i) orelse return null;
    const b = s[i..][0..n];
    const cp: u21 = switch (n) {
        1 => b[0],
        2 => (@as(u21, b[0] & 0x1F) << 6) | (b[1] & 0x3F),
        3 => (@as(u21, b[0] & 0x0F) << 12) | (@as(u21, b[1] & 0x3F) << 6) | (b[2] & 0x3F),
        else => (@as(u21, b[0] & 0x07) << 18) | (@as(u21, b[1] & 0x3F) << 12) |
            (@as(u21, b[2] & 0x3F) << 6) | (b[3] & 0x3F),
    };
    return .{ .cp = cp, .len = n };
}

/// Iterates code points; `next` returns error.InvalidUtf8 on a bad sequence.
pub const Iterator = struct {
    s: []const u8,
    i: usize = 0,

    pub fn next(it: *Iterator) error{InvalidUtf8}!?u21 {
        if (it.i >= it.s.len) return null;
        const d = decodeAt(it.s, it.i) orelse return error.InvalidUtf8;
        it.i += d.len;
        return d.cp;
    }
};

/// Number of code points (Rust `chars().count()`); invalid bytes count as
/// one each.
pub fn count(s: []const u8) usize {
    var n: usize = 0;
    var i: usize = 0;
    while (i < s.len) {
        i += seqLen(s, i) orelse 1;
        n += 1;
    }
    return n;
}

/// The XML 1.0 `Char` rule as yorc-rs applies it: TAB, LF, CR, and
/// everything from U+0020 except U+FFFE and U+FFFF (surrogates cannot occur
/// in valid UTF-8).
pub fn isXmlChar(cp: u21) bool {
    return cp == '\t' or cp == '\n' or cp == '\r' or (cp >= 0x20 and cp != 0xFFFE and cp != 0xFFFF);
}

/// The first code point XML 1.0 cannot carry, or 0xFFFD for invalid UTF-8;
/// null if `s` is fine.
pub fn firstNonXmlChar(s: []const u8) ?u21 {
    var it: Iterator = .{ .s = s };
    while (true) {
        const cp = (it.next() catch return 0xFFFD) orelse return null;
        if (!isXmlChar(cp)) return cp;
    }
}

/// Rust `char::is_whitespace` (Unicode White_Space).
pub fn isUnicodeSpace(cp: u21) bool {
    return switch (cp) {
        0x09...0x0D, 0x20, 0x85, 0xA0, 0x1680, 0x2000...0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000 => true,
        else => false,
    };
}

/// Rust `str::trim`: strips Unicode White_Space at both ends. Invalid bytes
/// are never stripped.
pub fn trimUnicode(s: []const u8) []const u8 {
    var start: usize = 0;
    while (start < s.len) {
        const d = decodeAt(s, start) orelse break;
        if (!isUnicodeSpace(d.cp)) break;
        start += d.len;
    }
    var end: usize = s.len;
    while (end > start) {
        // find the start of the last sequence
        var j = end - 1;
        while (j > start and cont(s[j])) j -= 1;
        const d = decodeAt(s, j) orelse break;
        if (j + d.len != end or !isUnicodeSpace(d.cp)) break;
        end = j;
    }
    return s[start..end];
}

/// Appends the UTF-8 encoding of `cp` (a Unicode scalar value).
pub fn appendCodepoint(list: *std.ArrayList(u8), gpa: std.mem.Allocator, cp: u21) error{OutOfMemory}!void {
    var buf: [4]u8 = undefined;
    const n: usize = if (cp < 0x80) 1 else if (cp < 0x800) 2 else if (cp < 0x10000) 3 else 4;
    switch (n) {
        1 => buf[0] = @intCast(cp),
        2 => {
            buf[0] = @intCast(0xC0 | (cp >> 6));
            buf[1] = @intCast(0x80 | (cp & 0x3F));
        },
        3 => {
            buf[0] = @intCast(0xE0 | (cp >> 12));
            buf[1] = @intCast(0x80 | ((cp >> 6) & 0x3F));
            buf[2] = @intCast(0x80 | (cp & 0x3F));
        },
        else => {
            buf[0] = @intCast(0xF0 | (cp >> 18));
            buf[1] = @intCast(0x80 | ((cp >> 12) & 0x3F));
            buf[2] = @intCast(0x80 | ((cp >> 6) & 0x3F));
            buf[3] = @intCast(0x80 | (cp & 0x3F));
        },
    }
    try list.appendSlice(gpa, buf[0..n]);
}

test "validation reports the valid prefix" {
    try std.testing.expectEqual(@as(?usize, null), invalidIndex("plain é ü 😀"));
    try std.testing.expectEqual(@as(?usize, 3), invalidIndex("<a>\xff</a>"));
    try std.testing.expectEqual(@as(?usize, 0), invalidIndex("\xed\xa0\x80")); // surrogate
    try std.testing.expectEqual(@as(?usize, 0), invalidIndex("\xc0\xaf")); // overlong
    try std.testing.expectEqual(@as(?usize, 1), invalidIndex("a\xe2\x82"));
}

test "count, trim and XML chars" {
    try std.testing.expectEqual(@as(usize, 3), count("aéb"));
    try std.testing.expectEqualStrings("x y", trimUnicode("\u{3000} x y\u{a0}\n"));
    try std.testing.expectEqual(@as(?u21, 7), firstNonXmlChar("bell\x07"));
    try std.testing.expectEqual(@as(?u21, null), firstNonXmlChar("tab\tok"));
    try std.testing.expectEqual(@as(?u21, 0xFFFE), firstNonXmlChar("\u{fffe}"));
}

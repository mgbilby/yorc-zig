//! ORCID iDs: normalisation, ISO 7064 MOD 11-2 check character, `OrcidId`.
//!
//! The rules are those of yorc-duckdb's `orcid_normalize` and yorc-rs's
//! `id` module, byte for byte: leading ASCII whitespace (C `isspace`) is
//! skipped; one of the prefixes `https://orcid.org/`, `http://orcid.org/` or
//! `orcid.org/` (case-sensitive) is stripped; then hyphens and ASCII
//! whitespace are ignored anywhere; the remaining bytes are upper-cased and
//! must be exactly 16: 15 digits plus a check character (a digit or `X`).
const std = @import("std");

const prefixes = [_][]const u8{ "https://orcid.org/", "http://orcid.org/", "orcid.org/" };

/// C `isspace` in the "C" locale.
fn isCSpace(c: u8) bool {
    return switch (c) {
        ' ', '\t', '\n', 0x0b, 0x0c, '\r' => true,
        else => false,
    };
}

/// ISO 7064 MOD 11-2 check character for the first 15 digits, or null if
/// `digits` is not exactly 15 ASCII digits.
pub fn checkChar(digits: []const u8) ?u8 {
    if (digits.len != 15) return null;
    var total: u32 = 0;
    for (digits) |c| {
        if (c < '0' or c > '9') return null;
        total = (total + (c - '0')) * 2;
    }
    const digit: u8 = @intCast((12 - total % 11) % 11);
    return if (digit == 10) 'X' else '0' + digit;
}

/// Canonical `XXXX-XXXX-XXXX-XXXX` text of an iD (19 bytes).
pub const Canonical = [19]u8;

/// Normalises `input` into canonical form, or returns null if it is not a
/// valid iD. No allocation.
pub fn normalize(input: []const u8) ?Canonical {
    var pos: usize = 0;
    while (pos < input.len and isCSpace(input[pos])) pos += 1;
    for (prefixes) |p| {
        if (std.mem.startsWith(u8, input[pos..], p)) {
            pos += p.len;
            break;
        }
    }
    var chars: [16]u8 = undefined;
    var n: usize = 0;
    for (input[pos..]) |c| {
        if (c == '-' or isCSpace(c)) continue;
        if (n == 16) return null;
        chars[n] = std.ascii.toUpper(c);
        n += 1;
    }
    if (n != 16) return null;
    const want = checkChar(chars[0..15]) orelse return null;
    if (want != chars[15]) return null;

    var out: Canonical = undefined;
    var o: usize = 0;
    for (chars, 0..) |c, i| {
        if (i > 0 and i % 4 == 0) {
            out[o] = '-';
            o += 1;
        }
        out[o] = c;
        o += 1;
    }
    return out;
}

/// True if `normalize` accepts the input.
pub fn isValid(input: []const u8) bool {
    return normalize(input) != null;
}

pub const ParseError = error{InvalidOrcidId};

/// A valid ORCID iD in canonical `XXXX-XXXX-XXXX-XXXX` form. A value type:
/// no allocation, copyable.
pub const OrcidId = struct {
    text: Canonical,

    /// Accepts every form `normalize` accepts (URL prefixes, missing
    /// hyphens, lowercase `x`, surrounding whitespace).
    pub fn parse(input: []const u8) ParseError!OrcidId {
        return .{ .text = normalize(input) orelse return error.InvalidOrcidId };
    }

    /// Canonical `XXXX-XXXX-XXXX-XXXX`.
    pub fn slice(self: *const OrcidId) []const u8 {
        return &self.text;
    }

    pub fn eql(a: OrcidId, b: OrcidId) bool {
        return std.mem.eql(u8, &a.text, &b.text);
    }

    pub const uri_prefix = "https://orcid.org/";

    /// `https://orcid.org/XXXX-XXXX-XXXX-XXXX` (37 bytes).
    pub fn uri(self: OrcidId) [uri_prefix.len + 19]u8 {
        var out: [uri_prefix.len + 19]u8 = undefined;
        @memcpy(out[0..uri_prefix.len], uri_prefix);
        @memcpy(out[uri_prefix.len..], &self.text);
        return out;
    }

    /// `{f}` prints the canonical form.
    pub fn format(self: OrcidId, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.writeAll(&self.text);
    }
};

// ------------------------------------------------------------------ tests
// The cases of yorc-rs's `id` module and yorc-duckdb/test/sql/orcid.test.

const testing = std.testing;

fn expectNorm(want: ?[]const u8, input: []const u8) !void {
    const got = normalize(input);
    if (want) |w| {
        try testing.expect(got != null);
        try testing.expectEqualStrings(w, &got.?);
    } else {
        try testing.expect(got == null);
    }
}

test "valid ids" {
    for ([_][]const u8{
        "0000-0003-0100-6634",
        "0000-0002-1694-233X",
        "0000-0002-1825-0097",
        "0000-0001-5109-3700",
    }) |id| try expectNorm(id, id);
}

test "invalid checksum" {
    try expectNorm(null, "0000-0003-0100-6635");
    try testing.expect(!isValid("0000-0002-1825-0098"));
}

test "extension test vectors" {
    try testing.expect(isValid("0000-0003-0100-6634"));
    try testing.expect(!isValid("0000-0003-0100-6635"));
    try expectNorm("0000-0002-1694-233X", "https://orcid.org/000000021694233x");
}

test "prefixes and whitespace" {
    const want = "0000-0002-1825-0097";
    try expectNorm(want, "http://orcid.org/0000-0002-1825-0097");
    try expectNorm(want, "orcid.org/0000000218250097");
    try expectNorm(want, "  0000 0002 1825 0097\n");
    try expectNorm(want, "\t0000-0002-1825-0097");
    // prefixes are case-sensitive, as in the extension
    try expectNorm(null, "HTTPS://ORCID.ORG/0000-0002-1825-0097");
    // a prefix is only stripped at the start
    try expectNorm(null, "x https://orcid.org/0000-0002-1825-0097");
}

test "wrong lengths and characters" {
    try expectNorm(null, "");
    try expectNorm(null, "0000-0002-1825-009");
    try expectNorm(null, "0000-0002-1825-00971");
    try expectNorm(null, "X000-0002-1825-0097");
    try expectNorm(null, "0000-0002-1825-009\u{e9}");
    try expectNorm(null, "https://orcid.org/");
}

test "OrcidId value type" {
    const id = try OrcidId.parse("https://orcid.org/000000021694233x");
    try testing.expectEqualStrings("0000-0002-1694-233X", id.slice());
    const u = id.uri();
    try testing.expectEqualStrings("https://orcid.org/0000-0002-1694-233X", &u);
    try testing.expectError(error.InvalidOrcidId, OrcidId.parse("0000-0003-0100-6635"));
    var buf: [32]u8 = undefined;
    const printed = try std.fmt.bufPrint(&buf, "{f}", .{id});
    try testing.expectEqualStrings("0000-0002-1694-233X", printed);
    try testing.expect(id.eql(try OrcidId.parse("0000-0002-1694-233x")));
}

test "check character vectors" {
    try testing.expectEqual(@as(?u8, 'X'), checkChar("000000021694233"));
    try testing.expectEqual(@as(?u8, '4'), checkChar("000000030100663"));
    try testing.expectEqual(@as(?u8, null), checkChar("00000003010066"));
}

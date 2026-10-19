//! A small, allocation-free XML 1.0 pull scanner over a complete input slice.
//!
//! It yields start tags (qualified name, raw attribute region, self-closing
//! flag), end tags, text and CDATA; comments, processing instructions (and
//! the XML declaration) and DOCTYPE declarations (including an internal
//! subset) are skipped. Text and attribute values are returned raw:
//! `decodeText` / `decodeAttribute` expand the five predefined entities and
//! numeric character references and keep anything else literally (the rule
//! yorc-rs inherits from quick-xml with `allow_dangling_amp`).
//!
//! Well-formedness checks are the reader's business (tag balance, names);
//! the scanner reports unterminated constructs and malformed tags or
//! attributes as `error.MalformedXml`, with `pos` at the offending byte.
const std = @import("std");
const utf8 = @import("utf8.zig");

pub const Error = error{MalformedXml};

pub const Token = union(enum) {
    start: Start,
    /// Qualified name of an end tag.
    end: []const u8,
    /// Raw character data (may contain references).
    text: []const u8,
    /// CDATA section content (literal).
    cdata: []const u8,
    eof,
};

pub const Start = struct {
    /// Qualified name, e.g. `work:title`.
    name: []const u8,
    /// Raw attribute region (between the name and `>` or `/>`).
    attrs: []const u8,
    /// `<x/>`.
    empty: bool,

    pub fn attributes(s: Start) AttributeIterator {
        return .{ .s = s.attrs };
    }
};

pub const Attribute = struct {
    /// Qualified name, e.g. `xmlns:work`, `put-code`.
    name: []const u8,
    /// Raw value between the quotes.
    raw_value: []const u8,
};

pub const AttributeIterator = struct {
    s: []const u8,
    i: usize = 0,

    pub fn next(it: *AttributeIterator) Error!?Attribute {
        const s = it.s;
        while (it.i < s.len and isSpace(s[it.i])) it.i += 1;
        if (it.i >= s.len) return null;
        const name_start = it.i;
        while (it.i < s.len and !isSpace(s[it.i]) and s[it.i] != '=') it.i += 1;
        if (it.i == name_start) return error.MalformedXml;
        const name = s[name_start..it.i];
        while (it.i < s.len and isSpace(s[it.i])) it.i += 1;
        if (it.i >= s.len or s[it.i] != '=') return error.MalformedXml;
        it.i += 1;
        while (it.i < s.len and isSpace(s[it.i])) it.i += 1;
        if (it.i >= s.len) return error.MalformedXml;
        const q = s[it.i];
        if (q != '"' and q != '\'') return error.MalformedXml;
        it.i += 1;
        const v_start = it.i;
        const close = std.mem.indexOfScalarPos(u8, s, v_start, q) orelse return error.MalformedXml;
        it.i = close + 1;
        // attributes must be separated by whitespace
        if (it.i < s.len and !isSpace(s[it.i])) return error.MalformedXml;
        return .{ .name = name, .raw_value = s[v_start..close] };
    }
};

pub fn isSpace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r';
}

/// Local part of a qualified name: everything after the first `:`.
pub fn localName(qname: []const u8) []const u8 {
    return if (std.mem.indexOfScalar(u8, qname, ':')) |i| qname[i + 1 ..] else qname;
}

/// Prefix of a qualified name (empty if none).
pub fn prefixOf(qname: []const u8) []const u8 {
    return if (std.mem.indexOfScalar(u8, qname, ':')) |i| qname[0..i] else "";
}

pub const Scanner = struct {
    input: []const u8,
    /// Byte offset of the next token; on error, where scanning stopped.
    pos: usize = 0,

    pub fn init(input: []const u8) Scanner {
        return .{ .input = input };
    }

    pub fn next(sc: *Scanner) Error!Token {
        const in = sc.input;
        while (true) {
            if (sc.pos >= in.len) return .eof;
            if (in[sc.pos] != '<') {
                const start = sc.pos;
                const end = std.mem.indexOfScalarPos(u8, in, start, '<') orelse in.len;
                sc.pos = end;
                return .{ .text = in[start..end] };
            }
            const rest = in[sc.pos..];
            if (std.mem.startsWith(u8, rest, "<?")) {
                const e = std.mem.indexOfPos(u8, in, sc.pos + 2, "?>") orelse return error.MalformedXml;
                sc.pos = e + 2;
                continue;
            }
            if (std.mem.startsWith(u8, rest, "<!--")) {
                const e = std.mem.indexOfPos(u8, in, sc.pos + 4, "-->") orelse return error.MalformedXml;
                sc.pos = e + 3;
                continue;
            }
            if (std.mem.startsWith(u8, rest, "<![CDATA[")) {
                const start = sc.pos + 9;
                const e = std.mem.indexOfPos(u8, in, start, "]]>") orelse return error.MalformedXml;
                sc.pos = e + 3;
                return .{ .cdata = in[start..e] };
            }
            if (std.mem.startsWith(u8, rest, "<!")) {
                try sc.skipDeclaration();
                continue;
            }
            if (std.mem.startsWith(u8, rest, "</")) {
                var i = sc.pos + 2;
                const name_start = i;
                while (i < in.len and !isSpace(in[i]) and in[i] != '>') i += 1;
                if (i == name_start) return error.MalformedXml;
                const name = in[name_start..i];
                while (i < in.len and isSpace(in[i])) i += 1;
                if (i >= in.len or in[i] != '>') {
                    sc.pos = i;
                    return error.MalformedXml;
                }
                sc.pos = i + 1;
                return .{ .end = name };
            }
            // start tag
            var i = sc.pos + 1;
            const name_start = i;
            while (i < in.len and !isSpace(in[i]) and in[i] != '/' and in[i] != '>' and in[i] != '<') i += 1;
            if (i == name_start) return error.MalformedXml;
            const name = in[name_start..i];
            const attrs_start = i;
            var quote: u8 = 0;
            while (i < in.len) : (i += 1) {
                const c = in[i];
                if (quote != 0) {
                    if (c == quote) quote = 0;
                } else if (c == '"' or c == '\'') {
                    quote = c;
                } else if (c == '>') {
                    break;
                } else if (c == '<') {
                    sc.pos = i;
                    return error.MalformedXml;
                }
            }
            if (i >= in.len) return error.MalformedXml;
            var attrs_end = i;
            var empty = false;
            if (attrs_end > attrs_start and in[attrs_end - 1] == '/') {
                empty = true;
                attrs_end -= 1;
            }
            sc.pos = i + 1;
            return .{ .start = .{ .name = name, .attrs = in[attrs_start..attrs_end], .empty = empty } };
        }
    }

    /// `<!DOCTYPE ...>` (or any other `<!` declaration), with quoted strings
    /// and a bracketed internal subset.
    fn skipDeclaration(sc: *Scanner) Error!void {
        const in = sc.input;
        var i = sc.pos + 2;
        var depth: usize = 0;
        var quote: u8 = 0;
        while (i < in.len) : (i += 1) {
            const c = in[i];
            if (quote != 0) {
                if (c == quote) quote = 0;
                continue;
            }
            switch (c) {
                '"', '\'' => quote = c,
                '[' => depth += 1,
                ']' => depth -|= 1,
                '>' => if (depth == 0) {
                    sc.pos = i + 1;
                    return;
                },
                else => {},
            }
        }
        return error.MalformedXml;
    }
};

// ------------------------------------------------------------- references

/// Appends `raw` text with references expanded. A reference is `&name;`
/// where `;` is the next semicolon of the run (any distance).
pub fn decodeText(out: *std.ArrayList(u8), gpa: std.mem.Allocator, raw: []const u8) error{OutOfMemory}!void {
    return decode(out, gpa, raw, std.math.maxInt(usize));
}

/// Appends an attribute value with references expanded; as yorc-rs, a
/// reference name is at most 11 bytes (`&` followed by a `;` further away is
/// kept literally).
pub fn decodeAttribute(out: *std.ArrayList(u8), gpa: std.mem.Allocator, raw: []const u8) error{OutOfMemory}!void {
    return decode(out, gpa, raw, 11);
}

fn decode(out: *std.ArrayList(u8), gpa: std.mem.Allocator, raw: []const u8, max_name: usize) error{OutOfMemory}!void {
    var rest = raw;
    while (std.mem.indexOfScalar(u8, rest, '&')) |amp| {
        try out.appendSlice(gpa, rest[0..amp]);
        const after = rest[amp + 1 ..];
        // Look for the `;` no further than a name may reach: searching the
        // whole rest for every `&` would be quadratic in a run of `&`.
        const window = after[0..@min(after.len, max_name +| 1)];
        if (std.mem.indexOfScalar(u8, window, ';')) |semi| {
            try pushEntity(out, gpa, after[0..semi]);
            rest = after[semi + 1 ..];
            continue;
        }
        try out.append(gpa, '&');
        if (window.len == after.len) {
            // no `;` anywhere after this `&`: the rest is literal text
            try out.appendSlice(gpa, after);
            return;
        }
        rest = after;
    }
    try out.appendSlice(gpa, rest);
}

/// The expansion of `&name;` (unknown names and invalid code points are kept
/// literally).
fn pushEntity(out: *std.ArrayList(u8), gpa: std.mem.Allocator, name: []const u8) error{OutOfMemory}!void {
    const predefined = [_]struct { []const u8, u8 }{
        .{ "amp", '&' }, .{ "lt", '<' }, .{ "gt", '>' }, .{ "quot", '"' }, .{ "apos", '\'' },
    };
    for (predefined) |p| {
        if (std.mem.eql(u8, name, p[0])) return out.append(gpa, p[1]);
    }
    const code: ?u32 = if (std.mem.startsWith(u8, name, "#x") or std.mem.startsWith(u8, name, "#X"))
        parseU32(name[2..], 16)
    else if (std.mem.startsWith(u8, name, "#"))
        parseU32(name[1..], 10)
    else
        null;
    if (code) |c| {
        if (c <= 0x10FFFF and !(c >= 0xD800 and c <= 0xDFFF)) {
            return utf8.appendCodepoint(out, gpa, @intCast(c));
        }
    }
    try out.append(gpa, '&');
    try out.appendSlice(gpa, name);
    try out.append(gpa, ';');
}

/// Rust `u32::from_str_radix`: an optional `+`, then at least one digit.
fn parseU32(s: []const u8, radix: u8) ?u32 {
    var t = s;
    if (t.len > 0 and t[0] == '+') t = t[1..];
    if (t.len == 0) return null;
    var v: u64 = 0;
    for (t) |c| {
        const d: u8 = switch (c) {
            '0'...'9' => c - '0',
            'a'...'f' => c - 'a' + 10,
            'A'...'F' => c - 'A' + 10,
            else => return null,
        };
        if (d >= radix) return null;
        v = v * radix + d;
        if (v > std.math.maxInt(u32)) return null;
    }
    return @intCast(v);
}

// ------------------------------------------------------------------ tests

test "tokens" {
    var sc: Scanner = .init("<?xml version=\"1.0\"?><!DOCTYPE x [<!ENTITY a 'b>'>]><!-- c --><r a='1' b=\"x>y\"><e/>t<![CDATA[<raw>]]></r >");
    try std.testing.expectEqualStrings("r", (try sc.next()).start.name);
    const e = (try sc.next()).start;
    try std.testing.expect(e.empty);
    try std.testing.expectEqualStrings("e", e.name);
    try std.testing.expectEqualStrings("t", (try sc.next()).text);
    try std.testing.expectEqualStrings("<raw>", (try sc.next()).cdata);
    try std.testing.expectEqualStrings("r", (try sc.next()).end);
    try std.testing.expect((try sc.next()) == .eof);
}

test "attributes" {
    var sc: Scanner = .init("<r a = '1' b=\"x>y\" xmlns:p=\"u\"/>");
    const s = (try sc.next()).start;
    var it = s.attributes();
    const a = (try it.next()).?;
    try std.testing.expectEqualStrings("a", a.name);
    try std.testing.expectEqualStrings("1", a.raw_value);
    try std.testing.expectEqualStrings("x>y", (try it.next()).?.raw_value);
    try std.testing.expectEqualStrings("xmlns:p", (try it.next()).?.name);
    try std.testing.expect((try it.next()) == null);
    var bad = (Start{ .name = "r", .attrs = " a", .empty = false }).attributes();
    try std.testing.expectError(error.MalformedXml, bad.next());
}

test "references" {
    const gpa = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try decodeText(&out, gpa, "Fish &amp; Chips &#x2014; &#233;t&#xE9; &lt;3 &foo; & x");
    try std.testing.expectEqualStrings("Fish & Chips \u{2014} \u{e9}t\u{e9} <3 &foo; & x", out.items);
    out.clearRetainingCapacity();
    try decodeText(&out, gpa, "&#xD800;&#+65;&#x110000;");
    try std.testing.expectEqualStrings("&#xD800;A&#x110000;", out.items);
}

test "references: a run of & is linear" {
    const gpa = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    const amps = try gpa.alloc(u8, 1 << 20);
    defer gpa.free(amps);
    @memset(amps, '&');
    // text: no `;` at all
    try decodeText(&out, gpa, amps);
    try std.testing.expectEqualSlices(u8, amps, out.items);
    // attribute: a `;` at the very end, beyond every name's reach but the last
    out.clearRetainingCapacity();
    const attr = try std.mem.concat(gpa, u8, &.{ amps, ";" });
    defer gpa.free(attr);
    try decodeAttribute(&out, gpa, attr);
    try std.testing.expectEqualSlices(u8, attr, out.items);
    // the same expansions as before
    out.clearRetainingCapacity();
    try decodeAttribute(&out, gpa, "a &amp; b &#x41; &toolongtobeanentity; &");
    try std.testing.expectEqualStrings("a & b A &toolongtobeanentity; &", out.items);
    out.clearRetainingCapacity();
    try decodeText(&out, gpa, "x &amp; y & z");
    try std.testing.expectEqualStrings("x & y & z", out.items);
}

test "unterminated constructs" {
    for ([_][]const u8{ "<!-- x", "<a", "<![CDATA[x", "<?pi", "</a", "<a b='1>" }) |s| {
        var sc: Scanner = .init(s);
        try std.testing.expectError(error.MalformedXml, sc.next());
    }
}

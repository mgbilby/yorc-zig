//! ORCID's JSON form (`application/vnd.orcid+json`), read into and written
//! from the same model as the XML, with the shape rules of yorc-rs's
//! `json` module:
//! * kebab-case keys (the XML element names without prefixes); attributes
//!   are ordinary keys (`put-code`, `path`, `visibility`, `display-index`, ...);
//! * many text values are wrapped as `{"value": ...}` (titles, `journal-title`,
//!   `credit-name`, `source-name`, every URL, fuzzy-date parts, `country` of
//!   works and addresses, `amount` with `currency-code`); others are bare
//!   strings (`type`, `content`, `department-name`, organisation fields, ...);
//! * timestamps are `{"value": <epoch milliseconds>}`; the model keeps the XML
//!   text, so reading turns them into `YYYY-MM-DDTHH:MM:SS.mmmZ` and writing
//!   parses any `xs:dateTime` (offset or `Z`; none means UTC) back;
//! * lists are arrays under the item name (`"external-id": [...]`), affiliation
//!   groups hold `"summaries": [{"employment-summary": {...}}]`, research
//!   resources have `"resource-item": [...]` directly, bulk is
//!   `{"bulk": [{"work": ...}, {"error": ...}]}`;
//! * `history/creation-method` uses the Java enum names (`MEMBER_REFERRED`,
//!   `API`, `DIRECT`, `WEBSITE`);
//! * `history/@visibility` is XML-only: ORCID's JSON has no such member (its
//!   Java model refuses unknown members), so writing leaves it out and reading
//!   still takes it if present. An XML -> JSON -> XML round trip loses it.
//! * a work's `country/@visibility` is XML-only for the same reason (ORCID's
//!   `Country` has only `value`).
//!
//! Reading is lenient: unknown keys and `null` are ignored, a text may come
//! bare or wrapped, numbers and strings are accepted for each other, text is
//! trimmed and empty text is absent, a duplicate key keeps its last value.
//! Writing omits absent values (no `null`s), always writes the containers the
//! XSD requires, sorts keys bytewise and pretty-prints with two-space indent
//! and a final LF (serde_json's `to_string_pretty` layout).
//!
//! JSON documents do not name their root, so reading takes the document kind
//! (`model.kinds`: the XML root local name).
const std = @import("std");
const model = @import("model.zig");
const utf8 = @import("utf8.zig");
const xml_read = @import("xml_read.zig");
const Diagnostic = @import("diag.zig").Diagnostic;
const Bump = @import("bump.zig").Bump;

const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const Value = std.json.Value;
const OOM = error{OutOfMemory};
const Text = model.Text;

// ================================================================ timestamps

fn daysFromCivil(y0: i64, m: i64, d: i64) i64 {
    const y = if (m <= 2) y0 - 1 else y0;
    const era = @divTrunc(if (y >= 0) y else y - 399, 400);
    const yoe = y - era * 400;
    const mp = @rem(m + 9, 12);
    const doy = @divTrunc(153 * mp + 2, 5) + d - 1;
    const doe = yoe * 365 + @divTrunc(yoe, 4) - @divTrunc(yoe, 100) + doy;
    return era * 146_097 + doe - 719_468;
}

fn civilFromDays(z0: i64) struct { y: i64, m: i64, d: i64 } {
    const z = z0 + 719_468;
    const era = @divTrunc(if (z >= 0) z else z - 146_096, 146_097);
    const doe = z - era * 146_097;
    const yoe = @divTrunc(doe - @divTrunc(doe, 1460) + @divTrunc(doe, 36_524) - @divTrunc(doe, 146_096), 365);
    const y = yoe + era * 400;
    const doy = doe - (365 * yoe + @divTrunc(yoe, 4) - @divTrunc(yoe, 100));
    const mp = @divTrunc(5 * doy + 2, 153);
    const d = doy - @divTrunc(153 * mp + 2, 5) + 1;
    const m = if (mp < 10) mp + 3 else mp - 9;
    return .{ .y = if (m <= 2) y + 1 else y, .m = m, .d = d };
}

/// Epoch milliseconds → `YYYY-MM-DDTHH:MM:SS.mmmZ` (into `buf`, at least 32
/// bytes).
pub fn millisToDatetime(buf: []u8, ms: i64) []const u8 {
    const days = @divFloor(ms, 86_400_000);
    const rem: u64 = @intCast(@mod(ms, 86_400_000));
    const c = civilFromDays(days);
    var yb: [24]u8 = undefined;
    const year = padInt(&yb, c.y, 4);
    return std.fmt.bufPrint(buf, "{s}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}Z", .{
        year,
        @as(u64, @intCast(c.m)),
        @as(u64, @intCast(c.d)),
        rem / 3_600_000,
        rem / 60_000 % 60,
        rem / 1000 % 60,
        rem % 1000,
    }) catch unreachable;
}

const padInt = @import("xml_write.zig").padInt;

/// `xs:dateTime` (`YYYY-MM-DDTHH:MM:SS[.f+][Z|±HH:MM]`, no zone = UTC) →
/// epoch milliseconds (fractions beyond milliseconds are truncated).
pub fn datetimeToMillis(text: []const u8) ?i64 {
    const s = utf8.trimUnicode(text);
    if (s.len < 19 or s[4] != '-' or s[7] != '-' or s[10] != 'T' or s[13] != ':' or s[16] != ':') return null;
    const y = digitsAt(s, 0, 4) orelse return null;
    const mo = digitsAt(s, 5, 7) orelse return null;
    const d = digitsAt(s, 8, 10) orelse return null;
    const h = digitsAt(s, 11, 13) orelse return null;
    const mi = digitsAt(s, 14, 16) orelse return null;
    const sec = digitsAt(s, 17, 19) orelse return null;
    if (mo < 1 or mo > 12 or d < 1 or d > 31 or h > 24 or mi > 59 or sec > 60) return null;
    var i: usize = 19;
    var ms: i64 = 0;
    if (i < s.len and s[i] == '.') {
        i += 1;
        const start = i;
        while (i < s.len and s[i] >= '0' and s[i] <= '9') i += 1;
        if (i == start) return null;
        const frac = s[start..@min(i, start + 3)];
        var f: i64 = 0;
        for (frac) |c| f = f * 10 + (c - '0');
        var k = frac.len;
        while (k < 3) : (k += 1) f *= 10;
        ms = f;
    }
    const z = s[i..];
    var offset_min: i64 = 0;
    if (z.len == 0 or std.mem.eql(u8, z, "Z")) {
        offset_min = 0;
    } else if (z.len == 6 and (z[0] == '+' or z[0] == '-') and z[3] == ':') {
        const hh = xml_read.parseSigned(z[1..3]) orelse return null;
        const mm = xml_read.parseSigned(z[4..6]) orelse return null;
        const sign: i64 = if (z[0] == '-') -1 else 1;
        offset_min = sign * (hh * 60 + mm);
    } else return null;
    const days = daysFromCivil(y, mo, d);
    return ((days * 24 + h) * 60 + mi - offset_min) * 60_000 + sec * 1000 + ms;
}

fn digitsAt(s: []const u8, from: usize, to: usize) ?i64 {
    var v: i64 = 0;
    for (s[from..to]) |c| {
        if (c < '0' or c > '9') return null;
        v = v * 10 + (c - '0');
    }
    return v;
}

// =================================================================== reading
//
// One pass over the bytes, straight onto the model: no value tree and no map
// per object. Each type's reader walks its object key by key; `keyOf` turns
// the key into a `Key` (a switch on the length, then a vector compare with
// each known key of that length) and the reader switches on it. Unknown keys
// and values of the wrong shape are skipped, their syntax checked. A field
// is assigned each time its key is read, so a duplicate key keeps its last
// value (also when that value is `null`).
//
// Strings are borrowed from the input while they are inspected (vocabulary
// values, integers, booleans) and copied into the document only when the
// model keeps them; only strings with escapes are decoded, into a scratch
// buffer. The items of a list collect on one scratch stack (nested lists
// stack above their parent's items) and move to the document when the list
// closes. Document memory comes from a `Bump` over the document's arena,
// whose first chunk is sized from the input.
//
// Syntax is checked as std.json checks it (RFC 8259, paired surrogates
// only), with its error names in `Diagnostic.message`: `SyntaxError` at the
// first offending byte, `UnexpectedEndOfInput` for truncated input. Nothing
// recurses on the nesting of the input: the readers recurse along the schema
// only (about a dozen levels), and skipped values and `{"value": ...}` chains
// are walked with an explicit bracket stack, so any depth that fits in memory
// reads in bounded native stack, as std.json's iterative parser did.

pub const ParseError = error{
    /// Not JSON, or not an object (see `Diagnostic.message`).
    MalformedJson,
    /// The input is not UTF-8 (`Diagnostic.position` = valid bytes).
    InvalidUtf8,
    /// `kind` is not one of `model.kinds`.
    UnknownKind,
    OutOfMemory,
};

/// Reads a JSON document of the given kind (the XML root local name, see
/// `model.kinds`). UTF-8, optional BOM. The Document owns its memory.
pub fn parse(gpa: Allocator, kind: []const u8, input: []const u8, diag: ?*Diagnostic) ParseError!model.Document {
    const bytes = if (std.mem.startsWith(u8, input, "\xEF\xBB\xBF")) input[3..] else input;
    if (utf8.invalidIndex(bytes)) |bad| {
        if (diag) |d| {
            d.message = "input is not UTF-8";
            d.position = bad;
        }
        return error.InvalidUtf8;
    }
    return read(gpa, kind, bytes, false, diag);
}

/// Maps a parsed `std.json.Value` of the given kind onto the model, with the
/// rules of `parse`. The value is written out as JSON text (see `writeValue`)
/// and read back.
pub fn fromValue(gpa: Allocator, kind: []const u8, value: *const Value, diag: ?*Diagnostic) ParseError!model.Document {
    if (value.* != .object) {
        if (diag) |d| d.message = "a document must be a JSON object";
        return error.MalformedJson;
    }
    var aw: Writer.Allocating = .init(gpa);
    defer aw.deinit();
    writeValue(gpa, &aw.writer, value) catch return error.OutOfMemory;
    return read(gpa, kind, aw.written(), true, diag);
}

fn read(gpa: Allocator, kind: []const u8, bytes: []const u8, value_mode: bool, diag: ?*Diagnostic) ParseError!model.Document {
    const arena = try gpa.create(std.heap.ArenaAllocator);
    errdefer gpa.destroy(arena);
    arena.* = .init(gpa);
    errdefer arena.deinit();
    // The model of pretty-printed ORCID JSON takes about twice its size.
    var p: Parser = .{
        .s = bytes,
        .value_mode = value_mode,
        .gpa = gpa,
        .mem = try Bump.init(arena.allocator(), @max(2 * bytes.len, 4096), @max(bytes.len, 4096)),
    };
    defer p.deinit();
    const outcome = p.document(kind) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.SyntaxError, error.UnexpectedEndOfInput => {
            if (diag) |d| d.message = @errorName(err);
            return error.MalformedJson;
        },
    };
    const r = switch (outcome) {
        .rooted => |x| x,
        .not_object => {
            if (diag) |d| d.message = "a document must be a JSON object";
            return error.MalformedJson;
        },
        .unknown_kind => {
            if (diag) |d| d.message = "unknown document kind";
            return error.UnknownKind;
        },
    };
    return .{ .arena = arena, .root_name = try p.mem.dupe(kind), .root_path = r.path, .root = r.root };
}

/// `fromValue`'s input: `value` as JSON text. Numbers keep the distinctions
/// of `std.json.Value` through two spellings only this reader accepts (and
/// only in `fromValue`): a `.float` is `~` and a string of its `{d}` text (a
/// number that never reads as an integer), a `.number_string` is `#` and a
/// string of its text (integers that fit i64 in decimal, as serde_json
/// prints them, anything else as it is). Iterative: any depth.
fn writeValue(gpa: Allocator, w: *Writer, root: *const Value) (Writer.Error || OOM)!void {
    const Open = struct { v: *const Value, next: usize = 0 };
    var stack: std.ArrayList(Open) = .empty;
    defer stack.deinit(gpa);
    var v = root;
    while (true) {
        switch (v.*) {
            .null => try w.writeAll("null"),
            .bool => |b| try w.writeAll(if (b) "true" else "false"),
            .integer => |i| try w.print("{d}", .{i}),
            .float => |f| try w.print("~\"{d}\"", .{f}),
            .number_string => |s| {
                var buf: [24]u8 = undefined;
                try w.writeByte('#');
                try writeString(w, numberStringText(&buf, s));
            },
            .string => |s| try writeString(w, s),
            .array => {
                try w.writeByte('[');
                try stack.append(gpa, .{ .v = v });
            },
            .object => {
                try w.writeByte('{');
                try stack.append(gpa, .{ .v = v });
            },
        }
        // the next value to write, closing the containers it finishes
        v = while (stack.items.len > 0) {
            const top = &stack.items[stack.items.len - 1];
            const i = top.next;
            top.next += 1;
            switch (top.v.*) {
                .array => |*arr| if (i < arr.items.len) {
                    if (i > 0) try w.writeByte(',');
                    break &arr.items[i];
                } else try w.writeByte(']'),
                .object => |*obj| if (i < obj.count()) {
                    if (i > 0) try w.writeByte(',');
                    try writeString(w, obj.keys()[i]);
                    try w.writeByte(':');
                    break &obj.values()[i];
                } else try w.writeByte('}'),
                else => unreachable,
            }
            _ = stack.pop();
        } else return;
    }
}

/// The text of a `.number_string` (see `writeValue`); `buf` holds it when
/// it is reformatted.
fn numberStringText(buf: *[24]u8, raw: []const u8) []const u8 {
    if (!std.json.isNumberFormattedLikeAnInteger(raw)) return raw;
    const v = std.fmt.parseInt(i64, raw, 10) catch return raw;
    return std.fmt.bufPrint(buf, "{d}", .{v}) catch unreachable;
}

// ------------------------------------------------------------------- keys

/// Every key a reader looks at (several mean different things in different
/// objects: `title`, `address`, `email`, `country`, `path`, ...).
const Key = enum {
    @"activities-summary",
    address,
    addresses,
    @"affiliation-group",
    amount,
    @"assertion-origin-client-id",
    @"assertion-origin-name",
    @"assertion-origin-orcid",
    biography,
    bulk,
    citation,
    @"citation-type",
    @"citation-value",
    city,
    claimed,
    @"completion-date",
    content,
    contributor,
    @"contributor-attributes",
    @"contributor-email",
    @"contributor-orcid",
    @"contributor-role",
    @"contributor-sequence",
    contributors,
    @"convening-organization",
    country,
    @"created-date",
    @"creation-method",
    @"credit-name",
    @"currency-code",
    day,
    @"deactivation-date",
    @"department-name",
    @"developer-message",
    @"disambiguated-organization",
    @"disambiguated-organization-identifier",
    @"disambiguation-source",
    @"display-index",
    @"distinction-summary",
    distinctions,
    @"education-summary",
    educations,
    email,
    emails,
    @"employment-summary",
    employments,
    @"end-date",
    @"error",
    @"error-code",
    @"error-message",
    @"expanded-result",
    @"external-id",
    @"external-id-normalized",
    @"external-id-normalized-error",
    @"external-id-relationship",
    @"external-id-type",
    @"external-id-url",
    @"external-id-value",
    @"external-identifier",
    @"external-identifiers",
    @"external-ids",
    @"family-name",
    @"family-names",
    @"funding-summary",
    fundings,
    @"given-names",
    group,
    history,
    host,
    hosts,
    @"institution-name",
    @"invited-position-summary",
    @"invited-positions",
    @"journal-title",
    keyword,
    keywords,
    @"language-code",
    @"last-modified-date",
    locale,
    @"membership-summary",
    memberships,
    month,
    @"more-info",
    name,
    @"num-found",
    @"orcid-id",
    @"orcid-identifier",
    organization,
    @"organization-defined-type",
    @"other-name",
    @"other-names",
    path,
    @"peer-review-group",
    @"peer-review-summary",
    @"peer-reviews",
    person,
    preferences,
    primary,
    proposal,
    @"publication-date",
    @"put-code",
    @"qualification-summary",
    qualifications,
    region,
    @"research-resource-summary",
    @"research-resources",
    @"researcher-url",
    @"researcher-urls",
    @"resource-item",
    @"resource-items",
    @"resource-name",
    @"resource-type",
    @"response-code",
    result,
    @"review-completion-date",
    @"review-group-id",
    @"review-identifiers",
    @"review-type",
    @"review-url",
    @"reviewer-role",
    @"role-title",
    @"service-summary",
    services,
    @"short-description",
    source,
    @"source-client-id",
    @"source-name",
    @"source-orcid",
    @"start-date",
    @"subject-container-name",
    @"subject-external-identifier",
    @"subject-name",
    @"subject-type",
    @"subject-url",
    @"submission-date",
    subtitle,
    summaries,
    title,
    @"translated-title",
    transient,
    type,
    uri,
    url,
    @"url-name",
    @"user-message",
    value,
    verified,
    @"verified-email",
    @"verified-primary-email",
    visibility,
    work,
    @"work-summary",
    works,
    year,
    /// Any other key (never produced by `keyOf`).
    @"(unknown)",
};

/// Every `Key`, computed once (std.enums.values walks all ~150 fields at
/// comptime; doing that per key length exceeded the branch quota).
const all_keys: []const Key = blk: {
    @setEvalBranchQuota(100_000);
    break :blk std.enums.values(Key);
};

fn maxKeyLen() usize {
    @setEvalBranchQuota(100_000);
    var m: usize = 0;
    for (all_keys) |k| m = @max(m, @tagName(k).len);
    return m;
}

const max_key_len = maxKeyLen();

/// The known keys of length `n`.
inline fn keysOfLen(comptime n: usize) []const Key {
    comptime {
        @setEvalBranchQuota(1_000_000);
        var count: usize = 0;
        for (all_keys) |k| {
            if (k != .@"(unknown)" and @tagName(k).len == n) count += 1;
        }
        var out: [count]Key = undefined;
        var i: usize = 0;
        for (all_keys) |k| {
            if (k != .@"(unknown)" and @tagName(k).len == n) {
                out[i] = k;
                i += 1;
            }
        }
        const final = out;
        return &final;
    }
}

/// The `Key` named `name`, null if no reader looks at it.
fn keyOf(name: []const u8) ?Key {
    // the inline prongs and loops below unroll at comptime over every key
    @setEvalBranchQuota(1_000_000);
    switch (name.len) {
        inline 1...max_key_len => |n| {
            const word: @Vector(n, u8) = name[0..n].*;
            inline for (comptime keysOfLen(n)) |k| {
                const want: @Vector(n, u8) = comptime @tagName(k)[0..n].*;
                if (@reduce(.And, word == want)) return k;
            }
            return null;
        },
        else => return null,
    }
}

// ---------------------------------------------------------------- scanner

const ReadError = error{ SyntaxError, UnexpectedEndOfInput, OutOfMemory };

const vec_len = std.simd.suggestVectorLength(u8) orelse 16;
const Vec = @Vector(vec_len, u8);
const Bits = @Vector(vec_len, u1);

/// Index of the first `"`, `\` or control byte at or after `from` (or
/// `s.len`): a vector at a time, then byte by byte for the tail.
fn findSpecial(s: []const u8, from: usize) usize {
    var i = from;
    while (i + vec_len <= s.len) : (i += vec_len) {
        const v: Vec = s[i..][0..vec_len].*;
        const hits = @as(Bits, @bitCast(v == @as(Vec, @splat('"')))) |
            @as(Bits, @bitCast(v == @as(Vec, @splat('\\')))) |
            @as(Bits, @bitCast(v < @as(Vec, @splat(0x20))));
        if (std.simd.firstTrue(hits != @as(Bits, @splat(0)))) |k| return i + k;
    }
    while (i < s.len) : (i += 1) {
        const c = s[i];
        if (c == '"' or c == '\\' or c < 0x20) return i;
    }
    return s.len;
}

fn digitsEnd(s: []const u8, from: usize) usize {
    var i = from;
    while (i < s.len and s[i] >= '0' and s[i] <= '9') i += 1;
    return i;
}

fn isDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}

fn expectAt(s: []const u8, i: usize, c: u8) error{ SyntaxError, UnexpectedEndOfInput }!void {
    if (i >= s.len) return error.UnexpectedEndOfInput;
    if (s[i] != c) return error.SyntaxError;
}

/// Four hex digits of a `\u` escape at `i.*` (advanced past them). `low`:
/// they must be a low surrogate (`DC00`-`DFFF`), checked digit by digit as
/// std.json does.
fn hexUnit(s: []const u8, i: *usize, low: bool) error{ SyntaxError, UnexpectedEndOfInput }!u16 {
    var v: u16 = 0;
    for (0..4) |k| {
        if (i.* >= s.len) return error.UnexpectedEndOfInput;
        const c = s[i.*];
        const d: u16 = switch (c) {
            '0'...'9' => c - '0',
            'a'...'f' => c - 'a' + 10,
            'A'...'F' => c - 'A' + 10,
            else => return error.SyntaxError,
        };
        if (low and ((k == 0 and d != 0xD) or (k == 1 and d < 0xC))) return error.SyntaxError;
        v = v << 4 | d;
        i.* += 1;
    }
    return v;
}

/// A JSON number, as written (`float`: a `std.json.Value` float, see
/// `writeValue`).
const Num = struct {
    text: []const u8,
    float: bool = false,

    /// serde's `as_i64`: an integer-formatted number that fits i64.
    fn asI64(n: Num) ?i64 {
        if (n.float or !std.json.isNumberFormattedLikeAnInteger(n.text)) return null;
        return std.fmt.parseInt(i64, n.text, 10) catch null;
    }
};

/// An object being read: whether the next member is the first.
const Obj = struct { first: bool = true };

/// An array being read: whether the next element is the first.
const Arr = struct { first: bool = true };

fn ValueWith(comptime A: type) type {
    return struct { value: ?Text = null, attr: ?A = null };
}

const Rooted = struct { root: model.Root, path: ?Text };

const Outcome = union(enum) { rooted: Rooted, not_object, unknown_kind };

const Parser = struct {
    s: []const u8,
    i: usize = 0,
    /// `fromValue`'s text: also accept the number spellings of `writeValue`.
    value_mode: bool,
    gpa: Allocator,
    /// The document's memory.
    mem: Bump,
    /// Items of the lists being read, as bytes (see `list`).
    stack: std.ArrayList(u8) = .empty,
    /// Open brackets of the value being skipped.
    nest: std.ArrayList(u8) = .empty,
    /// The last string with escapes, decoded.
    unesc: std.ArrayList(u8) = .empty,
    /// Whether the last string read is in `unesc` (else it is in `s`).
    esc: bool = false,

    fn deinit(p: *Parser) void {
        p.stack.deinit(p.gpa);
        p.nest.deinit(p.gpa);
        p.unesc.deinit(p.gpa);
    }

    fn skipWs(p: *Parser) void {
        const s = p.s;
        var i = p.i;
        while (i < s.len) {
            switch (s[i]) {
                ' ' => if (i + vec_len <= s.len) {
                    // indentation: a vector of spaces at a time
                    const v: Vec = s[i..][0..vec_len].*;
                    if (std.simd.firstTrue(v != @as(Vec, @splat(' ')))) |k| {
                        i += k;
                    } else {
                        i += vec_len;
                    }
                } else {
                    i += 1;
                },
                '\n', '\r', '\t' => i += 1,
                else => break,
            }
        }
        p.i = i;
    }

    /// The next byte after whitespace (not consumed).
    fn peek(p: *Parser) ReadError!u8 {
        p.skipWs();
        if (p.i >= p.s.len) return error.UnexpectedEndOfInput;
        return p.s[p.i];
    }

    /// Only whitespace may follow the document.
    fn end(p: *Parser) ReadError!void {
        p.skipWs();
        if (p.i < p.s.len) return error.SyntaxError;
    }

    fn document(p: *Parser, kind: []const u8) ReadError!Outcome {
        const c = try p.peek();
        if (c == '{') {
            if (try readRoot(p, kind)) |r| {
                try p.end();
                return .{ .rooted = r };
            }
        }
        // checked all the same: a syntax error takes precedence
        try p.skip();
        try p.end();
        return if (c == '{') .unknown_kind else .not_object;
    }

    // ------------------------------------------------------------ tokens

    /// The string whose opening quote was just consumed, decoded; the cursor
    /// moves past its closing quote. Borrowed from the input unless it has
    /// escapes (then valid until the next string).
    fn stringBody(p: *Parser) ReadError![]const u8 {
        const s = p.s;
        const start = p.i;
        const j = findSpecial(s, start);
        if (j < s.len and s[j] == '"') {
            p.i = j + 1;
            p.esc = false;
            return s[start..j];
        }
        return p.escaped(start, j);
    }

    /// `stringBody` from `first`, its first special byte (or the end).
    fn escaped(p: *Parser, start: usize, first: usize) ReadError![]const u8 {
        @branchHint(.unlikely);
        const s = p.s;
        p.unesc.clearRetainingCapacity();
        var from = start;
        var j = first;
        while (true) {
            if (j >= s.len) return error.UnexpectedEndOfInput;
            try p.unesc.appendSlice(p.gpa, s[from..j]);
            switch (s[j]) {
                '"' => {
                    p.i = j + 1;
                    p.esc = true;
                    return p.unesc.items;
                },
                '\\' => from = try p.escape(j + 1),
                else => return error.SyntaxError, // a control character
            }
            j = findSpecial(s, from);
        }
    }

    /// Decodes the escape whose backslash is before `at`; returns the index
    /// after it.
    fn escape(p: *Parser, at: usize) ReadError!usize {
        const s = p.s;
        if (at >= s.len) return error.UnexpectedEndOfInput;
        const byte: u8 = switch (s[at]) {
            '"', '\\', '/' => s[at],
            'b' => 0x08,
            'f' => 0x0C,
            'n' => '\n',
            'r' => '\r',
            't' => '\t',
            'u' => {
                var i = at + 1;
                const hi = try hexUnit(s, &i, false);
                var cp: u21 = hi;
                if (hi >= 0xD800 and hi <= 0xDBFF) {
                    // a high surrogate: a `\u` low surrogate must follow
                    try expectAt(s, i, '\\');
                    try expectAt(s, i + 1, 'u');
                    i += 2;
                    const lo = try hexUnit(s, &i, true);
                    cp = 0x10000 + ((@as(u21, hi) - 0xD800) << 10) + (lo - 0xDC00);
                } else if (hi >= 0xDC00 and hi <= 0xDFFF) {
                    return error.SyntaxError; // a low surrogate on its own
                }
                try utf8.appendCodepoint(&p.unesc, p.gpa, cp);
                return i;
            },
            else => return error.SyntaxError,
        };
        try p.unesc.append(p.gpa, byte);
        return at + 1;
    }

    /// The number at the cursor (`-` or a digit), as written.
    fn number(p: *Parser) ReadError![]const u8 {
        const s = p.s;
        const start = p.i;
        var i = start;
        if (s[i] == '-') i += 1;
        if (i >= s.len) return error.UnexpectedEndOfInput;
        switch (s[i]) {
            '0' => i += 1,
            '1'...'9' => i = digitsEnd(s, i + 1),
            else => return error.SyntaxError,
        }
        if (i < s.len and s[i] == '.') {
            i += 1;
            if (i >= s.len) return error.UnexpectedEndOfInput;
            if (!isDigit(s[i])) return error.SyntaxError;
            i = digitsEnd(s, i + 1);
        }
        if (i < s.len and (s[i] == 'e' or s[i] == 'E')) {
            i += 1;
            if (i >= s.len) return error.UnexpectedEndOfInput;
            if (s[i] == '+' or s[i] == '-') {
                i += 1;
                if (i >= s.len) return error.UnexpectedEndOfInput;
            }
            if (!isDigit(s[i])) return error.SyntaxError;
            i = digitsEnd(s, i + 1);
        }
        p.i = i;
        return s[start..i];
    }

    /// `true`, `false` or `null` at the cursor (its first byte checked).
    fn literal(p: *Parser, comptime word: []const u8) ReadError!void {
        var i = p.i + 1;
        inline for (word[1..]) |c| {
            if (i >= p.s.len) return error.UnexpectedEndOfInput;
            if (p.s[i] != c) return error.SyntaxError;
            i += 1;
        }
        p.i = i;
    }

    /// `fromValue`'s `#"..."` or `~"..."` at the cursor (see `writeValue`).
    fn marked(p: *Parser, c: u8) ReadError!Num {
        if (!p.value_mode) return error.SyntaxError;
        try expectAt(p.s, p.i + 1, '"');
        p.i += 2;
        return .{ .text = try p.stringBody(), .float = c == '~' };
    }

    /// Consumes the `{` at the cursor (peeked by the caller).
    fn open(p: *Parser) Obj {
        p.i += 1;
        return .{};
    }

    /// The next key of the object, the cursor after its `:`; null (the `}`
    /// consumed) at the end.
    fn key(p: *Parser, o: *Obj) ReadError!?Key {
        var c = try p.peek();
        if (c == '}') {
            p.i += 1;
            return null;
        }
        if (!o.first) {
            if (c != ',') return error.SyntaxError;
            p.i += 1;
            c = try p.peek();
        }
        o.first = false;
        if (c != '"') return error.SyntaxError;
        p.i += 1;
        const name = try p.stringBody();
        if (try p.peek() != ':') return error.SyntaxError;
        p.i += 1;
        return keyOf(name) orelse .@"(unknown)";
    }

    /// `key`, returning the key's name instead of a `Key` (valid until the
    /// next string is read): for the group-id readers, whose keys are not
    /// `Key`s, so that `keyOf` and the record readers stay as they are.
    fn keyName(p: *Parser, o: *Obj) ReadError!?[]const u8 {
        var c = try p.peek();
        if (c == '}') {
            p.i += 1;
            return null;
        }
        if (!o.first) {
            if (c != ',') return error.SyntaxError;
            p.i += 1;
            c = try p.peek();
        }
        o.first = false;
        if (c != '"') return error.SyntaxError;
        p.i += 1;
        const name = try p.stringBody();
        if (try p.peek() != ':') return error.SyntaxError;
        p.i += 1;
        return name;
    }

    /// Whether the array (its `[` consumed) has another element, the cursor
    /// then at it; false (the `]` consumed) at the end.
    fn more(p: *Parser, a: *Arr) ReadError!bool {
        const c = try p.peek();
        if (c == ']') {
            p.i += 1;
            return false;
        }
        if (!a.first) {
            if (c != ',') return error.SyntaxError;
            p.i += 1;
        }
        a.first = false;
        return true;
    }

    /// Skips the value at the cursor, checking it.
    fn skip(p: *Parser) ReadError!void {
        const c = try p.peek();
        switch (c) {
            '{', '[' => try p.skipContainer(c),
            else => _ = try p.leafView(c),
        }
    }

    /// Skips the object or array at the cursor (`first` is its bracket),
    /// keeping the open brackets on `nest` rather than on the native stack.
    fn skipContainer(p: *Parser, first: u8) ReadError!void {
        const base = p.nest.items.len;
        defer p.nest.shrinkRetainingCapacity(base);
        var c = first;
        while (true) {
            // `c` starts a value
            switch (c) {
                '{', '[' => {
                    p.i += 1;
                    const close: u8 = if (c == '{') '}' else ']';
                    if (try p.peek() == close) {
                        p.i += 1;
                    } else {
                        try p.nest.append(p.gpa, c);
                        if (c == '{') try p.memberKey();
                        c = try p.peek();
                        continue;
                    }
                },
                else => _ = try p.leafView(c),
            }
            // after a value: close what it finishes, then on to the next one
            while (true) {
                const n = p.nest.items.len;
                if (n == base) return;
                const top = p.nest.items[n - 1];
                const d = try p.peek();
                if (d == ',') {
                    p.i += 1;
                    if (top == '{') try p.memberKey();
                    break;
                }
                if (d != (if (top == '{') @as(u8, '}') else ']')) return error.SyntaxError;
                p.i += 1;
                p.nest.shrinkRetainingCapacity(n - 1);
            }
            c = try p.peek();
        }
    }

    /// A key and its `:` in a skipped object.
    fn memberKey(p: *Parser) ReadError!void {
        if (try p.peek() != '"') return error.SyntaxError;
        p.i += 1;
        _ = try p.stringBody();
        if (try p.peek() != ':') return error.SyntaxError;
        p.i += 1;
    }

    // ------------------------------------------------------------ values

    /// A value that is not an object or array, as text: strings trimmed
    /// (empty is null), numbers as written, `true`/`false`, `null` is null.
    /// Not copied (see `stringBody`).
    fn leafView(p: *Parser, c: u8) ReadError!?[]const u8 {
        switch (c) {
            '"' => {
                p.i += 1;
                const t = model.trimXmlSpace(try p.stringBody());
                return if (t.len == 0) null else t;
            },
            '-', '0'...'9' => return try p.number(),
            't' => {
                try p.literal("true");
                return "true";
            },
            'f' => {
                try p.literal("false");
                return "false";
            },
            'n' => {
                try p.literal("null");
                return null;
            },
            '#', '~' => return (try p.marked(c)).text,
            else => return error.SyntaxError,
        }
    }

    /// Any value as text (not copied): `leafView` for scalars, an object's
    /// `"value"` member (its last, read the same way), null for arrays.
    fn scalarView(p: *Parser) ReadError!?[]const u8 {
        const c = try p.peek();
        switch (c) {
            '{' => return p.wrappedView(),
            '[' => {
                try p.skipContainer(c);
                return null;
            },
            else => return p.leafView(c),
        }
    }

    /// The `"value"` of the object at the cursor, following nested
    /// `{"value": {"value": ...}}` with a depth count (each level's result
    /// is the last `"value"` member it holds; an object without one is
    /// null). Escaped strings are copied, since more strings follow.
    fn wrappedView(p: *Parser) ReadError!?[]const u8 {
        var o = p.open();
        var depth: usize = 1;
        var cur: ?[]const u8 = null;
        while (true) {
            const k = (try p.key(&o)) orelse {
                depth -= 1;
                if (depth == 0) return cur;
                o = .{ .first = false };
                continue;
            };
            if (k != .value) {
                try p.skip();
                continue;
            }
            const c = try p.peek();
            switch (c) {
                '{' => {
                    o = p.open();
                    depth += 1;
                    cur = null;
                },
                '[' => {
                    try p.skipContainer(c);
                    cur = null;
                },
                else => {
                    cur = try p.leafView(c);
                    if (p.esc) {
                        if (cur) |t| cur = try p.mem.dupe(t);
                    }
                },
            }
        }
    }

    /// Text the model keeps (`scalarView`, copied into the document).
    fn text(p: *Parser) ReadError!?Text {
        const t = (try p.scalarView()) orelse return null;
        return try p.mem.dupe(t);
    }

    /// A timestamp: epoch milliseconds (bare or `{"value": ms}`) as
    /// `YYYY-MM-DDTHH:MM:SS.mmmZ`, null for a number that is not an i64;
    /// other values as `text` reads them.
    fn time(p: *Parser) ReadError!?Text {
        if (try p.peek() != '{') return p.timeOf();
        var o = p.open();
        var out: ?Text = null;
        while (try p.key(&o)) |k| {
            if (k == .value) {
                out = try p.timeOf();
            } else try p.skip();
        }
        return out;
    }

    fn timeOf(p: *Parser) ReadError!?Text {
        const c = try p.peek();
        const n: Num = switch (c) {
            '-', '0'...'9' => .{ .text = try p.number() },
            '#', '~' => try p.marked(c),
            else => return p.text(),
        };
        const ms = n.asI64() orelse return null;
        var buf: [40]u8 = undefined;
        return try p.mem.dupe(millisToDatetime(&buf, ms));
    }

    /// yorc-duckdb's integer rule over the text: 1..=`max` ASCII digits.
    fn digits(p: *Parser, max: usize) ReadError!?i64 {
        const t = (try p.scalarView()) orelse return null;
        return xml_read.parseInteger(t, max);
    }

    fn int32(p: *Parser) ReadError!?i32 {
        const v = (try p.digits(9)) orelse return null;
        return std.math.cast(i32, v);
    }

    fn signed(p: *Parser) ReadError!?i64 {
        const t = (try p.scalarView()) orelse return null;
        return xml_read.parseSigned(t);
    }

    /// A JSON boolean, or text that parses as one (`true`/`1`, `false`/`0`).
    fn boolean(p: *Parser) ReadError!?bool {
        switch (try p.peek()) {
            't' => {
                try p.literal("true");
                return true;
            },
            'f' => {
                try p.literal("false");
                return false;
            },
            else => {
                const t = (try p.scalarView()) orelse return null;
                return xml_read.parseBool(t);
            },
        }
    }

    /// A vocabulary value; only text outside the vocabulary is copied.
    fn vocab(p: *Parser, comptime V: type) ReadError!?V {
        const t = (try p.scalarView()) orelse return null;
        return switch (V.parse(t)) {
            .known => |k| .{ .known = k },
            .other => .{ .other = try p.mem.dupe(t) },
        };
    }

    fn visibility(p: *Parser) ReadError!?model.Visibility {
        return p.vocab(model.Visibility);
    }

    /// A text with an attribute: `{"value": ..., <attr>: ...}`, or a bare
    /// scalar (no attribute). null for `null` only: any other value gives a
    /// (possibly empty) result.
    fn valueWith(p: *Parser, comptime attr: Key, comptime A: type, comptime readAttr: fn (*Parser) ReadError!?A) ReadError!?ValueWith(A) {
        switch (try p.peek()) {
            'n' => {
                try p.literal("null");
                return null;
            },
            '{' => {
                var o = p.open();
                var out: ValueWith(A) = .{};
                while (try p.key(&o)) |k| {
                    if (k == .value) {
                        out.value = try p.text();
                    } else if (k == attr) {
                        out.attr = try readAttr(p);
                    } else try p.skip();
                }
                return out;
            },
            else => return .{ .value = try p.text() },
        }
    }

    /// The object at the cursor read by `f`; null (the value skipped) for
    /// anything else.
    fn optObject(p: *Parser, comptime T: type, comptime f: fn (*Parser) ReadError!T) ReadError!?T {
        if (try p.peek() != '{') {
            try p.skip();
            return null;
        }
        return try f(p);
    }

    /// Moves the stack's items above `mark` into the document.
    fn take(p: *Parser, comptime T: type, mark: usize) ReadError![]const T {
        const raw = p.stack.items[mark..];
        if (raw.len == 0) return &.{};
        const out = try p.mem.alloc(T, raw.len / @sizeOf(T));
        @memcpy(std.mem.sliceAsBytes(out), raw);
        p.stack.shrinkRetainingCapacity(mark);
        return out;
    }

    fn push(p: *Parser, comptime T: type, x: *const T) ReadError!void {
        try p.stack.appendSlice(p.gpa, std.mem.asBytes(x));
    }

    /// The objects of an array, each read by `item`; a single object is a
    /// list of one, anything else (and any element that is not an object)
    /// is skipped.
    fn list(p: *Parser, comptime T: type, comptime item: fn (*Parser) ReadError!T) ReadError![]const T {
        switch (try p.peek()) {
            '{' => {
                const x = try item(p);
                const out = try p.mem.alloc(T, 1);
                out[0] = x;
                return out;
            },
            '[' => {
                p.i += 1;
                const mark = p.stack.items.len;
                var a: Arr = .{};
                while (try p.more(&a)) {
                    if (try p.peek() == '{') {
                        const x = try item(p);
                        try p.push(T, &x);
                    } else try p.skip();
                }
                return p.take(T, mark);
            },
            else => {
                try p.skip();
                return &.{};
            },
        }
    }

    /// `list` for items that may be dropped (`item` returns null).
    fn listSome(p: *Parser, comptime T: type, comptime item: fn (*Parser) ReadError!?T) ReadError![]const T {
        switch (try p.peek()) {
            '{' => {
                const x = (try item(p)) orelse return &.{};
                const out = try p.mem.alloc(T, 1);
                out[0] = x;
                return out;
            },
            '[' => {
                p.i += 1;
                const mark = p.stack.items.len;
                var a: Arr = .{};
                while (try p.more(&a)) {
                    if (try p.peek() == '{') {
                        if (try item(p)) |x| try p.push(T, &x);
                    } else try p.skip();
                }
                return p.take(T, mark);
            },
            else => {
                try p.skip();
                return &.{};
            },
        }
    }

    /// A list under one key of an object (`{"external-id": [...]}`,
    /// `{"contributor": [...]}`, ...); empty for anything but an object.
    fn wrappedList(p: *Parser, comptime item_key: Key, comptime T: type, comptime item: fn (*Parser) ReadError!T) ReadError![]const T {
        if (try p.peek() != '{') {
            try p.skip();
            return &.{};
        }
        var o = p.open();
        var out: []const T = &.{};
        while (try p.key(&o)) |k| {
            if (k == item_key) {
                out = try p.list(T, item);
            } else try p.skip();
        }
        return out;
    }

    /// Texts: each element of an array as `text` reads it (null ones
    /// dropped), or a single value.
    fn strings(p: *Parser) ReadError![]const Text {
        if (try p.peek() != '[') {
            const t = (try p.text()) orelse return &.{};
            const out = try p.mem.alloc(Text, 1);
            out[0] = t;
            return out;
        }
        p.i += 1;
        const mark = p.stack.items.len;
        var a: Arr = .{};
        while (try p.more(&a)) {
            if (try p.text()) |t| try p.push(Text, &t);
        }
        return p.take(Text, mark);
    }

    fn extIds(p: *Parser) ReadError![]const model.ExternalId {
        return p.wrappedList(.@"external-id", model.ExternalId, rExtId);
    }

    fn contributors(p: *Parser) ReadError![]const model.Contributor {
        return p.wrappedList(.contributor, model.Contributor, rContributor);
    }

    fn hosts(p: *Parser) ReadError![]const model.Organization {
        return p.wrappedList(.organization, model.Organization, rOrg);
    }

    fn date(p: *Parser) ReadError!?model.FuzzyDate {
        return p.optObject(model.FuzzyDate, rDate);
    }

    fn title(p: *Parser) ReadError!?model.Title {
        return p.optObject(model.Title, rTitle);
    }

    fn org(p: *Parser) ReadError!?model.Organization {
        return p.optObject(model.Organization, rOrg);
    }

    fn ident(p: *Parser) ReadError!?model.OrcidIdentifier {
        return p.optObject(model.OrcidIdentifier, rIdent);
    }
};

// ------------------------------------------------------------ the readers
// Each reader is called with the cursor at its object's `{`.

/// One `common:element-summary` member of an item (put-code, visibility,
/// ...); any other key is skipped. `finishMeta` completes it.
fn metaField(p: *Parser, m: *model.ItemMeta, k: Key) ReadError!void {
    switch (k) {
        .@"put-code" => m.put_code = try p.digits(18),
        .visibility => m.visibility = try p.visibility(),
        // the raw text until `finishMeta`
        .@"display-index" => m.display_index_text = try p.text(),
        .path => m.path = try p.text(),
        .@"created-date" => m.created_date = try p.time(),
        .@"last-modified-date" => m.last_modified_date = try p.time(),
        .source => m.source = try p.optObject(model.Source, rSource),
        else => try p.skip(),
    }
}

/// `display_index` from the display-index text, which is kept only when it
/// is not that number in decimal (e.g. `-1`).
fn finishMeta(m: *model.ItemMeta) void {
    const t = m.display_index_text orelse return;
    m.display_index = if (xml_read.parseInteger(t, 9)) |v| std.math.cast(i32, v) else null;
    if (m.display_index) |v| {
        var buf: [16]u8 = undefined;
        if (std.mem.eql(u8, std.fmt.bufPrint(&buf, "{d}", .{v}) catch "", t)) m.display_index_text = null;
    }
}

fn rIdent(p: *Parser) ReadError!model.OrcidIdentifier {
    var o = p.open();
    var x: model.OrcidIdentifier = .{};
    while (try p.key(&o)) |k| switch (k) {
        .uri => x.uri = try p.text(),
        .path => x.path = try p.text(),
        .host => x.host = try p.text(),
        else => try p.skip(),
    };
    return x;
}

fn rSource(p: *Parser) ReadError!model.Source {
    var o = p.open();
    var x: model.Source = .{};
    while (try p.key(&o)) |k| switch (k) {
        .@"source-orcid" => x.source_orcid = try p.ident(),
        .@"source-client-id" => x.source_client_id = try p.ident(),
        .@"source-name" => x.source_name = try p.text(),
        .@"assertion-origin-orcid" => x.assertion_origin_orcid = try p.ident(),
        .@"assertion-origin-client-id" => x.assertion_origin_client_id = try p.ident(),
        .@"assertion-origin-name" => x.assertion_origin_name = try p.text(),
        else => try p.skip(),
    };
    return x;
}

fn rDate(p: *Parser) ReadError!model.FuzzyDate {
    var o = p.open();
    var d: model.FuzzyDate = .{};
    while (try p.key(&o)) |k| switch (k) {
        .year => d.year = try p.int32(),
        .month => d.month = try p.int32(),
        .day => d.day = try p.int32(),
        else => try p.skip(),
    };
    return d;
}

fn rOrgAddress(p: *Parser) ReadError!model.OrganizationAddress {
    var o = p.open();
    var x: model.OrganizationAddress = .{};
    while (try p.key(&o)) |k| switch (k) {
        .city => x.city = try p.text(),
        .region => x.region = try p.text(),
        .country => x.country = try p.text(),
        else => try p.skip(),
    };
    return x;
}

fn rDisambiguated(p: *Parser) ReadError!model.DisambiguatedOrganization {
    var o = p.open();
    var x: model.DisambiguatedOrganization = .{};
    while (try p.key(&o)) |k| switch (k) {
        .@"disambiguated-organization-identifier" => x.identifier = try p.text(),
        .@"disambiguation-source" => x.source = try p.text(),
        else => try p.skip(),
    };
    return x;
}

fn rOrg(p: *Parser) ReadError!model.Organization {
    var o = p.open();
    var x: model.Organization = .{};
    while (try p.key(&o)) |k| switch (k) {
        .name => x.name = try p.text(),
        .address => x.address = try p.optObject(model.OrganizationAddress, rOrgAddress),
        .@"disambiguated-organization" => x.disambiguated_organization = try p.optObject(model.DisambiguatedOrganization, rDisambiguated),
        else => try p.skip(),
    };
    return x;
}

fn rTransientError(p: *Parser) ReadError!model.TransientError {
    var o = p.open();
    var x: model.TransientError = .{};
    while (try p.key(&o)) |k| switch (k) {
        .@"error-code" => x.error_code = try p.text(),
        .@"error-message" => x.error_message = try p.text(),
        .transient => x.transient = try p.boolean(),
        else => try p.skip(),
    };
    return x;
}

/// `external-id-normalized`: `{"value": ..., "transient": ...}` or a bare
/// text; null only for `null`.
fn rNormalized(p: *Parser) ReadError!?model.TransientString {
    const v = (try p.valueWith(.transient, bool, Parser.boolean)) orelse return null;
    return .{ .value = v.value, .transient = v.attr };
}

fn rExtId(p: *Parser) ReadError!model.ExternalId {
    var o = p.open();
    var x: model.ExternalId = .{};
    while (try p.key(&o)) |k| switch (k) {
        .@"external-id-type" => x.id_type = try p.text(),
        .@"external-id-value" => x.value = try p.text(),
        .@"external-id-url" => x.url = try p.text(),
        .@"external-id-relationship" => x.relationship = try p.vocab(model.Relationship),
        .@"external-id-normalized" => x.normalized = try rNormalized(p),
        .@"external-id-normalized-error" => x.normalized_error = try p.optObject(model.TransientError, rTransientError),
        else => try metaField(p, &x.meta, k),
    };
    finishMeta(&x.meta);
    return x;
}

fn rTranslatedTitle(p: *Parser) ReadError!?model.TranslatedTitle {
    const v = (try p.valueWith(.@"language-code", Text, Parser.text)) orelse return null;
    return .{ .value = v.value, .language_code = v.attr };
}

fn rTitle(p: *Parser) ReadError!model.Title {
    var o = p.open();
    var x: model.Title = .{};
    while (try p.key(&o)) |k| switch (k) {
        .title => x.title = try p.text(),
        .subtitle => x.subtitle = try p.text(),
        .@"translated-title" => x.translated_title = try rTranslatedTitle(p),
        else => try p.skip(),
    };
    return x;
}

fn rContributorAttributes(p: *Parser) ReadError!model.ContributorAttributes {
    var o = p.open();
    var x: model.ContributorAttributes = .{};
    while (try p.key(&o)) |k| switch (k) {
        .@"contributor-sequence" => x.sequence = try p.vocab(model.ContributorSequence),
        .@"contributor-role" => x.role = try p.vocab(model.ContributorRole),
        else => try p.skip(),
    };
    return x;
}

fn rContributor(p: *Parser) ReadError!model.Contributor {
    var o = p.open();
    var x: model.Contributor = .{};
    while (try p.key(&o)) |k| switch (k) {
        .@"contributor-orcid" => x.contributor_orcid = try p.ident(),
        .@"credit-name" => x.credit_name = try p.text(),
        .@"contributor-email" => x.contributor_email = try p.text(),
        .@"contributor-attributes" => x.attributes = try p.optObject(model.ContributorAttributes, rContributorAttributes),
        else => try p.skip(),
    };
    return x;
}

fn rCitation(p: *Parser) ReadError!model.Citation {
    var o = p.open();
    var x: model.Citation = .{};
    while (try p.key(&o)) |k| switch (k) {
        .@"citation-type" => x.citation_type = try p.vocab(model.CitationType),
        .@"citation-value" => x.citation_value = try p.text(),
        else => try p.skip(),
    };
    return x;
}

/// A work's `country`: `{"value": ..., "visibility": ...}` or a bare text.
fn rCountry(p: *Parser) ReadError!?model.Country {
    const v = (try p.valueWith(.visibility, model.Visibility, Parser.visibility)) orelse return null;
    return .{ .value = v.value, .visibility = v.attr };
}

fn rWork(p: *Parser) ReadError!model.Work {
    var o = p.open();
    var x: model.Work = .{};
    while (try p.key(&o)) |k| switch (k) {
        .title => x.title = try p.title(),
        .@"journal-title" => x.journal_title = try p.text(),
        .@"short-description" => x.short_description = try p.text(),
        .citation => x.citation = try p.optObject(model.Citation, rCitation),
        .type => x.work_type = try p.vocab(model.WorkType),
        .@"publication-date" => x.publication_date = try p.date(),
        .@"external-ids" => x.external_ids = try p.extIds(),
        .url => x.url = try p.text(),
        .contributors => x.contributors = try p.contributors(),
        .@"language-code" => x.language_code = try p.text(),
        .country => x.country = try rCountry(p),
        else => try metaField(p, &x.meta, k),
    };
    finishMeta(&x.meta);
    return x;
}

fn rWorkSummary(p: *Parser) ReadError!model.WorkSummary {
    var o = p.open();
    var x: model.WorkSummary = .{};
    while (try p.key(&o)) |k| switch (k) {
        .title => x.title = try p.title(),
        .@"external-ids" => x.external_ids = try p.extIds(),
        .url => x.url = try p.text(),
        .type => x.work_type = try p.vocab(model.WorkType),
        .@"publication-date" => x.publication_date = try p.date(),
        .@"journal-title" => x.journal_title = try p.text(),
        else => try metaField(p, &x.meta, k),
    };
    finishMeta(&x.meta);
    return x;
}

fn rWorkGroup(p: *Parser) ReadError!model.WorkGroup {
    var o = p.open();
    var g: model.WorkGroup = .{};
    while (try p.key(&o)) |k| switch (k) {
        .@"last-modified-date" => g.last_modified_date = try p.time(),
        .@"external-ids" => g.external_ids = try p.extIds(),
        .@"work-summary" => g.work_summaries = try p.list(model.WorkSummary, rWorkSummary),
        else => try p.skip(),
    };
    return g;
}

fn rWorks(p: *Parser) ReadError!model.Works {
    var o = p.open();
    var x: model.Works = .{};
    while (try p.key(&o)) |k| switch (k) {
        .path => x.path = try p.text(),
        .@"last-modified-date" => x.last_modified_date = try p.time(),
        .group => x.groups = try p.list(model.WorkGroup, rWorkGroup),
        else => try p.skip(),
    };
    return x;
}

fn rAmount(p: *Parser) ReadError!?model.Amount {
    const v = (try p.valueWith(.@"currency-code", Text, Parser.text)) orelse return null;
    return .{ .value = v.value, .currency_code = v.attr };
}

fn rFunding(p: *Parser) ReadError!model.Funding {
    var o = p.open();
    var x: model.Funding = .{};
    while (try p.key(&o)) |k| switch (k) {
        .type => x.funding_type = try p.vocab(model.FundingType),
        .@"organization-defined-type" => x.organization_defined_type = try p.text(),
        .title => x.title = try p.title(),
        .@"short-description" => x.short_description = try p.text(),
        .amount => x.amount = try rAmount(p),
        .url => x.url = try p.text(),
        .@"start-date" => x.start_date = try p.date(),
        .@"end-date" => x.end_date = try p.date(),
        .@"external-ids" => x.external_ids = try p.extIds(),
        .contributors => x.contributors = try p.contributors(),
        .organization => x.organization = try p.org(),
        else => try metaField(p, &x.meta, k),
    };
    finishMeta(&x.meta);
    return x;
}

fn rFundingSummary(p: *Parser) ReadError!model.FundingSummary {
    var o = p.open();
    var x: model.FundingSummary = .{};
    while (try p.key(&o)) |k| switch (k) {
        .title => x.title = try p.title(),
        .@"external-ids" => x.external_ids = try p.extIds(),
        .url => x.url = try p.text(),
        .type => x.funding_type = try p.vocab(model.FundingType),
        .@"start-date" => x.start_date = try p.date(),
        .@"end-date" => x.end_date = try p.date(),
        .organization => x.organization = try p.org(),
        else => try metaField(p, &x.meta, k),
    };
    finishMeta(&x.meta);
    return x;
}

fn rFundingGroup(p: *Parser) ReadError!model.FundingGroup {
    var o = p.open();
    var g: model.FundingGroup = .{};
    while (try p.key(&o)) |k| switch (k) {
        .@"last-modified-date" => g.last_modified_date = try p.time(),
        .@"external-ids" => g.external_ids = try p.extIds(),
        .@"funding-summary" => g.funding_summaries = try p.list(model.FundingSummary, rFundingSummary),
        else => try p.skip(),
    };
    return g;
}

fn rFundings(p: *Parser) ReadError!model.Fundings {
    var o = p.open();
    var x: model.Fundings = .{};
    while (try p.key(&o)) |k| switch (k) {
        .path => x.path = try p.text(),
        .@"last-modified-date" => x.last_modified_date = try p.time(),
        .group => x.groups = try p.list(model.FundingGroup, rFundingGroup),
        else => try p.skip(),
    };
    return x;
}

fn rAffiliation(p: *Parser, kind: model.AffiliationKind) ReadError!model.Affiliation {
    var o = p.open();
    var x: model.Affiliation = .{ .kind = kind };
    while (try p.key(&o)) |k| switch (k) {
        .@"department-name" => x.department_name = try p.text(),
        .@"role-title" => x.role_title = try p.text(),
        .@"start-date" => x.start_date = try p.date(),
        .@"end-date" => x.end_date = try p.date(),
        .organization => x.organization = try p.org(),
        .url => x.url = try p.text(),
        .@"external-ids" => x.external_ids = try p.extIds(),
        else => try metaField(p, &x.meta, k),
    };
    finishMeta(&x.meta);
    return x;
}

fn affiliationOf(comptime kind: model.AffiliationKind) fn (*Parser) ReadError!model.Affiliation {
    return struct {
        fn f(p: *Parser) ReadError!model.Affiliation {
            return rAffiliation(p, kind);
        }
    }.f;
}

/// The kind of a `*-summary` key.
fn summaryKind(k: Key) ?model.AffiliationKind {
    return switch (k) {
        .@"distinction-summary" => .distinction,
        .@"education-summary" => .education,
        .@"employment-summary" => .employment,
        .@"invited-position-summary" => .invited_position,
        .@"membership-summary" => .membership,
        .@"qualification-summary" => .qualification,
        .@"service-summary" => .service,
        else => null,
    };
}

/// The kind of a section container key (`distinctions`, ...).
fn containerKind(k: Key) ?model.AffiliationKind {
    return switch (k) {
        .distinctions => .distinction,
        .educations => .education,
        .employments => .employment,
        .@"invited-positions" => .invited_position,
        .memberships => .membership,
        .qualifications => .qualification,
        .services => .service,
        else => null,
    };
}

/// One `summaries` wrapper (`{"employment-summary": {...}}`): its items go
/// on the stack, in `AffiliationKind.all` order (whatever the key order).
fn rSummaryWrapper(p: *Parser) ReadError!void {
    var o = p.open();
    var per: [model.AffiliationKind.all.len][]const model.Affiliation = @splat(&.{});
    while (try p.key(&o)) |k| {
        const kind = summaryKind(k) orelse {
            try p.skip();
            continue;
        };
        switch (kind) {
            inline else => |kd| per[@backingInt(kd)] = try p.list(model.Affiliation, affiliationOf(kd)),
        }
    }
    for (per) |items| {
        for (items) |*x| try p.push(model.Affiliation, x);
    }
}

/// `summaries`: the wrappers of an array (or a single one), flattened.
fn rSummaries(p: *Parser) ReadError![]const model.Affiliation {
    const mark = p.stack.items.len;
    switch (try p.peek()) {
        '{' => try rSummaryWrapper(p),
        '[' => {
            p.i += 1;
            var a: Arr = .{};
            while (try p.more(&a)) {
                if (try p.peek() == '{') {
                    try rSummaryWrapper(p);
                } else try p.skip();
            }
        },
        else => {
            try p.skip();
            return &.{};
        },
    }
    return p.take(model.Affiliation, mark);
}

fn rAffiliationGroup(p: *Parser) ReadError!model.AffiliationGroup {
    var o = p.open();
    var g: model.AffiliationGroup = .{};
    while (try p.key(&o)) |k| switch (k) {
        .@"last-modified-date" => g.last_modified_date = try p.time(),
        .@"external-ids" => g.external_ids = try p.extIds(),
        .summaries => g.summaries = try rSummaries(p),
        else => try p.skip(),
    };
    return g;
}

fn rAffiliations(p: *Parser, kind: model.AffiliationKind) ReadError!model.Affiliations {
    var o = p.open();
    var x: model.Affiliations = .{ .kind = kind };
    while (try p.key(&o)) |k| switch (k) {
        .path => x.path = try p.text(),
        .@"last-modified-date" => x.last_modified_date = try p.time(),
        .@"affiliation-group" => x.groups = try p.list(model.AffiliationGroup, rAffiliationGroup),
        else => try p.skip(),
    };
    return x;
}

fn optAffiliations(p: *Parser, kind: model.AffiliationKind) ReadError!?model.Affiliations {
    if (try p.peek() != '{') {
        try p.skip();
        return null;
    }
    return try rAffiliations(p, kind);
}

fn rPeerReviewSummary(p: *Parser) ReadError!model.PeerReviewSummary {
    var o = p.open();
    var x: model.PeerReviewSummary = .{};
    while (try p.key(&o)) |k| switch (k) {
        .@"reviewer-role" => x.reviewer_role = try p.vocab(model.PeerReviewRole),
        .@"external-ids" => x.external_ids = try p.extIds(),
        .@"review-url" => x.review_url = try p.text(),
        .@"review-type" => x.review_type = try p.vocab(model.PeerReviewType),
        .@"completion-date" => x.completion_date = try p.date(),
        .@"review-group-id" => x.review_group_id = try p.text(),
        .@"convening-organization" => x.convening_organization = try p.org(),
        else => try metaField(p, &x.meta, k),
    };
    finishMeta(&x.meta);
    return x;
}

fn rPeerReview(p: *Parser) ReadError!model.PeerReview {
    var o = p.open();
    var x: model.PeerReview = .{};
    while (try p.key(&o)) |k| switch (k) {
        .@"reviewer-role" => x.reviewer_role = try p.vocab(model.PeerReviewRole),
        .@"review-identifiers" => x.review_identifiers = try p.extIds(),
        .@"review-url" => x.review_url = try p.text(),
        .@"review-type" => x.review_type = try p.vocab(model.PeerReviewType),
        .@"review-completion-date" => x.review_completion_date = try p.date(),
        .@"review-group-id" => x.review_group_id = try p.text(),
        .@"subject-external-identifier" => x.subject_external_identifier = try p.optObject(model.ExternalId, rExtId),
        .@"subject-container-name" => x.subject_container_name = try p.text(),
        .@"subject-type" => x.subject_type = try p.text(),
        .@"subject-name" => x.subject_name = try p.title(),
        .@"subject-url" => x.subject_url = try p.text(),
        .@"convening-organization" => x.convening_organization = try p.org(),
        else => try metaField(p, &x.meta, k),
    };
    finishMeta(&x.meta);
    return x;
}

fn rPeerReviewDuplicates(p: *Parser) ReadError!model.PeerReviewDuplicates {
    var o = p.open();
    var d: model.PeerReviewDuplicates = .{};
    while (try p.key(&o)) |k| switch (k) {
        .@"last-modified-date" => d.last_modified_date = try p.time(),
        .@"external-ids" => d.external_ids = try p.extIds(),
        .@"peer-review-summary" => d.summaries = try p.list(model.PeerReviewSummary, rPeerReviewSummary),
        else => try p.skip(),
    };
    return d;
}

fn rPeerReviewGroup(p: *Parser) ReadError!model.PeerReviewGroup {
    var o = p.open();
    var g: model.PeerReviewGroup = .{};
    while (try p.key(&o)) |k| switch (k) {
        .@"last-modified-date" => g.last_modified_date = try p.time(),
        .@"external-ids" => g.external_ids = try p.extIds(),
        .@"peer-review-group" => g.duplicates = try p.list(model.PeerReviewDuplicates, rPeerReviewDuplicates),
        else => try p.skip(),
    };
    return g;
}

fn rPeerReviews(p: *Parser) ReadError!model.PeerReviews {
    var o = p.open();
    var x: model.PeerReviews = .{};
    while (try p.key(&o)) |k| switch (k) {
        .path => x.path = try p.text(),
        .@"last-modified-date" => x.last_modified_date = try p.time(),
        .group => x.groups = try p.list(model.PeerReviewGroup, rPeerReviewGroup),
        else => try p.skip(),
    };
    return x;
}

fn rProposal(p: *Parser) ReadError!model.Proposal {
    var o = p.open();
    var x: model.Proposal = .{};
    while (try p.key(&o)) |k| switch (k) {
        .title => x.title = try p.title(),
        .hosts => x.hosts = try p.hosts(),
        .@"external-ids" => x.external_ids = try p.extIds(),
        .@"start-date" => x.start_date = try p.date(),
        .@"end-date" => x.end_date = try p.date(),
        .url => x.url = try p.text(),
        else => try p.skip(),
    };
    return x;
}

fn rResourceItem(p: *Parser) ReadError!model.ResourceItem {
    var o = p.open();
    var x: model.ResourceItem = .{};
    while (try p.key(&o)) |k| switch (k) {
        .@"resource-name" => x.resource_name = try p.text(),
        .@"resource-type" => x.resource_type = try p.vocab(model.ResourceType),
        .hosts => x.hosts = try p.hosts(),
        .@"external-ids" => x.external_ids = try p.extIds(),
        .url => x.url = try p.text(),
        else => try p.skip(),
    };
    return x;
}

fn rResearchResource(p: *Parser) ReadError!model.ResearchResource {
    var o = p.open();
    var x: model.ResearchResource = .{};
    // `resource-item` directly (the samples), then any wrapped in `resource-items`
    var direct: []const model.ResourceItem = &.{};
    var wrapped: []const model.ResourceItem = &.{};
    while (try p.key(&o)) |k| switch (k) {
        .proposal => x.proposal = try p.optObject(model.Proposal, rProposal),
        .@"resource-item" => direct = try p.list(model.ResourceItem, rResourceItem),
        .@"resource-items" => wrapped = try p.wrappedList(.@"resource-item", model.ResourceItem, rResourceItem),
        else => try metaField(p, &x.meta, k),
    };
    finishMeta(&x.meta);
    if (wrapped.len == 0) {
        x.resource_items = direct;
    } else if (direct.len == 0) {
        x.resource_items = wrapped;
    } else {
        const all = try p.mem.alloc(model.ResourceItem, direct.len + wrapped.len);
        @memcpy(all[0..direct.len], direct);
        @memcpy(all[direct.len..], wrapped);
        x.resource_items = all;
    }
    return x;
}

fn rResearchResourceSummary(p: *Parser) ReadError!model.ResearchResourceSummary {
    var o = p.open();
    var x: model.ResearchResourceSummary = .{};
    while (try p.key(&o)) |k| switch (k) {
        .proposal => x.proposal = try p.optObject(model.Proposal, rProposal),
        else => try metaField(p, &x.meta, k),
    };
    finishMeta(&x.meta);
    return x;
}

fn rResearchResourceGroup(p: *Parser) ReadError!model.ResearchResourceGroup {
    var o = p.open();
    var g: model.ResearchResourceGroup = .{};
    while (try p.key(&o)) |k| switch (k) {
        .@"last-modified-date" => g.last_modified_date = try p.time(),
        .@"external-ids" => g.external_ids = try p.extIds(),
        .@"research-resource-summary" => g.summaries = try p.list(model.ResearchResourceSummary, rResearchResourceSummary),
        else => try p.skip(),
    };
    return g;
}

fn rResearchResources(p: *Parser) ReadError!model.ResearchResources {
    var o = p.open();
    var x: model.ResearchResources = .{};
    while (try p.key(&o)) |k| switch (k) {
        .path => x.path = try p.text(),
        .@"last-modified-date" => x.last_modified_date = try p.time(),
        .group => x.groups = try p.list(model.ResearchResourceGroup, rResearchResourceGroup),
        else => try p.skip(),
    };
    return x;
}

fn rActivities(p: *Parser) ReadError!model.ActivitiesSummary {
    var o = p.open();
    var x: model.ActivitiesSummary = .{};
    while (try p.key(&o)) |k| switch (k) {
        .path => x.path = try p.text(),
        .@"last-modified-date" => x.last_modified_date = try p.time(),
        .fundings => x.fundings = try p.optObject(model.Fundings, rFundings),
        .@"peer-reviews" => x.peer_reviews = try p.optObject(model.PeerReviews, rPeerReviews),
        .@"research-resources" => x.research_resources = try p.optObject(model.ResearchResources, rResearchResources),
        .works => x.works = try p.optObject(model.Works, rWorks),
        else => if (containerKind(k)) |kind| {
            x.affiliationsSlot(kind).* = try optAffiliations(p, kind);
        } else try p.skip(),
    };
    return x;
}

fn rName(p: *Parser) ReadError!model.Name {
    var o = p.open();
    var x: model.Name = .{};
    while (try p.key(&o)) |k| switch (k) {
        .visibility => x.visibility = try p.visibility(),
        .path => x.path = try p.text(),
        .@"created-date" => x.created_date = try p.time(),
        .@"last-modified-date" => x.last_modified_date = try p.time(),
        .@"given-names" => x.given_names = try p.text(),
        .@"family-name" => x.family_name = try p.text(),
        .@"credit-name" => x.credit_name = try p.text(),
        else => try p.skip(),
    };
    return x;
}

fn rBiography(p: *Parser) ReadError!model.Biography {
    var o = p.open();
    var x: model.Biography = .{};
    while (try p.key(&o)) |k| switch (k) {
        .visibility => x.visibility = try p.visibility(),
        .path => x.path = try p.text(),
        .@"created-date" => x.created_date = try p.time(),
        .@"last-modified-date" => x.last_modified_date = try p.time(),
        .content => x.content = try p.text(),
        else => try p.skip(),
    };
    return x;
}

fn rOtherName(p: *Parser) ReadError!model.OtherName {
    var o = p.open();
    var x: model.OtherName = .{};
    while (try p.key(&o)) |k| switch (k) {
        .content => x.content = try p.text(),
        else => try metaField(p, &x.meta, k),
    };
    finishMeta(&x.meta);
    return x;
}

fn rResearcherUrl(p: *Parser) ReadError!model.ResearcherUrl {
    var o = p.open();
    var x: model.ResearcherUrl = .{};
    while (try p.key(&o)) |k| switch (k) {
        .@"url-name" => x.url_name = try p.text(),
        .url => x.url = try p.text(),
        else => try metaField(p, &x.meta, k),
    };
    finishMeta(&x.meta);
    return x;
}

fn rEmail(p: *Parser) ReadError!model.Email {
    var o = p.open();
    var x: model.Email = .{};
    while (try p.key(&o)) |k| switch (k) {
        .email => x.email = try p.text(),
        .verified => x.verified = try p.boolean(),
        .primary => x.primary = try p.boolean(),
        else => try metaField(p, &x.meta, k),
    };
    finishMeta(&x.meta);
    return x;
}

fn rAddress(p: *Parser) ReadError!model.Address {
    var o = p.open();
    var x: model.Address = .{};
    while (try p.key(&o)) |k| switch (k) {
        .country => x.country = try p.text(),
        else => try metaField(p, &x.meta, k),
    };
    finishMeta(&x.meta);
    return x;
}

fn rKeyword(p: *Parser) ReadError!model.Keyword {
    var o = p.open();
    var x: model.Keyword = .{};
    while (try p.key(&o)) |k| switch (k) {
        .content => x.content = try p.text(),
        else => try metaField(p, &x.meta, k),
    };
    finishMeta(&x.meta);
    return x;
}

/// A person item container: `path`, `last-modified-date` and the items
/// under `item_key`.
fn rItemList(p: *Parser, comptime T: type, comptime item_key: Key, comptime item: fn (*Parser) ReadError!T) ReadError!model.ItemList(T) {
    var o = p.open();
    var x: model.ItemList(T) = .{};
    while (try p.key(&o)) |k| {
        if (k == item_key) {
            x.items = try p.list(T, item);
            continue;
        }
        switch (k) {
            .path => x.path = try p.text(),
            .@"last-modified-date" => x.last_modified_date = try p.time(),
            else => try p.skip(),
        }
    }
    return x;
}

fn itemListOf(comptime T: type, comptime item_key: Key, comptime item: fn (*Parser) ReadError!T) fn (*Parser) ReadError!model.ItemList(T) {
    return struct {
        fn f(p: *Parser) ReadError!model.ItemList(T) {
            return rItemList(p, T, item_key, item);
        }
    }.f;
}

const rOtherNames = itemListOf(model.OtherName, .@"other-name", rOtherName);
const rResearcherUrls = itemListOf(model.ResearcherUrl, .@"researcher-url", rResearcherUrl);
const rEmails = itemListOf(model.Email, .email, rEmail);
const rAddresses = itemListOf(model.Address, .address, rAddress);
const rKeywords = itemListOf(model.Keyword, .keyword, rKeyword);
const rExternalIdentifiers = itemListOf(model.ExternalId, .@"external-identifier", rExtId);

fn rPerson(p: *Parser) ReadError!model.Person {
    var o = p.open();
    var x: model.Person = .{};
    while (try p.key(&o)) |k| switch (k) {
        .path => x.path = try p.text(),
        .@"last-modified-date" => x.last_modified_date = try p.time(),
        .name => x.name = try p.optObject(model.Name, rName),
        .@"other-names" => x.other_names = try p.optObject(model.OtherNames, rOtherNames),
        .biography => x.biography = try p.optObject(model.Biography, rBiography),
        .@"researcher-urls" => x.researcher_urls = try p.optObject(model.ResearcherUrls, rResearcherUrls),
        .emails => x.emails = try p.optObject(model.Emails, rEmails),
        .addresses => x.addresses = try p.optObject(model.Addresses, rAddresses),
        .keywords => x.keywords = try p.optObject(model.Keywords, rKeywords),
        .@"external-identifiers" => x.external_identifiers = try p.optObject(model.ExternalIdentifiers, rExternalIdentifiers),
        else => try p.skip(),
    };
    return x;
}

fn rPersonalDetails(p: *Parser) ReadError!model.PersonalDetails {
    var o = p.open();
    var x: model.PersonalDetails = .{};
    while (try p.key(&o)) |k| switch (k) {
        .path => x.path = try p.text(),
        .@"last-modified-date" => x.last_modified_date = try p.time(),
        .name => x.name = try p.optObject(model.Name, rName),
        .@"other-names" => x.other_names = try p.optObject(model.OtherNames, rOtherNames),
        .biography => x.biography = try p.optObject(model.Biography, rBiography),
        else => try p.skip(),
    };
    return x;
}

const java_creation_methods = [_]struct { []const u8, model.CreationMethod.Known }{
    .{ "API", .API },
    .{ "DIRECT", .Direct },
    .{ "MEMBER_REFERRED", .@"Member-referred" },
    .{ "WEBSITE", .website },
};

/// `creation-method`: ORCID's Java enum names, or the XML text.
fn rCreationMethod(p: *Parser) ReadError!?model.CreationMethod {
    const t = (try p.scalarView()) orelse return null;
    for (java_creation_methods) |m| {
        if (std.mem.eql(u8, t, m[0])) return .{ .known = m[1] };
    }
    return switch (model.CreationMethod.parse(t)) {
        .known => |k| .{ .known = k },
        .other => .{ .other = try p.mem.dupe(t) },
    };
}

fn creationMethodToJson(m: model.CreationMethod) Text {
    return switch (m) {
        .known => |k| for (java_creation_methods) |j| {
            if (j[1] == k) break j[0];
        } else unreachable,
        .other => |s| s,
    };
}

/// Reads `path` into `root_path` when given (a document root), else skips it.
fn rootPath(p: *Parser, root_path: ?*?Text) ReadError!void {
    if (root_path) |rp| {
        rp.* = try p.text();
    } else try p.skip();
}

fn rHistory(p: *Parser, root_path: ?*?Text) ReadError!model.History {
    var o = p.open();
    var x: model.History = .{};
    while (try p.key(&o)) |k| switch (k) {
        .visibility => x.visibility = try p.visibility(),
        .@"creation-method" => x.creation_method = try rCreationMethod(p),
        .@"completion-date" => x.completion_date = try p.time(),
        .@"submission-date" => x.submission_date = try p.time(),
        .@"last-modified-date" => x.last_modified_date = try p.time(),
        .claimed => x.claimed = try p.boolean(),
        .source => x.source = try p.optObject(model.Source, rSource),
        .@"deactivation-date" => x.deactivation_date = try p.time(),
        .@"verified-email" => x.verified_email = try p.boolean(),
        .@"verified-primary-email" => x.verified_primary_email = try p.boolean(),
        .path => try rootPath(p, root_path),
        else => try p.skip(),
    };
    return x;
}

fn rHistoryItem(p: *Parser) ReadError!model.History {
    return rHistory(p, null);
}

fn rPreferences(p: *Parser, root_path: ?*?Text) ReadError!model.Preferences {
    var o = p.open();
    var x: model.Preferences = .{};
    while (try p.key(&o)) |k| switch (k) {
        .locale => x.locale = try p.text(),
        .path => try rootPath(p, root_path),
        else => try p.skip(),
    };
    return x;
}

fn rPreferencesItem(p: *Parser) ReadError!model.Preferences {
    return rPreferences(p, null);
}

fn rRecord(p: *Parser) ReadError!model.Record {
    var o = p.open();
    var x: model.Record = .{};
    while (try p.key(&o)) |k| switch (k) {
        .path => x.path = try p.text(),
        .@"orcid-identifier" => x.orcid_identifier = try p.ident(),
        .preferences => x.preferences = try p.optObject(model.Preferences, rPreferencesItem),
        .history => x.history = try p.optObject(model.History, rHistoryItem),
        .person => x.person = try p.optObject(model.Person, rPerson),
        .@"activities-summary" => x.activities_summary = try p.optObject(model.ActivitiesSummary, rActivities),
        else => try p.skip(),
    };
    return x;
}

fn rError(p: *Parser, root_path: ?*?Text) ReadError!model.OrcidError {
    var o = p.open();
    var x: model.OrcidError = .{};
    while (try p.key(&o)) |k| switch (k) {
        .@"response-code" => x.response_code = try p.signed(),
        .@"developer-message" => x.developer_message = try p.text(),
        .@"user-message" => x.user_message = try p.text(),
        .@"error-code" => x.error_code = try p.signed(),
        .@"more-info" => x.more_info = try p.text(),
        .path => try rootPath(p, root_path),
        else => try p.skip(),
    };
    return x;
}

fn rErrorItem(p: *Parser) ReadError!model.OrcidError {
    return rError(p, null);
}

/// A bulk entry: its `work` if that is an object, else its `error` if that
/// is one; dropped otherwise.
fn rBulkItem(p: *Parser) ReadError!?model.BulkItem {
    var o = p.open();
    var work: ?model.Work = null;
    var err: ?model.OrcidError = null;
    while (try p.key(&o)) |k| switch (k) {
        .work => work = try p.optObject(model.Work, rWork),
        .@"error" => err = try p.optObject(model.OrcidError, rErrorItem),
        else => try p.skip(),
    };
    if (work) |w| return .{ .work = w };
    if (err) |e| return .{ .@"error" = e };
    return null;
}

fn rBulk(p: *Parser, root_path: *?Text) ReadError!model.Bulk {
    var o = p.open();
    var x: model.Bulk = .{};
    while (try p.key(&o)) |k| switch (k) {
        .bulk => x.items = try p.listSome(model.BulkItem, rBulkItem),
        .path => try rootPath(p, root_path),
        else => try p.skip(),
    };
    return x;
}

/// A search result's `orcid-identifier`; dropped if it is not an object.
fn rSearchResult(p: *Parser) ReadError!?model.OrcidIdentifier {
    var o = p.open();
    var id: ?model.OrcidIdentifier = null;
    while (try p.key(&o)) |k| switch (k) {
        .@"orcid-identifier" => id = try p.ident(),
        else => try p.skip(),
    };
    return id;
}

fn rSearch(p: *Parser, root_path: *?Text) ReadError!model.Search {
    var o = p.open();
    var x: model.Search = .{};
    while (try p.key(&o)) |k| switch (k) {
        .@"num-found" => x.num_found = try p.signed(),
        .result => x.results = try p.listSome(model.OrcidIdentifier, rSearchResult),
        .path => try rootPath(p, root_path),
        else => try p.skip(),
    };
    return x;
}

fn rExpandedResult(p: *Parser) ReadError!model.ExpandedResult {
    var o = p.open();
    var x: model.ExpandedResult = .{};
    while (try p.key(&o)) |k| switch (k) {
        .@"orcid-id" => x.orcid_id = try p.text(),
        .@"given-names" => x.given_names = try p.text(),
        .@"family-names" => x.family_names = try p.text(),
        .@"credit-name" => x.credit_name = try p.text(),
        .@"other-name" => x.other_names = try p.strings(),
        .email => x.emails = try p.strings(),
        .@"institution-name" => x.institution_names = try p.strings(),
        else => try p.skip(),
    };
    return x;
}

fn rExpandedSearch(p: *Parser, root_path: *?Text) ReadError!model.ExpandedSearch {
    var o = p.open();
    var x: model.ExpandedSearch = .{};
    while (try p.key(&o)) |k| switch (k) {
        .@"num-found" => x.num_found = try p.signed(),
        .@"expanded-result" => x.results = try p.list(model.ExpandedResult, rExpandedResult),
        .path => try rootPath(p, root_path),
        else => try p.skip(),
    };
    return x;
}

fn keyIs(name: []const u8, want: []const u8) bool {
    return std.mem.eql(u8, name, want);
}

/// `group-id-record`: `source`, or the inline source keys of the XSD's
/// common-2.1 `source-type` (`source-orcid`, `source-client-id`,
/// `source-name`), which fill what `source` leaves empty (yorc-rs's
/// `r_group_id_record`).
fn rGroupIdRecord(p: *Parser, root_path: ?*?Text) ReadError!model.GroupIdRecord {
    var o = p.open();
    var x: model.GroupIdRecord = .{};
    var inline_orcid: ?model.OrcidIdentifier = null;
    var inline_client: ?model.OrcidIdentifier = null;
    var inline_name: ?Text = null;
    while (try p.keyName(&o)) |k| {
        if (keyIs(k, "put-code")) {
            x.put_code = try p.digits(18);
        } else if (keyIs(k, "created-date")) {
            x.created_date = try p.time();
        } else if (keyIs(k, "last-modified-date")) {
            x.last_modified_date = try p.time();
        } else if (keyIs(k, "name")) {
            x.name = try p.text();
        } else if (keyIs(k, "group-id")) {
            x.group_id = try p.text();
        } else if (keyIs(k, "description")) {
            x.description = try p.text();
        } else if (keyIs(k, "type")) {
            x.group_type = try p.vocab(model.GroupType);
        } else if (keyIs(k, "source")) {
            x.source = try p.optObject(model.Source, rSource);
        } else if (keyIs(k, "source-orcid")) {
            inline_orcid = try p.ident();
        } else if (keyIs(k, "source-client-id")) {
            inline_client = try p.ident();
        } else if (keyIs(k, "source-name")) {
            inline_name = try p.text();
        } else if (keyIs(k, "path")) {
            try rootPath(p, root_path);
        } else try p.skip();
    }
    if (inline_orcid != null or inline_client != null or inline_name != null) {
        if (x.source == null) x.source = .{};
        const src = &x.source.?;
        if (src.source_orcid == null) src.source_orcid = inline_orcid;
        if (src.source_client_id == null) src.source_client_id = inline_client;
        if (src.source_name == null) src.source_name = inline_name;
    }
    return x;
}

fn rGroupIdRecordItem(p: *Parser) ReadError!model.GroupIdRecord {
    return rGroupIdRecord(p, null);
}

fn rGroupIdRecords(p: *Parser, root_path: *?Text) ReadError!model.GroupIdRecords {
    var o = p.open();
    var x: model.GroupIdRecords = .{};
    while (try p.keyName(&o)) |k| {
        if (keyIs(k, "last-modified-date")) {
            x.last_modified_date = try p.time();
        } else if (keyIs(k, "total")) {
            x.total = try p.digits(9);
        } else if (keyIs(k, "page")) {
            x.page = try p.digits(9);
        } else if (keyIs(k, "page-size")) {
            x.page_size = try p.digits(9);
        } else if (keyIs(k, "group-id-record")) {
            x.records = try p.list(model.GroupIdRecord, rGroupIdRecordItem);
        } else if (keyIs(k, "path")) {
            try rootPath(p, root_path);
        } else try p.skip();
    }
    return x;
}

/// `credit-name` documents: `{"value": ...}` (and `path`).
fn rCreditName(p: *Parser, root_path: *?Text) ReadError!?Text {
    var o = p.open();
    var x: ?Text = null;
    while (try p.key(&o)) |k| switch (k) {
        .value => x = try p.text(),
        .path => try rootPath(p, root_path),
        else => try p.skip(),
    };
    return x;
}

/// The root of a document of `kind` (the cursor at its `{`, not consumed if
/// the kind is unknown) and its `path`.
fn readRoot(p: *Parser, kind: []const u8) ReadError!?Rooted {
    const eq = struct {
        fn f(x: []const u8, y: []const u8) bool {
            return std.mem.eql(u8, x, y);
        }
    }.f;
    var path: ?Text = null;
    if (eq(kind, "record")) {
        const x = try rRecord(p);
        return .{ .root = .{ .record = x }, .path = x.path };
    }
    if (eq(kind, "activities-summary")) {
        const x = try rActivities(p);
        return .{ .root = .{ .activities_summary = x }, .path = x.path };
    }
    if (eq(kind, "works")) {
        const x = try rWorks(p);
        return .{ .root = .{ .works = x }, .path = x.path };
    }
    if (eq(kind, "work")) {
        const x = try rWork(p);
        return .{ .root = .{ .work = x }, .path = x.meta.path };
    }
    if (eq(kind, "work-summary")) {
        const x = try rWorkSummary(p);
        return .{ .root = .{ .work_summary = x }, .path = x.meta.path };
    }
    if (eq(kind, "fundings")) {
        const x = try rFundings(p);
        return .{ .root = .{ .fundings = x }, .path = x.path };
    }
    if (eq(kind, "funding")) {
        const x = try rFunding(p);
        return .{ .root = .{ .funding = x }, .path = x.meta.path };
    }
    if (eq(kind, "funding-summary")) {
        const x = try rFundingSummary(p);
        return .{ .root = .{ .funding_summary = x }, .path = x.meta.path };
    }
    if (eq(kind, "peer-reviews")) {
        const x = try rPeerReviews(p);
        return .{ .root = .{ .peer_reviews = x }, .path = x.path };
    }
    if (eq(kind, "peer-review")) {
        const x = try rPeerReview(p);
        return .{ .root = .{ .peer_review = x }, .path = x.meta.path };
    }
    if (eq(kind, "peer-review-summary")) {
        const x = try rPeerReviewSummary(p);
        return .{ .root = .{ .peer_review_summary = x }, .path = x.meta.path };
    }
    if (eq(kind, "research-resources")) {
        const x = try rResearchResources(p);
        return .{ .root = .{ .research_resources = x }, .path = x.path };
    }
    if (eq(kind, "research-resource")) {
        const x = try rResearchResource(p);
        return .{ .root = .{ .research_resource = x }, .path = x.meta.path };
    }
    if (eq(kind, "research-resource-summary")) {
        const x = try rResearchResourceSummary(p);
        return .{ .root = .{ .research_resource_summary = x }, .path = x.meta.path };
    }
    if (eq(kind, "person")) {
        const x = try rPerson(p);
        return .{ .root = .{ .person = x }, .path = x.path };
    }
    if (eq(kind, "personal-details")) {
        const x = try rPersonalDetails(p);
        return .{ .root = .{ .personal_details = x }, .path = x.path };
    }
    if (eq(kind, "name")) {
        const x = try rName(p);
        return .{ .root = .{ .name = x }, .path = x.path };
    }
    if (eq(kind, "biography")) {
        const x = try rBiography(p);
        return .{ .root = .{ .biography = x }, .path = x.path };
    }
    if (eq(kind, "credit-name")) {
        const x = try rCreditName(p, &path);
        return .{ .root = .{ .credit_name = x }, .path = path };
    }
    if (eq(kind, "other-names")) {
        const x = try rOtherNames(p);
        return .{ .root = .{ .other_names = x }, .path = x.path };
    }
    if (eq(kind, "other-name")) {
        const x = try rOtherName(p);
        return .{ .root = .{ .other_name = x }, .path = x.meta.path };
    }
    if (eq(kind, "researcher-urls")) {
        const x = try rResearcherUrls(p);
        return .{ .root = .{ .researcher_urls = x }, .path = x.path };
    }
    if (eq(kind, "researcher-url")) {
        const x = try rResearcherUrl(p);
        return .{ .root = .{ .researcher_url = x }, .path = x.meta.path };
    }
    if (eq(kind, "emails")) {
        const x = try rEmails(p);
        return .{ .root = .{ .emails = x }, .path = x.path };
    }
    if (eq(kind, "email")) {
        const x = try rEmail(p);
        return .{ .root = .{ .email = x }, .path = x.meta.path };
    }
    if (eq(kind, "addresses")) {
        const x = try rAddresses(p);
        return .{ .root = .{ .addresses = x }, .path = x.path };
    }
    if (eq(kind, "address")) {
        const x = try rAddress(p);
        return .{ .root = .{ .address = x }, .path = x.meta.path };
    }
    if (eq(kind, "keywords")) {
        const x = try rKeywords(p);
        return .{ .root = .{ .keywords = x }, .path = x.path };
    }
    if (eq(kind, "keyword")) {
        const x = try rKeyword(p);
        return .{ .root = .{ .keyword = x }, .path = x.meta.path };
    }
    if (eq(kind, "external-identifiers")) {
        const x = try rExternalIdentifiers(p);
        return .{ .root = .{ .external_identifiers = x }, .path = x.path };
    }
    if (eq(kind, "external-identifier")) {
        const x = try rExtId(p);
        return .{ .root = .{ .external_identifier = x }, .path = x.meta.path };
    }
    if (eq(kind, "history")) {
        const x = try rHistory(p, &path);
        return .{ .root = .{ .history = x }, .path = path };
    }
    if (eq(kind, "preferences")) {
        const x = try rPreferences(p, &path);
        return .{ .root = .{ .preferences = x }, .path = path };
    }
    if (eq(kind, "bulk")) {
        const x = try rBulk(p, &path);
        return .{ .root = .{ .bulk = x }, .path = path };
    }
    if (eq(kind, "error")) {
        const x = try rError(p, &path);
        return .{ .root = .{ .@"error" = x }, .path = path };
    }
    if (eq(kind, "search")) {
        const x = try rSearch(p, &path);
        return .{ .root = .{ .search = x }, .path = path };
    }
    if (eq(kind, "expanded-search")) {
        const x = try rExpandedSearch(p, &path);
        return .{ .root = .{ .expanded_search = x }, .path = path };
    }
    if (eq(kind, "group-id-record")) {
        const x = try rGroupIdRecord(p, &path);
        return .{ .root = .{ .group_id_record = x }, .path = path };
    }
    if (eq(kind, "group-id-records")) {
        const x = try rGroupIdRecords(p, &path);
        return .{ .root = .{ .group_id_records = x }, .path = path };
    }
    if (model.AffiliationKind.fromContainerElement(kind)) |k| {
        const x = try rAffiliations(p, k);
        return .{ .root = .{ .affiliations = x }, .path = x.path };
    }
    if (model.AffiliationKind.fromElement(kind)) |k| {
        const x = try rAffiliation(p, k);
        return .{ .root = .{ .affiliation = x }, .path = x.meta.path };
    }
    if (model.AffiliationKind.fromSummaryElement(kind)) |k| {
        const x = try rAffiliation(p, k);
        return .{ .root = .{ .affiliation_summary = x }, .path = x.meta.path };
    }
    return null;
}

// =================================================================== writing

/// A JSON value being written.
const J = union(enum) {
    obj: []const Field,
    arr: []const J,
    str: []const u8,
    int: i64,
    boolean: bool,
};

const Field = struct { key: []const u8, val: J };

pub const WriteError = error{ Unwritable, WriteFailed, OutOfMemory };

/// Write builder for one JSON object.
const W = struct {
    a: Allocator,
    fields: std.ArrayList(Field) = .empty,
    path: []const u8,
    diag: ?*Diagnostic,

    fn init(ctx: *const Ctx, path: []const u8) W {
        return .{ .a = ctx.a, .path = path, .diag = ctx.diag };
    }

    fn at(w: *const W, k: []const u8) OOM![]const u8 {
        return std.fmt.allocPrint(w.a, "{s}/{s}", .{ w.path, k });
    }

    fn put(w: *W, k: []const u8, val: J) WriteError!void {
        for (w.fields.items) |*f| {
            if (std.mem.eql(u8, f.key, k)) {
                f.val = val;
                return;
            }
        }
        try w.fields.append(w.a, .{ .key = k, .val = val });
    }

    fn checked(w: *W, k: []const u8, text: []const u8) WriteError!J {
        if (!utf8.isValid(text)) {
            if (w.diag) |d| {
                d.setPath(try w.at(k));
                d.message = "not valid UTF-8";
                d.code_point = 0xFFFD;
            }
            return error.Unwritable;
        }
        return .{ .str = text };
    }

    /// Bare string.
    fn bare(w: *W, k: []const u8, val: ?Text) WriteError!void {
        const x = val orelse return;
        try w.put(k, try w.checked(k, x));
    }

    /// `{"value": "..."}`.
    fn wrapped(w: *W, k: []const u8, val: ?Text) WriteError!void {
        const x = val orelse return;
        const f = try w.a.alloc(Field, 1);
        f[0] = .{ .key = "value", .val = try w.checked(k, x) };
        try w.put(k, .{ .obj = f });
    }

    /// `{"value": <epoch ms>}`.
    fn timestamp(w: *W, k: []const u8, val: ?Text) WriteError!void {
        const x = val orelse return;
        const ms = datetimeToMillis(x) orelse {
            if (w.diag) |d| {
                d.setPath(try w.at(k));
                d.message = "not an xs:dateTime";
                d.code_point = null;
            }
            return error.Unwritable;
        };
        const f = try w.a.alloc(Field, 1);
        f[0] = .{ .key = "value", .val = .{ .int = ms } };
        try w.put(k, .{ .obj = f });
    }

    fn boolean(w: *W, k: []const u8, val: ?bool) WriteError!void {
        try w.put(k, .{ .boolean = val orelse return });
    }

    fn int(w: *W, k: []const u8, val: ?i64) WriteError!void {
        try w.put(k, .{ .int = val orelse return });
    }

    /// A vocabulary value as a bare string.
    fn vocab(w: *W, k: []const u8, val: anytype) WriteError!void {
        const x = val orelse return;
        try w.bare(k, x.text());
    }

    fn obj(w: *W, k: []const u8, val: ?J) WriteError!void {
        try w.put(k, val orelse return);
    }

    fn arr(w: *W, k: []const u8, items: []const J) WriteError!void {
        try w.put(k, .{ .arr = items });
    }

    fn done(w: *W) J {
        return .{ .obj = w.fields.items };
    }
};

const Ctx = struct {
    a: Allocator,
    diag: ?*Diagnostic,

    fn path(c: *const Ctx, comptime f: []const u8, args: anytype) OOM![]const u8 {
        return std.fmt.allocPrint(c.a, f, args);
    }
};

fn wMeta(w: *W, m: *const model.ItemMeta) WriteError!void {
    try w.int("put-code", m.put_code);
    try w.bare("path", m.path);
    try w.vocab("visibility", m.visibility);
    if (m.display_index_text) |txt| {
        try w.bare("display-index", txt);
    } else if (m.display_index) |i| {
        try w.int("display-index", i);
    }
    try w.timestamp("created-date", m.created_date);
    try w.timestamp("last-modified-date", m.last_modified_date);
    if (m.source) |*src| try w.obj("source", try wSource(w, try w.at("source"), src));
}

fn wIdent(w: *const W, i: *const model.OrcidIdentifier) WriteError!J {
    var x: W = .{ .a = w.a, .path = "", .diag = w.diag };
    try x.bare("uri", i.uri);
    try x.bare("path", i.path);
    try x.bare("host", i.host);
    return x.done();
}

fn optIdentJ(w: *const W, i: *const ?model.OrcidIdentifier) WriteError!?J {
    return if (i.*) |*x| try wIdent(w, x) else null;
}

fn wSource(parent: *const W, path: []const u8, s: *const model.Source) WriteError!J {
    var w: W = .{ .a = parent.a, .path = path, .diag = parent.diag };
    try w.obj("source-orcid", try optIdentJ(&w, &s.source_orcid));
    try w.obj("source-client-id", try optIdentJ(&w, &s.source_client_id));
    try w.wrapped("source-name", s.source_name);
    try w.obj("assertion-origin-orcid", try optIdentJ(&w, &s.assertion_origin_orcid));
    try w.obj("assertion-origin-client-id", try optIdentJ(&w, &s.assertion_origin_client_id));
    try w.wrapped("assertion-origin-name", s.assertion_origin_name);
    return w.done();
}

fn wDate(parent: *const W, d: ?model.FuzzyDate) WriteError!?J {
    const x = d orelse return null;
    var w: W = .{ .a = parent.a, .path = "", .diag = parent.diag };
    var buf: [24]u8 = undefined;
    if (x.year) |y| try w.wrapped("year", try w.a.dupe(u8, padInt(&buf, y, 4)));
    if (x.month) |m| try w.wrapped("month", try w.a.dupe(u8, padInt(&buf, m, 2)));
    if (x.day) |day| try w.wrapped("day", try w.a.dupe(u8, padInt(&buf, day, 2)));
    return w.done();
}

fn wOrg(parent: *const W, org: *const model.Organization) WriteError!J {
    var w: W = .{ .a = parent.a, .path = "", .diag = parent.diag };
    try w.bare("name", org.name);
    if (org.address) |*ad| {
        var x: W = .{ .a = parent.a, .path = "", .diag = parent.diag };
        try x.bare("city", ad.city);
        try x.bare("region", ad.region);
        try x.bare("country", ad.country);
        try w.obj("address", x.done());
    }
    if (org.disambiguated_organization) |*d| {
        var x: W = .{ .a = parent.a, .path = "", .diag = parent.diag };
        try x.bare("disambiguated-organization-identifier", d.identifier);
        try x.bare("disambiguation-source", d.source);
        try w.obj("disambiguated-organization", x.done());
    }
    return w.done();
}

fn optOrgJ(w: *const W, org: *const ?model.Organization) WriteError!?J {
    return if (org.*) |*x| try wOrg(w, x) else null;
}

fn wExtId(parent: *const W, path: []const u8, x: *const model.ExternalId) WriteError!J {
    var w: W = .{ .a = parent.a, .path = path, .diag = parent.diag };
    try wMeta(&w, &x.meta);
    try w.bare("external-id-type", x.id_type);
    try w.bare("external-id-value", x.value);
    if (x.normalized) |*nz| {
        var nw: W = .{ .a = parent.a, .path = "", .diag = parent.diag };
        try nw.bare("value", nz.value);
        try nw.boolean("transient", nz.transient);
        try w.obj("external-id-normalized", nw.done());
    }
    if (x.normalized_error) |*er| {
        var ew: W = .{ .a = parent.a, .path = "", .diag = parent.diag };
        try ew.bare("error-code", er.error_code);
        try ew.bare("error-message", er.error_message);
        try ew.boolean("transient", er.transient);
        try w.obj("external-id-normalized-error", ew.done());
    }
    try w.wrapped("external-id-url", x.url);
    try w.vocab("external-id-relationship", x.relationship);
    return w.done();
}

/// `{"external-id": [...]}`.
fn wExtIds(parent: *const W, path: []const u8, ids: []const model.ExternalId) WriteError!J {
    var w: W = .{ .a = parent.a, .path = path, .diag = parent.diag };
    const items = try w.a.alloc(J, ids.len);
    for (ids, items, 0..) |*x, *it, i| {
        it.* = try wExtId(&w, try std.fmt.allocPrint(w.a, "{s}/external-id[{d}]", .{ path, i + 1 }), x);
    }
    try w.arr("external-id", items);
    return w.done();
}

fn optExtIds(w: *W, k: []const u8, ids: []const model.ExternalId) WriteError!void {
    if (ids.len > 0) try w.obj(k, try wExtIds(w, try w.at(k), ids));
}

fn reqExtIds(w: *W, k: []const u8, ids: []const model.ExternalId) WriteError!void {
    try w.obj(k, try wExtIds(w, try w.at(k), ids));
}

fn wTitle(parent: *const W, title: ?model.Title) WriteError!?J {
    const ti = title orelse return null;
    var w: W = .{ .a = parent.a, .path = "", .diag = parent.diag };
    try w.wrapped("title", ti.title);
    try w.wrapped("subtitle", ti.subtitle);
    if (ti.translated_title) |tt| {
        var x: W = .{ .a = parent.a, .path = "", .diag = parent.diag };
        try x.bare("value", tt.value);
        try x.bare("language-code", tt.language_code);
        try w.obj("translated-title", x.done());
    }
    return w.done();
}

fn wContributors(w: *W, cs: []const model.Contributor) WriteError!void {
    if (cs.len == 0) return;
    const items = try w.a.alloc(J, cs.len);
    for (cs, items) |*c, *it| {
        var cw: W = .{ .a = w.a, .path = "", .diag = w.diag };
        try cw.obj("contributor-orcid", try optIdentJ(&cw, &c.contributor_orcid));
        try cw.wrapped("credit-name", c.credit_name);
        try cw.bare("contributor-email", c.contributor_email);
        if (c.attributes) |at| {
            var aw: W = .{ .a = w.a, .path = "", .diag = w.diag };
            try aw.vocab("contributor-sequence", at.sequence);
            try aw.vocab("contributor-role", at.role);
            try cw.obj("contributor-attributes", aw.done());
        }
        it.* = cw.done();
    }
    var list: W = .{ .a = w.a, .path = "", .diag = w.diag };
    try list.arr("contributor", items);
    try w.obj("contributors", list.done());
}

fn wWork(ctx: *const Ctx, path: []const u8, x: *const model.Work) WriteError!J {
    var w = W.init(ctx, path);
    try wMeta(&w, &x.meta);
    try w.obj("title", try wTitle(&w, x.title));
    try w.wrapped("journal-title", x.journal_title);
    try w.bare("short-description", x.short_description);
    if (x.citation) |c| {
        var cw = W.init(ctx, "");
        try cw.vocab("citation-type", c.citation_type);
        try cw.bare("citation-value", c.citation_value);
        try w.obj("citation", cw.done());
    }
    try w.vocab("type", x.work_type);
    try w.obj("publication-date", try wDate(&w, x.publication_date));
    try optExtIds(&w, "external-ids", x.external_ids);
    try w.wrapped("url", x.url);
    try wContributors(&w, x.contributors);
    try w.bare("language-code", x.language_code);
    if (x.country) |c| {
        var cw = W.init(ctx, "");
        try cw.bare("value", c.value);
        // country/@visibility is XML-only, like history/@visibility (yorc-rs)
        try w.obj("country", cw.done());
    }
    return w.done();
}

fn wWorkSummary(ctx: *const Ctx, path: []const u8, x: *const model.WorkSummary) WriteError!J {
    var w = W.init(ctx, path);
    try wMeta(&w, &x.meta);
    try w.obj("title", try wTitle(&w, x.title));
    try optExtIds(&w, "external-ids", x.external_ids);
    try w.wrapped("url", x.url);
    try w.vocab("type", x.work_type);
    try w.obj("publication-date", try wDate(&w, x.publication_date));
    try w.wrapped("journal-title", x.journal_title);
    return w.done();
}

/// A container: `path`, `last-modified-date`.
fn wContainer(ctx: *const Ctx, path: []const u8, p: ?Text, lmd: ?Text) WriteError!W {
    var w = W.init(ctx, path);
    try w.bare("path", p);
    try w.timestamp("last-modified-date", lmd);
    return w;
}

/// A group: `last-modified-date`, `external-ids` (always).
fn wGroup(ctx: *const Ctx, path: []const u8, lmd: ?Text, ids: []const model.ExternalId) WriteError!W {
    var w = W.init(ctx, path);
    try w.timestamp("last-modified-date", lmd);
    try reqExtIds(&w, "external-ids", ids);
    return w;
}

fn wWorks(ctx: *const Ctx, path: []const u8, x: *const model.Works) WriteError!J {
    var w = try wContainer(ctx, path, x.path, x.last_modified_date);
    const groups = try ctx.a.alloc(J, x.groups.len);
    for (x.groups, groups, 0..) |*g, *gj, i| {
        const gp = try ctx.path("{s}/group[{d}]", .{ path, i + 1 });
        var gw = try wGroup(ctx, gp, g.last_modified_date, g.external_ids);
        const items = try ctx.a.alloc(J, g.work_summaries.len);
        const sp = try ctx.path("{s}/work-summary", .{gp});
        for (g.work_summaries, items) |*s, *it| it.* = try wWorkSummary(ctx, sp, s);
        try gw.arr("work-summary", items);
        gj.* = gw.done();
    }
    try w.arr("group", groups);
    return w.done();
}

fn wAmount(ctx: *const Ctx, am: ?model.Amount) WriteError!?J {
    const x = am orelse return null;
    var w = W.init(ctx, "");
    try w.bare("value", x.value);
    try w.bare("currency-code", x.currency_code);
    return w.done();
}

fn wFunding(ctx: *const Ctx, path: []const u8, x: *const model.Funding) WriteError!J {
    var w = W.init(ctx, path);
    try wMeta(&w, &x.meta);
    try w.vocab("type", x.funding_type);
    try w.wrapped("organization-defined-type", x.organization_defined_type);
    try w.obj("title", try wTitle(&w, x.title));
    try w.bare("short-description", x.short_description);
    try w.obj("amount", try wAmount(ctx, x.amount));
    try w.wrapped("url", x.url);
    try w.obj("start-date", try wDate(&w, x.start_date));
    try w.obj("end-date", try wDate(&w, x.end_date));
    try optExtIds(&w, "external-ids", x.external_ids);
    try wContributors(&w, x.contributors);
    try w.obj("organization", try optOrgJ(&w, &x.organization));
    return w.done();
}

fn wFundingSummary(ctx: *const Ctx, path: []const u8, x: *const model.FundingSummary) WriteError!J {
    var w = W.init(ctx, path);
    try wMeta(&w, &x.meta);
    try w.obj("title", try wTitle(&w, x.title));
    try optExtIds(&w, "external-ids", x.external_ids);
    try w.wrapped("url", x.url);
    try w.vocab("type", x.funding_type);
    try w.obj("start-date", try wDate(&w, x.start_date));
    try w.obj("end-date", try wDate(&w, x.end_date));
    try w.obj("organization", try optOrgJ(&w, &x.organization));
    return w.done();
}

fn wFundings(ctx: *const Ctx, path: []const u8, x: *const model.Fundings) WriteError!J {
    var w = try wContainer(ctx, path, x.path, x.last_modified_date);
    const groups = try ctx.a.alloc(J, x.groups.len);
    for (x.groups, groups, 0..) |*g, *gj, i| {
        const gp = try ctx.path("{s}/group[{d}]", .{ path, i + 1 });
        var gw = try wGroup(ctx, gp, g.last_modified_date, g.external_ids);
        const items = try ctx.a.alloc(J, g.funding_summaries.len);
        const sp = try ctx.path("{s}/funding-summary", .{gp});
        for (g.funding_summaries, items) |*s, *it| it.* = try wFundingSummary(ctx, sp, s);
        try gw.arr("funding-summary", items);
        gj.* = gw.done();
    }
    try w.arr("group", groups);
    return w.done();
}

fn wAffiliation(ctx: *const Ctx, path: []const u8, x: *const model.Affiliation) WriteError!J {
    var w = W.init(ctx, path);
    try wMeta(&w, &x.meta);
    try w.bare("department-name", x.department_name);
    try w.bare("role-title", x.role_title);
    try w.obj("start-date", try wDate(&w, x.start_date));
    try w.obj("end-date", try wDate(&w, x.end_date));
    try w.obj("organization", try optOrgJ(&w, &x.organization));
    try w.wrapped("url", x.url);
    try optExtIds(&w, "external-ids", x.external_ids);
    return w.done();
}

fn wAffiliations(ctx: *const Ctx, path: []const u8, x: *const model.Affiliations) WriteError!J {
    var w = try wContainer(ctx, path, x.path, x.last_modified_date);
    const groups = try ctx.a.alloc(J, x.groups.len);
    for (x.groups, groups, 0..) |*g, *gj, i| {
        const gp = try ctx.path("{s}/affiliation-group[{d}]", .{ path, i + 1 });
        var gw = try wGroup(ctx, gp, g.last_modified_date, g.external_ids);
        const items = try ctx.a.alloc(J, g.summaries.len);
        for (g.summaries, items) |*s, *it| {
            const tag = s.kind.summaryElement();
            var sw = W.init(ctx, "");
            try sw.obj(tag, try wAffiliation(ctx, try ctx.path("{s}/{s}", .{ gp, tag }), s));
            it.* = sw.done();
        }
        try gw.arr("summaries", items);
        gj.* = gw.done();
    }
    try w.arr("affiliation-group", groups);
    return w.done();
}

fn wPeerReviewSummary(ctx: *const Ctx, path: []const u8, x: *const model.PeerReviewSummary) WriteError!J {
    var w = W.init(ctx, path);
    try wMeta(&w, &x.meta);
    try w.vocab("reviewer-role", x.reviewer_role);
    try optExtIds(&w, "external-ids", x.external_ids);
    try w.wrapped("review-url", x.review_url);
    try w.vocab("review-type", x.review_type);
    try w.obj("completion-date", try wDate(&w, x.completion_date));
    try w.bare("review-group-id", x.review_group_id);
    try w.obj("convening-organization", try optOrgJ(&w, &x.convening_organization));
    return w.done();
}

fn wPeerReview(ctx: *const Ctx, path: []const u8, x: *const model.PeerReview) WriteError!J {
    var w = W.init(ctx, path);
    try wMeta(&w, &x.meta);
    try w.vocab("reviewer-role", x.reviewer_role);
    try reqExtIds(&w, "review-identifiers", x.review_identifiers);
    try w.wrapped("review-url", x.review_url);
    try w.vocab("review-type", x.review_type);
    try w.obj("review-completion-date", try wDate(&w, x.review_completion_date));
    try w.bare("review-group-id", x.review_group_id);
    if (x.subject_external_identifier) |*s| try w.obj("subject-external-identifier", try wExtId(&w, try w.at("subject-external-identifier"), s));
    try w.bare("subject-container-name", x.subject_container_name);
    try w.bare("subject-type", x.subject_type);
    try w.obj("subject-name", try wTitle(&w, x.subject_name));
    try w.wrapped("subject-url", x.subject_url);
    try w.obj("convening-organization", try optOrgJ(&w, &x.convening_organization));
    return w.done();
}

fn wPeerReviews(ctx: *const Ctx, path: []const u8, x: *const model.PeerReviews) WriteError!J {
    var w = try wContainer(ctx, path, x.path, x.last_modified_date);
    const groups = try ctx.a.alloc(J, x.groups.len);
    for (x.groups, groups, 0..) |*g, *gj, i| {
        const gp = try ctx.path("{s}/group[{d}]", .{ path, i + 1 });
        var gw = try wGroup(ctx, gp, g.last_modified_date, g.external_ids);
        const dups = try ctx.a.alloc(J, g.duplicates.len);
        for (g.duplicates, dups, 0..) |*d, *dj, k| {
            const dp = try ctx.path("{s}/peer-review-group[{d}]", .{ gp, k + 1 });
            var dw = try wGroup(ctx, dp, d.last_modified_date, d.external_ids);
            const items = try ctx.a.alloc(J, d.summaries.len);
            const sp = try ctx.path("{s}/peer-review-summary", .{dp});
            for (d.summaries, items) |*s, *it| it.* = try wPeerReviewSummary(ctx, sp, s);
            try dw.arr("peer-review-summary", items);
            dj.* = dw.done();
        }
        try gw.arr("peer-review-group", dups);
        gj.* = gw.done();
    }
    try w.arr("group", groups);
    return w.done();
}

fn wHosts(ctx: *const Ctx, orgs: []const model.Organization) WriteError!J {
    var w = W.init(ctx, "");
    const items = try ctx.a.alloc(J, orgs.len);
    for (orgs, items) |*org, *it| it.* = try wOrg(&w, org);
    try w.arr("organization", items);
    return w.done();
}

fn wProposal(ctx: *const Ctx, path: []const u8, p: *const model.Proposal) WriteError!J {
    var w = W.init(ctx, path);
    try w.obj("title", try wTitle(&w, p.title));
    try w.obj("hosts", try wHosts(ctx, p.hosts));
    try reqExtIds(&w, "external-ids", p.external_ids);
    try w.obj("start-date", try wDate(&w, p.start_date));
    try w.obj("end-date", try wDate(&w, p.end_date));
    try w.wrapped("url", p.url);
    return w.done();
}

fn wResearchResource(ctx: *const Ctx, path: []const u8, x: *const model.ResearchResource) WriteError!J {
    var w = W.init(ctx, path);
    try wMeta(&w, &x.meta);
    if (x.proposal) |*p| try w.obj("proposal", try wProposal(ctx, try w.at("proposal"), p));
    const items = try ctx.a.alloc(J, x.resource_items.len);
    for (x.resource_items, items, 0..) |*ri, *it, i| {
        var iw = W.init(ctx, try ctx.path("{s}/resource-item[{d}]", .{ path, i + 1 }));
        try iw.bare("resource-name", ri.resource_name);
        try iw.vocab("resource-type", ri.resource_type);
        try iw.obj("hosts", try wHosts(ctx, ri.hosts));
        try reqExtIds(&iw, "external-ids", ri.external_ids);
        try iw.wrapped("url", ri.url);
        it.* = iw.done();
    }
    try w.arr("resource-item", items);
    return w.done();
}

fn wResearchResourceSummary(ctx: *const Ctx, path: []const u8, x: *const model.ResearchResourceSummary) WriteError!J {
    var w = W.init(ctx, path);
    try wMeta(&w, &x.meta);
    if (x.proposal) |*p| try w.obj("proposal", try wProposal(ctx, try w.at("proposal"), p));
    return w.done();
}

fn wResearchResources(ctx: *const Ctx, path: []const u8, x: *const model.ResearchResources) WriteError!J {
    var w = try wContainer(ctx, path, x.path, x.last_modified_date);
    const groups = try ctx.a.alloc(J, x.groups.len);
    for (x.groups, groups, 0..) |*g, *gj, i| {
        const gp = try ctx.path("{s}/group[{d}]", .{ path, i + 1 });
        var gw = try wGroup(ctx, gp, g.last_modified_date, g.external_ids);
        const items = try ctx.a.alloc(J, g.summaries.len);
        const sp = try ctx.path("{s}/research-resource-summary", .{gp});
        for (g.summaries, items) |*s, *it| it.* = try wResearchResourceSummary(ctx, sp, s);
        try gw.arr("research-resource-summary", items);
        gj.* = gw.done();
    }
    try w.arr("group", groups);
    return w.done();
}

fn wActivities(ctx: *const Ctx, path: []const u8, x: *const model.ActivitiesSummary) WriteError!J {
    var w = try wContainer(ctx, path, x.path, x.last_modified_date);
    for (model.AffiliationKind.all) |k| {
        if (x.affiliations(k)) |af| {
            const key = k.containerElement();
            try w.obj(key, try wAffiliations(ctx, try w.at(key), af));
        }
    }
    if (x.fundings) |*f| try w.obj("fundings", try wFundings(ctx, try w.at("fundings"), f));
    if (x.peer_reviews) |*p| try w.obj("peer-reviews", try wPeerReviews(ctx, try w.at("peer-reviews"), p));
    if (x.research_resources) |*r| try w.obj("research-resources", try wResearchResources(ctx, try w.at("research-resources"), r));
    if (x.works) |*wk| try w.obj("works", try wWorks(ctx, try w.at("works"), wk));
    return w.done();
}

fn wName(ctx: *const Ctx, path: []const u8, x: *const model.Name) WriteError!J {
    var w = W.init(ctx, path);
    try w.vocab("visibility", x.visibility);
    try w.bare("path", x.path);
    try w.timestamp("created-date", x.created_date);
    try w.timestamp("last-modified-date", x.last_modified_date);
    try w.wrapped("given-names", x.given_names);
    try w.wrapped("family-name", x.family_name);
    try w.wrapped("credit-name", x.credit_name);
    return w.done();
}

fn wBiography(ctx: *const Ctx, path: []const u8, x: *const model.Biography) WriteError!J {
    var w = W.init(ctx, path);
    try w.vocab("visibility", x.visibility);
    try w.bare("path", x.path);
    try w.timestamp("created-date", x.created_date);
    try w.timestamp("last-modified-date", x.last_modified_date);
    try w.bare("content", x.content);
    return w.done();
}

fn wOtherName(ctx: *const Ctx, path: []const u8, x: *const model.OtherName) WriteError!J {
    var w = W.init(ctx, path);
    try wMeta(&w, &x.meta);
    try w.bare("content", x.content);
    return w.done();
}

fn wResearcherUrl(ctx: *const Ctx, path: []const u8, x: *const model.ResearcherUrl) WriteError!J {
    var w = W.init(ctx, path);
    try wMeta(&w, &x.meta);
    try w.bare("url-name", x.url_name);
    try w.wrapped("url", x.url);
    return w.done();
}

fn wEmail(ctx: *const Ctx, path: []const u8, x: *const model.Email) WriteError!J {
    var w = W.init(ctx, path);
    try wMeta(&w, &x.meta);
    try w.bare("email", x.email);
    try w.boolean("verified", x.verified);
    try w.boolean("primary", x.primary);
    return w.done();
}

fn wAddress(ctx: *const Ctx, path: []const u8, x: *const model.Address) WriteError!J {
    var w = W.init(ctx, path);
    try wMeta(&w, &x.meta);
    try w.wrapped("country", x.country);
    return w.done();
}

fn wKeyword(ctx: *const Ctx, path: []const u8, x: *const model.Keyword) WriteError!J {
    var w = W.init(ctx, path);
    try wMeta(&w, &x.meta);
    try w.bare("content", x.content);
    return w.done();
}

fn wExtIdRoot(ctx: *const Ctx, path: []const u8, x: *const model.ExternalId) WriteError!J {
    const w = W.init(ctx, path);
    return wExtId(&w, path, x);
}

fn wList(
    comptime T: type,
    ctx: *const Ctx,
    path: []const u8,
    l: *const model.ItemList(T),
    item: []const u8,
    comptime f: fn (*const Ctx, []const u8, *const T) WriteError!J,
) WriteError!J {
    var w = try wContainer(ctx, path, l.path, l.last_modified_date);
    const items = try ctx.a.alloc(J, l.items.len);
    for (l.items, items, 0..) |*x, *it, i| it.* = try f(ctx, try ctx.path("{s}/{s}[{d}]", .{ path, item, i + 1 }), x);
    try w.arr(item, items);
    return w.done();
}

fn wPerson(ctx: *const Ctx, path: []const u8, x: *const model.Person) WriteError!J {
    var w = try wContainer(ctx, path, x.path, x.last_modified_date);
    if (x.name) |*n| try w.obj("name", try wName(ctx, try w.at("name"), n));
    if (x.other_names) |*l| try w.obj("other-names", try wList(model.OtherName, ctx, try w.at("other-names"), l, "other-name", wOtherName));
    if (x.biography) |*b| try w.obj("biography", try wBiography(ctx, try w.at("biography"), b));
    if (x.researcher_urls) |*l| try w.obj("researcher-urls", try wList(model.ResearcherUrl, ctx, try w.at("researcher-urls"), l, "researcher-url", wResearcherUrl));
    if (x.emails) |*l| try w.obj("emails", try wList(model.Email, ctx, try w.at("emails"), l, "email", wEmail));
    if (x.addresses) |*l| try w.obj("addresses", try wList(model.Address, ctx, try w.at("addresses"), l, "address", wAddress));
    if (x.keywords) |*l| try w.obj("keywords", try wList(model.Keyword, ctx, try w.at("keywords"), l, "keyword", wKeyword));
    if (x.external_identifiers) |*l| try w.obj("external-identifiers", try wList(model.ExternalId, ctx, try w.at("external-identifiers"), l, "external-identifier", wExtIdRoot));
    return w.done();
}

fn wPersonalDetails(ctx: *const Ctx, path: []const u8, x: *const model.PersonalDetails) WriteError!J {
    var w = try wContainer(ctx, path, x.path, x.last_modified_date);
    if (x.name) |*n| try w.obj("name", try wName(ctx, try w.at("name"), n));
    if (x.other_names) |*l| try w.obj("other-names", try wList(model.OtherName, ctx, try w.at("other-names"), l, "other-name", wOtherName));
    if (x.biography) |*b| try w.obj("biography", try wBiography(ctx, try w.at("biography"), b));
    return w.done();
}

fn wHistory(ctx: *const Ctx, path: []const u8, x: *const model.History) WriteError!J {
    var w = W.init(ctx, path);
    // no "visibility": history/@visibility is XML-only (module docs)
    try w.bare("creation-method", if (x.creation_method) |m| creationMethodToJson(m) else null);
    try w.timestamp("completion-date", x.completion_date);
    try w.timestamp("submission-date", x.submission_date);
    try w.timestamp("last-modified-date", x.last_modified_date);
    try w.boolean("claimed", x.claimed);
    if (x.source) |*src| try w.obj("source", try wSource(&w, try w.at("source"), src));
    try w.timestamp("deactivation-date", x.deactivation_date);
    try w.boolean("verified-email", x.verified_email);
    try w.boolean("verified-primary-email", x.verified_primary_email);
    return w.done();
}

fn wRecord(ctx: *const Ctx, path: []const u8, x: *const model.Record) WriteError!J {
    var w = W.init(ctx, path);
    try w.bare("path", x.path);
    try w.obj("orcid-identifier", try optIdentJ(&w, &x.orcid_identifier));
    if (x.preferences) |p| {
        var pw = W.init(ctx, "");
        try pw.bare("locale", p.locale);
        try w.obj("preferences", pw.done());
    }
    if (x.history) |*h| try w.obj("history", try wHistory(ctx, try w.at("history"), h));
    if (x.person) |*p| try w.obj("person", try wPerson(ctx, try w.at("person"), p));
    if (x.activities_summary) |*act| try w.obj("activities-summary", try wActivities(ctx, try w.at("activities-summary"), act));
    return w.done();
}

fn wError(ctx: *const Ctx, x: *const model.OrcidError) WriteError!J {
    var w = W.init(ctx, "");
    try w.int("response-code", x.response_code);
    try w.bare("developer-message", x.developer_message);
    try w.bare("user-message", x.user_message);
    try w.int("error-code", x.error_code);
    try w.bare("more-info", x.more_info);
    return w.done();
}

fn wBulk(ctx: *const Ctx, path: []const u8, items: []const model.BulkItem) WriteError!J {
    const out = try ctx.a.alloc(J, items.len);
    for (items, out, 0..) |*item, *it, i| {
        var e = W.init(ctx, "");
        switch (item.*) {
            .work => |*x| try e.obj("work", try wWork(ctx, try ctx.path("{s}/work[{d}]", .{ path, i + 1 }), x)),
            .@"error" => |*x| try e.obj("error", try wError(ctx, x)),
        }
        it.* = e.done();
    }
    var w = W.init(ctx, path);
    try w.arr("bulk", out);
    return w.done();
}

/// `group-id-record` as ORCID's JSON has it: no dates (`@JsonIgnore` in
/// ORCID's `GroupIdRecord`), `source` as an object.
fn wGroupIdRecord(ctx: *const Ctx, path: []const u8, x: *const model.GroupIdRecord) WriteError!J {
    var w = W.init(ctx, path);
    try w.int("put-code", x.put_code);
    try w.bare("name", x.name);
    try w.bare("group-id", x.group_id);
    try w.bare("description", x.description);
    try w.vocab("type", x.group_type);
    if (x.source) |*src| try w.obj("source", try wSource(&w, try w.at("source"), src));
    return w.done();
}

fn wGroupIdRecords(ctx: *const Ctx, path: []const u8, x: *const model.GroupIdRecords) WriteError!J {
    var w = W.init(ctx, path);
    try w.timestamp("last-modified-date", x.last_modified_date);
    try w.int("total", x.total);
    try w.int("page", x.page);
    try w.int("page-size", x.page_size);
    const items = try ctx.a.alloc(J, x.records.len);
    for (x.records, items, 0..) |*r, *it, i| {
        it.* = try wGroupIdRecord(ctx, try ctx.path("{s}/group-id-record[{d}]", .{ path, i + 1 }), r);
    }
    try w.arr("group-id-record", items);
    return w.done();
}

fn toJ(ctx: *const Ctx, root: *const model.Root) WriteError!J {
    const p = root.kind() orelse "unknown";
    return switch (root.*) {
        .record => |*x| wRecord(ctx, p, x),
        .activities_summary => |*x| wActivities(ctx, p, x),
        .works => |*x| wWorks(ctx, p, x),
        .work => |*x| wWork(ctx, p, x),
        .work_summary => |*x| wWorkSummary(ctx, p, x),
        .fundings => |*x| wFundings(ctx, p, x),
        .funding => |*x| wFunding(ctx, p, x),
        .funding_summary => |*x| wFundingSummary(ctx, p, x),
        .affiliations => |*x| wAffiliations(ctx, p, x),
        .affiliation, .affiliation_summary => |*x| wAffiliation(ctx, p, x),
        .peer_reviews => |*x| wPeerReviews(ctx, p, x),
        .peer_review => |*x| wPeerReview(ctx, p, x),
        .peer_review_summary => |*x| wPeerReviewSummary(ctx, p, x),
        .research_resources => |*x| wResearchResources(ctx, p, x),
        .research_resource => |*x| wResearchResource(ctx, p, x),
        .research_resource_summary => |*x| wResearchResourceSummary(ctx, p, x),
        .person => |*x| wPerson(ctx, p, x),
        .personal_details => |*x| wPersonalDetails(ctx, p, x),
        .name => |*x| wName(ctx, p, x),
        .biography => |*x| wBiography(ctx, p, x),
        .credit_name => |x| blk: {
            var w = W.init(ctx, p);
            try w.bare("value", x);
            break :blk w.done();
        },
        .other_names => |*l| wList(model.OtherName, ctx, p, l, "other-name", wOtherName),
        .other_name => |*x| wOtherName(ctx, p, x),
        .researcher_urls => |*l| wList(model.ResearcherUrl, ctx, p, l, "researcher-url", wResearcherUrl),
        .researcher_url => |*x| wResearcherUrl(ctx, p, x),
        .emails => |*l| wList(model.Email, ctx, p, l, "email", wEmail),
        .email => |*x| wEmail(ctx, p, x),
        .addresses => |*l| wList(model.Address, ctx, p, l, "address", wAddress),
        .address => |*x| wAddress(ctx, p, x),
        .keywords => |*l| wList(model.Keyword, ctx, p, l, "keyword", wKeyword),
        .keyword => |*x| wKeyword(ctx, p, x),
        .external_identifiers => |*l| wList(model.ExternalId, ctx, p, l, "external-identifier", wExtIdRoot),
        .external_identifier => |*x| wExtIdRoot(ctx, p, x),
        .history => |*x| wHistory(ctx, p, x),
        .preferences => |x| blk: {
            var w = W.init(ctx, p);
            try w.bare("locale", x.locale);
            break :blk w.done();
        },
        .bulk => |*x| wBulk(ctx, p, x.items),
        .@"error" => |*x| wError(ctx, x),
        .search => |*s| blk: {
            var w = W.init(ctx, p);
            try w.int("num-found", s.num_found);
            const items = try ctx.a.alloc(J, s.results.len);
            for (s.results, items) |*r, *it| {
                var rw = W.init(ctx, "");
                try rw.obj("orcid-identifier", try wIdent(&rw, r));
                it.* = rw.done();
            }
            try w.arr("result", items);
            break :blk w.done();
        },
        .expanded_search => |*s| blk: {
            var w = W.init(ctx, p);
            try w.int("num-found", s.num_found);
            const items = try ctx.a.alloc(J, s.results.len);
            for (s.results, items) |*r, *it| {
                var rw = W.init(ctx, "");
                try rw.bare("orcid-id", r.orcid_id);
                try rw.bare("given-names", r.given_names);
                try rw.bare("family-names", r.family_names);
                try rw.bare("credit-name", r.credit_name);
                if (r.other_names.len > 0) try rw.arr("other-name", try stringsJ(&rw, "other-name", r.other_names));
                if (r.emails.len > 0) try rw.arr("email", try stringsJ(&rw, "email", r.emails));
                if (r.institution_names.len > 0) try rw.arr("institution-name", try stringsJ(&rw, "institution-name", r.institution_names));
                it.* = rw.done();
            }
            try w.arr("expanded-result", items);
            break :blk w.done();
        },
        .group_id_record => |*x| wGroupIdRecord(ctx, p, x),
        .group_id_records => |*x| wGroupIdRecords(ctx, p, x),
        .unknown => |name| blk: {
            if (ctx.diag) |d| {
                d.setPath(name);
                d.message = "unknown root element";
                d.code_point = null;
            }
            break :blk error.Unwritable;
        },
    };
}

fn stringsJ(w: *W, k: []const u8, values: []const Text) WriteError![]const J {
    const out = try w.a.alloc(J, values.len);
    for (values, out) |x, *o| o.* = try w.checked(k, x);
    return out;
}

// ------------------------------------------------------------- serialising

fn fieldLess(_: void, x: Field, y: Field) bool {
    return std.mem.lessThan(u8, x.key, y.key);
}

fn writeString(w: *Writer, s: []const u8) Writer.Error!void {
    try w.writeByte('"');
    var start: usize = 0;
    for (s, 0..) |c, i| {
        const esc: ?[]const u8 = switch (c) {
            '"' => "\\\"",
            '\\' => "\\\\",
            0x08 => "\\b",
            0x09 => "\\t",
            0x0A => "\\n",
            0x0C => "\\f",
            0x0D => "\\r",
            else => null,
        };
        if (esc == null and c >= 0x20) continue;
        try w.writeAll(s[start..i]);
        if (esc) |e| {
            try w.writeAll(e);
        } else {
            const hex = "0123456789abcdef";
            try w.writeAll("\\u00");
            try w.writeByte(hex[c >> 4]);
            try w.writeByte(hex[c & 0xF]);
        }
        start = i + 1;
    }
    try w.writeAll(s[start..]);
    try w.writeByte('"');
}

fn writeJ(w: *Writer, scratch: Allocator, j: J, indent: usize) (Writer.Error || OOM)!void {
    switch (j) {
        .str => |s| try writeString(w, s),
        .int => |i| try w.print("{d}", .{i}),
        .boolean => |b| try w.writeAll(if (b) "true" else "false"),
        .arr => |items| {
            if (items.len == 0) return w.writeAll("[]");
            try w.writeByte('[');
            for (items, 0..) |x, i| {
                try w.writeAll(if (i == 0) "\n" else ",\n");
                try w.splatByteAll(' ', indent + 2);
                try writeJ(w, scratch, x, indent + 2);
            }
            try w.writeByte('\n');
            try w.splatByteAll(' ', indent);
            try w.writeByte(']');
        },
        .obj => |fields| {
            if (fields.len == 0) return w.writeAll("{}");
            const sorted = try scratch.dupe(Field, fields);
            std.mem.sort(Field, sorted, {}, fieldLess);
            try w.writeByte('{');
            for (sorted, 0..) |f, i| {
                try w.writeAll(if (i == 0) "\n" else ",\n");
                try w.splatByteAll(' ', indent + 2);
                try writeString(w, f.key);
                try w.writeAll(": ");
                try writeJ(w, scratch, f.val, indent + 2);
            }
            try w.writeByte('\n');
            try w.splatByteAll(' ', indent);
            try w.writeByte('}');
        },
    }
}

fn emit(gpa: Allocator, w: *Writer, comptime Arg: type, arg: Arg, comptime build: fn (*const Ctx, Arg) WriteError!J, diag: ?*Diagnostic) WriteError!void {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const ctx: Ctx = .{ .a = arena.allocator(), .diag = diag };
    const j = try build(&ctx, arg);
    writeJ(w, ctx.a, j, 0) catch |err| return err;
    try w.writeByte('\n');
}

/// Writes any document root as ORCID JSON (pretty, keys sorted, final LF).
pub fn write(gpa: Allocator, w: *Writer, root: *const model.Root, diag: ?*Diagnostic) WriteError!void {
    return emit(gpa, w, *const model.Root, root, toJ, diag);
}

/// `write` into a new allocated buffer (caller frees).
pub fn toOwned(gpa: Allocator, root: *const model.Root, diag: ?*Diagnostic) WriteError![]u8 {
    var aw: Writer.Allocating = .init(gpa);
    defer aw.deinit();
    write(gpa, &aw.writer, root, diag) catch |err| switch (err) {
        error.WriteFailed => return error.OutOfMemory,
        else => |e| return e,
    };
    return aw.toOwnedSlice();
}

// ===================================================================== tests

const testing = std.testing;

test "timestamps" {
    var buf: [40]u8 = undefined;
    try testing.expectEqualStrings("1970-01-01T00:00:00.000Z", millisToDatetime(&buf, 0));
    try testing.expectEqualStrings("2018-10-30T10:49:18.250Z", millisToDatetime(&buf, 1_540_896_558_250));
    try testing.expectEqual(@as(?i64, 1_540_896_558_250), datetimeToMillis("2018-10-30T10:49:18.250Z"));
    try testing.expectEqual(@as(?i64, 1_461_784_973_471), datetimeToMillis("2016-04-27T13:22:53.471-06:00"));
    try testing.expectEqual(@as(?i64, 1_009_800_000_000), datetimeToMillis("2001-12-31T12:00:00"));
    try testing.expectEqual(@as(?i64, 1_009_796_400_123), datetimeToMillis("2001-12-31T12:00:00.123456+01:00"));
    try testing.expectEqual(@as(?i64, -315_619_200_000), datetimeToMillis("1960-01-01T00:00:00Z"));
    try testing.expectEqualStrings("1960-01-01T00:00:00.000Z", millisToDatetime(&buf, -315_619_200_000));
    try testing.expectEqual(@as(?i64, null), datetimeToMillis("yesterday"));
    try testing.expectEqual(@as(?i64, null), datetimeToMillis("2001-13-01T00:00:00Z"));
    for ([_]i64{ 0, 1, 999, 86_399_999, 951_782_400_000, 4_102_444_800_000, -1 }) |ms| {
        try testing.expectEqual(@as(?i64, ms), datetimeToMillis(millisToDatetime(&buf, ms)));
    }
}

test "lenient text and strict output" {
    const gpa = testing.allocator;
    var doc = try parse(gpa, "work",
        \\{"title": {"title": {"value": " T "}, "subtitle": "S", "translated-title": null},
        \\ "type": "book", "url": "https://bare", "put-code": "12", "display-index": -1,
        \\ "publication-date": {"year": {"value": "2022"}, "month": {"value": "05"}},
        \\ "unknown-key": [1, 2]}
    , null);
    defer doc.deinit();
    const w = doc.root.work;
    try testing.expectEqualStrings("T", w.title.?.title.?);
    try testing.expectEqualStrings("S", w.title.?.subtitle.?);
    try testing.expectEqualStrings("https://bare", w.url.?);
    try testing.expectEqual(@as(?i64, 12), w.meta.put_code);
    try testing.expectEqual(@as(?i32, null), w.meta.display_index);
    try testing.expectEqualStrings("-1", w.meta.display_index_text.?);
    try testing.expect(w.title.?.translated_title == null);
    const out = try toOwned(gpa, &doc.root, null);
    defer gpa.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "\"url\": {\n    \"value\": \"https://bare\"\n  }") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"put-code\": 12") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"display-index\": \"-1\"") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"month\": {\n      \"value\": \"05\"\n    }") != null);
    try testing.expect(std.mem.indexOf(u8, out, "translated-title") == null);
}

test "errors" {
    const gpa = testing.allocator;
    try testing.expectError(error.MalformedJson, parse(gpa, "work", "{", null));
    try testing.expectError(error.MalformedJson, parse(gpa, "work", "[]", null));
    try testing.expectError(error.UnknownKind, parse(gpa, "nonsense", "{}", null));
    var d: Diagnostic = .{};
    const k: model.Root = .{ .keyword = .{ .meta = .{ .created_date = "not a date" } } };
    try testing.expectError(error.Unwritable, toOwned(gpa, &k, &d));
    try testing.expectEqualStrings("keyword/created-date", d.path());
}

test "key lookup" {
    for (all_keys) |k| {
        if (k == .@"(unknown)") continue;
        try testing.expectEqual(@as(?Key, k), keyOf(@tagName(k)));
    }
    for ([_][]const u8{ "", "titl", "titles", "Title", "(unknown)", "disambiguated-organization-identifiers" }) |name| {
        try testing.expectEqual(@as(?Key, null), keyOf(name));
    }
}

test "string scan across vector boundaries" {
    var buf: [3 * vec_len + 5]u8 = undefined;
    for (0..buf.len) |n| {
        @memset(&buf, 'a');
        try testing.expectEqual(n, findSpecial(buf[0..n], 0));
        for ("\"\\\x00\x1f") |c| {
            buf[n] = c;
            try testing.expectEqual(n, findSpecial(&buf, 0));
            try testing.expectEqual(n, findSpecial(&buf, n));
        }
        buf[n] = 0x7f;
        try testing.expectEqual(buf.len, findSpecial(&buf, 0));
    }
}

test "serde layout" {
    const gpa = testing.allocator;
    const root: model.Root = .{ .keyword = .{ .meta = .{ .put_code = 1 }, .content = "a\"\\\x01\n" } };
    const out = try toOwned(gpa, &root, null);
    defer gpa.free(out);
    try testing.expectEqualStrings("{\n  \"content\": \"a\\\"\\\\\\u0001\\n\",\n  \"put-code\": 1\n}\n", out);
}

//! Model → ORCID v3.0 XML, exact and deterministic (the rules of yorc-rs's
//! `xml::write`):
//! * `<?xml version="1.0" encoding="UTF-8"?>`, then the root element, LF line
//!   ends, two-space indentation, a final LF;
//! * element names carry ORCID's prefixes (`work:`, `common:`, ...), each bound
//!   to `http://www.orcid.org/ns/<prefix>`; every namespace used anywhere in the
//!   document is declared once, on the root, in `Ns` order;
//! * elements follow the XSD sequence order; absent optional values are not
//!   written; containers the XSD requires (`external-ids` in groups,
//!   `review-identifiers`, `resource-items`, `hosts`) are always written;
//! * attributes in a fixed order per element (`put-code`, `path`,
//!   `visibility`, `display-index`, then element-specific ones);
//! * text escapes `&`, `<`, `>` and CR; attributes also `"`, TAB, LF;
//! * fuzzy-date parts: year as `{:04}`, month and day as `{:02}` (Rust
//!   formatting: the sign counts towards the width).
//!
//! Content XML 1.0 cannot carry (control characters, U+FFFE/U+FFFF, bytes
//! that are not UTF-8), a `.unknown` root, and a funding contributor with a
//! `contributor-sequence` (funding-3.0.xsd has none) are `error.Unwritable`,
//! with the element path in the Diagnostic; nothing panics.
//!
//! How (the techniques of yorc-rs's one-pass writer):
//! * `toOwned` writes in one pass, straight from the
//!   model into one buffer pre-sized from the model's shape (`estimate`).
//!   The namespaces in use are a bit set; their declarations are inserted
//!   after the root's name once the document is complete (one memmove).
//! * Escaping and the XML 1.0 character check are one scan (`escape`): a
//!   `@Vector` compare finds the next byte that needs attention, plain runs
//!   between them are copied in bulk.
//! * Integers and padded dates are written digit by digit, without
//!   `std.fmt`; indentation is a slice of a constant; the markup of a tag is
//!   one bounds check and plain copies (`put`).
//! * `write` takes any `*Writer` and no allocator, so it cannot insert
//!   into what it has written: it runs the same emitter
//!   first into a `Writer.Discarding`, which yields the namespaces (and any
//!   error, so that nothing reaches `w` when the model is unwritable), then
//!   into `w`, declaring the namespaces as the root is written.
//!
//! On error the `toOwned` variants free what they wrote; `write` writes
//! nothing on `error.Unwritable`.
const std = @import("std");
const model = @import("model.zig");
const utf8 = @import("utf8.zig");
const Diagnostic = @import("diag.zig").Diagnostic;

const Writer = std.Io.Writer;
const Text = model.Text;

pub const WriteError = error{ Unwritable, WriteFailed };

/// The ORCID v3.0 namespaces, in declaration order.
pub const Ns = enum {
    activities,
    address,
    bulk,
    common,
    distinction,
    education,
    email,
    employment,
    @"error",
    expanded_search,
    external_identifier,
    funding,
    history,
    invited_position,
    keyword,
    membership,
    other_name,
    peer_review,
    person,
    personal_details,
    preferences,
    qualification,
    record,
    research_resource,
    researcher_url,
    search,
    service,
    work,

    pub const count = @typeInfo(Ns).@"enum".field_names.len;

    /// The prefix ORCID uses; also the last segment of the namespace URI.
    pub fn prefix(ns: Ns) []const u8 {
        return switch (ns) {
            .expanded_search => "expanded-search",
            .external_identifier => "external-identifier",
            .invited_position => "invited-position",
            .other_name => "other-name",
            .peer_review => "peer-review",
            .personal_details => "personal-details",
            .research_resource => "research-resource",
            .researcher_url => "researcher-url",
            else => @tagName(ns),
        };
    }

    pub const uri_base = "http://www.orcid.org/ns/";

    /// The namespace of an affiliation kind's items.
    pub fn ofAffiliation(kind: model.AffiliationKind) Ns {
        return switch (kind) {
            .distinction => .distinction,
            .education => .education,
            .employment => .employment,
            .invited_position => .invited_position,
            .membership => .membership,
            .qualification => .qualification,
            .service => .service,
        };
    }

    /// This namespace's bit in `Emitter.used`.
    fn bit(ns: Ns) u32 {
        return @as(u32, 1) << @intCast(@backingInt(ns));
    }

    /// `prefix:`, for element names.
    fn qualifier(ns: Ns) []const u8 {
        return qualifiers[@backingInt(ns)];
    }
};

comptime {
    // `Emitter.used` has one bit per namespace
    std.debug.assert(Ns.count <= 32);
}

const qualifiers: [Ns.count][]const u8 = blk: {
    var t: [Ns.count][]const u8 = undefined;
    for (0..Ns.count) |i| {
        const ns: Ns = @fromBackingInt(@intCast(i));
        t[i] = ns.prefix() ++ ":";
    }
    break :blk t;
};

// ============================================================ declarations

const xml_decl = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n";

/// Room for the root's namespace declarations: all 28 take 1,490 bytes.
const decl_room = 1536;

comptime {
    @setEvalBranchQuota(10_000);
    var n: usize = 0;
    for (0..Ns.count) |i| {
        const ns: Ns = @fromBackingInt(@intCast(i));
        n += " xmlns:".len + 2 * ns.prefix().len + "=\"".len + Ns.uri_base.len + "\"".len;
    }
    std.debug.assert(n <= decl_room);
}

/// ` xmlns:p="http://www.orcid.org/ns/p"` for every namespace in `used`, in
/// `Ns` order.
fn declarations(buf: *[decl_room]u8, used: u32) []const u8 {
    var n: usize = 0;
    for (0..Ns.count) |i| {
        if ((used >> @intCast(i)) & 1 == 0) continue;
        const ns: Ns = @fromBackingInt(@intCast(i));
        const p = ns.prefix();
        for ([_][]const u8{ " xmlns:", p, "=\"" ++ Ns.uri_base, p, "\"" }) |part| {
            @memcpy(buf[n..][0..part.len], part);
            n += part.len;
        }
    }
    return buf[0..n];
}

/// Inserts the declarations of `used` at `at` in what `aw` holds.
fn insertDeclarations(aw: *Writer.Allocating, at: usize, used: u32) error{OutOfMemory}!void {
    var buf: [decl_room]u8 = undefined;
    const decls = declarations(&buf, used);
    try aw.ensureUnusedCapacity(decls.len);
    const w = &aw.writer;
    const tail_len = w.end - at;
    @memmove(w.buffer[at + decls.len ..][0..tail_len], w.buffer[at..][0..tail_len]);
    @memcpy(w.buffer[at..][0..decls.len], decls);
    w.end += decls.len;
}

// ================================================================= emitter
//
// Start tags are left open (`pending`) until the first child or the end, so
// an element without children or text is `<x/>`. The element path of an
// `error.Unwritable` is built only on error, from the stack of open
// elements.

const max_depth = 64;

/// Indentation for every depth below `max_depth`.
const indent_spaces: [2 * max_depth]u8 = @splat(' ');

const Open = struct { ns: Ns, name: []const u8 };

const Emitter = struct {
    w: *Writer,
    diag: ?*Diagnostic,
    /// The namespaces to declare on the root as it is written (`write`).
    /// Null: they are inserted at `root_end` afterwards (`toOwned`), or not
    /// at all (the dry run of `write`).
    declare: ?u32 = null,
    /// Namespaces used so far, one bit per `Ns`.
    used: u32 = 0,
    /// `w.end` just after the root element's name.
    root_end: usize = 0,
    open: [max_depth]Open = undefined,
    depth: usize = 0,
    /// The innermost start tag is open (`>` not written yet).
    pending: bool = false,

    fn unwritable(e: *const Emitter, extra: ?[]const u8, reason: []const u8, cp: ?u21) WriteError {
        if (e.diag) |d| {
            d.path_len = 0;
            for (e.open[0..e.depth]) |o| d.pushPath(o.name);
            if (extra) |x| d.pushPath(x);
            d.message = reason;
            d.code_point = cp;
        }
        return error.Unwritable;
    }

    /// A value XML 1.0 cannot carry, in the text of the innermost element
    /// (`leaf`: in its child `leaf`).
    fn badText(e: *const Emitter, leaf_name: ?[]const u8, bad: Bad) WriteError {
        return e.unwritable(leaf_name, bad.reason(), bad.cp);
    }

    /// A value XML 1.0 cannot carry, in attribute `name` of the innermost
    /// element (path `.../@name`).
    fn badAttr(e: *const Emitter, name: []const u8, bad: Bad) WriteError {
        if (e.diag) |d| {
            d.path_len = 0;
            for (e.open[0..e.depth]) |o| d.pushPath(o.name);
            d.pushPath("@");
            d.appendRaw(name);
            d.message = bad.reason();
            d.code_point = bad.cp;
        }
        return error.Unwritable;
    }

    fn indent(e: *const Emitter) []const u8 {
        return indent_spaces[0 .. 2 * e.depth];
    }

    /// `>` and the line end if the parent's start tag is still open.
    fn closing(e: *Emitter) []const u8 {
        if (!e.pending) return "";
        e.pending = false;
        return ">\n";
    }

    /// `<ns:name` (attributes may follow); end it with `end` or `endWith`.
    fn begin(e: *Emitter, ns: Ns, name: []const u8) WriteError!void {
        e.used |= ns.bit();
        if (e.depth >= max_depth) return e.unwritable(name, "nesting too deep", null);
        try put(e.w, .{ e.closing(), e.indent(), "<", ns.qualifier(), name });
        if (e.depth == 0) {
            if (e.declare) |used| {
                var buf: [decl_room]u8 = undefined;
                try e.w.writeAll(declarations(&buf, used));
            } else {
                e.root_end = e.w.end;
            }
        }
        e.open[e.depth] = .{ .ns = ns, .name = name };
        e.depth += 1;
        e.pending = true;
    }

    /// ` name="value"` (escaped) if the value is present.
    fn attr(e: *Emitter, name: []const u8, value: ?[]const u8) WriteError!void {
        const v = value orelse return;
        try put(e.w, .{ " ", name, "=\"" });
        if (try escape(true, e.w, v)) |bad| return e.badAttr(name, bad);
        try e.w.writeByte('"');
    }

    /// ` name="text"` for text that needs no escaping (digits, booleans).
    fn attrRaw(e: *Emitter, name: []const u8, text: []const u8) WriteError!void {
        try put(e.w, .{ " ", name, "=\"", text, "\"" });
    }

    fn attrInt(e: *Emitter, name: []const u8, v: i64) WriteError!void {
        var buf: [24]u8 = undefined;
        try e.attrRaw(name, padInt(&buf, v, 0));
    }

    fn attrBool(e: *Emitter, name: []const u8, value: ?bool) WriteError!void {
        const v = value orelse return;
        try e.attrRaw(name, if (v) "true" else "false");
    }

    /// Ends the innermost element; `body` is its text (written only if it
    /// has no children).
    fn endWith(e: *Emitter, body: ?[]const u8) WriteError!void {
        const o = e.open[e.depth - 1];
        if (e.pending) {
            e.pending = false;
            if (body) |t| {
                try e.w.writeByte('>');
                if (try escape(false, e.w, t)) |bad| return e.badText(null, bad);
                e.depth -= 1;
                try put(e.w, .{ "</", o.ns.qualifier(), o.name, ">\n" });
            } else {
                e.depth -= 1;
                try e.w.writeAll("/>\n");
            }
            return;
        }
        e.depth -= 1;
        try put(e.w, .{ e.indent(), "</", o.ns.qualifier(), o.name, ">\n" });
    }

    fn end(e: *Emitter) WriteError!void {
        return e.endWith(null);
    }

    /// `<ns:name>`, on its own line (a leaf: not pushed on the stack).
    fn openLeaf(e: *Emitter, ns: Ns, name: []const u8) WriteError!void {
        e.used |= ns.bit();
        if (e.depth >= max_depth) return e.unwritable(name, "nesting too deep", null);
        try put(e.w, .{ e.closing(), e.indent(), "<", ns.qualifier(), name, ">" });
    }

    /// `<ns:name>text</ns:name>` if `value` is present.
    fn leaf(e: *Emitter, ns: Ns, name: []const u8, value: ?[]const u8) WriteError!void {
        const v = value orelse return;
        try e.openLeaf(ns, name);
        if (try escape(false, e.w, v)) |bad| return e.badText(name, bad);
        try put(e.w, .{ "</", ns.qualifier(), name, ">\n" });
    }

    /// A leaf whose text needs no escaping (digits, booleans).
    fn leafRaw(e: *Emitter, ns: Ns, name: []const u8, text: []const u8) WriteError!void {
        try e.openLeaf(ns, name);
        try put(e.w, .{ text, "</", ns.qualifier(), name, ">\n" });
    }

    fn leafInt(e: *Emitter, ns: Ns, name: []const u8, value: ?i64) WriteError!void {
        const v = value orelse return;
        var buf: [24]u8 = undefined;
        try e.leafRaw(ns, name, padInt(&buf, v, 0));
    }

    fn leafBool(e: *Emitter, ns: Ns, name: []const u8, value: ?bool) WriteError!void {
        const v = value orelse return;
        try e.leafRaw(ns, name, if (v) "true" else "false");
    }

    fn leafVocab(e: *Emitter, ns: Ns, name: []const u8, value: anytype) WriteError!void {
        const v = value orelse return;
        try e.leaf(ns, name, v.text());
    }
};

/// Writes `parts` (a tuple of byte slices) one after the other: one bounds
/// check and plain copies when they fit in `w`'s buffer (as they do in the
/// pre-sized buffer of `toOwned` unless the estimate was short), `writeAll`
/// each otherwise.
inline fn put(w: *Writer, parts: anytype) WriteError!void {
    var n: usize = 0;
    inline for (parts) |p| n += p.len;
    if (w.buffer.len - w.end >= n) {
        @branchHint(.likely);
        var at = w.end;
        inline for (parts) |p| {
            const s: []const u8 = p;
            @memcpy(w.buffer[at..][0..s.len], s);
            at += s.len;
        }
        w.end = at;
        return;
    }
    inline for (parts) |p| try w.writeAll(p);
}

/// Rust `format!("{:0width$}", v)`: zero padding after the sign. `buf` must
/// hold `@max(width, 20)` bytes.
pub fn padInt(buf: []u8, v: i64, width: usize) []const u8 {
    var digits: [20]u8 = undefined;
    var m: u64 = @abs(v);
    var i: usize = digits.len;
    while (true) {
        i -= 1;
        digits[i] = '0' + @as(u8, @intCast(m % 10));
        m /= 10;
        if (m == 0) break;
    }
    const mag = digits[i..];
    var n: usize = 0;
    if (v < 0) {
        buf[0] = '-';
        n = 1;
    }
    while (n + mag.len < width) : (n += 1) buf[n] = '0';
    @memcpy(buf[n..][0..mag.len], mag);
    return buf[0 .. n + mag.len];
}

// ================================================================ escaping
//
// One scan both escapes and checks the XML 1.0 character rule. A vector at
// a time (`std.simd.suggestVectorLength`, then 16 and 8 bytes, then byte by
// byte), it finds the next byte that may need attention: a control byte
// (< 0x20: TAB, LF and CR are escaped or kept, the others refused), `&`,
// `<`, `>`, `"` (attributes), or a byte from 0x80. Runs of plain bytes
// between them are copied as slices.
//
// yorc-rs flags only 0xEF among the bytes from 0x80 (the lead byte of
// U+FFFE and U+FFFF), because a Rust `&str` is valid UTF-8 already. A Zig
// `[]const u8` is not, and the writer refuses invalid UTF-8 ("not valid
// UTF-8", as before), so here every non-ASCII run is decoded sequence by
// sequence (`utf8.decodeAt`), which checks it and finds U+FFFE/U+FFFF;
// the 0xEF look-alikes (U+FF0C, U+FFFD, ...) pass. ASCII text stays on the
// vector path.

const vec_len = std.simd.suggestVectorLength(u8) orelse 16;

/// The first character XML 1.0 cannot carry (0xFFFD: bytes that are not
/// UTF-8).
const Bad = struct {
    cp: u21,
    invalid_utf8: bool = false,

    fn reason(b: Bad) []const u8 {
        return if (b.invalid_utf8) "not valid UTF-8" else "character not allowed in XML 1.0";
    }
};

fn isSpecial(comptime attr: bool, c: u8) bool {
    return c < 0x20 or c >= 0x80 or c == '&' or c == '<' or c == '>' or (attr and c == '"');
}

/// Index in `chunk` of its first byte that `isSpecial`, or null.
inline fn firstSpecialIn(comptime n: comptime_int, comptime attr: bool, chunk: *const [n]u8) ?usize {
    const V = @Vector(n, u8);
    const I = @Vector(n, i8);
    const B = @Vector(n, u1);
    const v: V = chunk.*;
    const quote: B = if (attr) @bitCast(v == @as(V, @splat('"'))) else @splat(0);
    // below 0x20 as signed bytes: the control bytes and every byte from 0x80
    const hits = @as(B, @bitCast(@as(I, @bitCast(v)) < @as(I, @splat(0x20)))) |
        @as(B, @bitCast(v == @as(V, @splat('&')))) |
        // `<` (0x3C) and `>` (0x3E) are the two bytes with `b | 2 == 0x3E`
        @as(B, @bitCast((v | @as(V, @splat(2))) == @as(V, @splat('>')))) |
        quote;
    const k = std.simd.firstTrue(hits != @as(B, @splat(0))) orelse return null;
    return k;
}

/// Index of the first byte at or after `from` that `isSpecial`, or `s.len`.
fn nextSpecial(comptime attr: bool, s: []const u8, from: usize) usize {
    var i = from;
    while (i + vec_len <= s.len) : (i += vec_len) {
        if (firstSpecialIn(vec_len, attr, s[i..][0..vec_len])) |k| return i + k;
    }
    if (vec_len > 16) {
        while (i + 16 <= s.len) : (i += 16) {
            if (firstSpecialIn(16, attr, s[i..][0..16])) |k| return i + k;
        }
    }
    if (vec_len > 8 and i + 8 <= s.len) {
        if (firstSpecialIn(8, attr, s[i..][0..8])) |k| return i + k;
        i += 8;
    }
    while (i < s.len) : (i += 1) {
        if (isSpecial(attr, s[i])) return i;
    }
    return s.len;
}

/// Writes `s` escaped: `&` `<` `>` and CR always; in attributes (`attr`)
/// also `"`, TAB and LF. Returns the first character XML 1.0 cannot carry
/// instead (`w` then holds part of the value).
fn escape(comptime attr: bool, w: *Writer, s: []const u8) WriteError!?Bad {
    var run: usize = 0;
    var i: usize = 0;
    while (true) {
        i = nextSpecial(attr, s, i);
        if (i >= s.len) break;
        const c = s[i];
        const rep: []const u8 = switch (c) {
            '&' => "&amp;",
            '<' => "&lt;",
            '>' => "&gt;",
            '\r' => "&#13;",
            '"' => if (attr) "&quot;" else {
                i += 1;
                continue;
            },
            '\t' => if (attr) "&#9;" else {
                i += 1;
                continue;
            },
            '\n' => if (attr) "&#10;" else {
                i += 1;
                continue;
            },
            0x80...0xFF => {
                // the whole non-ASCII run, sequence by sequence
                while (i < s.len and s[i] >= 0x80) {
                    const d = utf8.decodeAt(s, i) orelse return .{ .cp = 0xFFFD, .invalid_utf8 = true };
                    if (d.cp == 0xFFFE or d.cp == 0xFFFF) return .{ .cp = d.cp };
                    i += d.len;
                }
                continue;
            },
            // the other control characters
            else => return .{ .cp = c },
        };
        try put(w, .{ s[run..i], rep });
        i += 1;
        run = i;
    }
    try w.writeAll(s[run..]);
    return null;
}

// =========================================================== size estimate
//
// Output capacity from the shape of the model (counts only, no strings
// read), yorc-rs's figures: an under-estimate costs a reallocation and
// a copy, an over-estimate only address space (and the final shrink).
// Calibrated on the real record (a work summary writes about 1.2 KiB
// besides its ids, an external id about 480 bytes, indentation included),
// rounded up.

const per_item = 1600;
const per_id = 560;

fn idsSize(ids: []const model.ExternalId) usize {
    return ids.len * per_id;
}

fn worksSize(w: *const model.Works) usize {
    var n: usize = 0;
    for (w.groups) |*g| {
        n += idsSize(g.external_ids);
        for (g.work_summaries) |*s| n += per_item + idsSize(s.external_ids);
    }
    return n;
}

fn fundingsSize(f: *const model.Fundings) usize {
    var n: usize = 0;
    for (f.groups) |*g| {
        n += idsSize(g.external_ids);
        for (g.funding_summaries) |*s| n += per_item + idsSize(s.external_ids);
    }
    return n;
}

fn affiliationsSize(a: *const model.Affiliations) usize {
    var n: usize = 0;
    for (a.groups) |*g| {
        n += idsSize(g.external_ids);
        for (g.summaries) |*s| n += per_item + idsSize(s.external_ids);
    }
    return n;
}

fn optAffiliationsSize(a: *const ?model.Affiliations) usize {
    return if (a.*) |*v| affiliationsSize(v) else 0;
}

fn peerReviewsSize(p: *const model.PeerReviews) usize {
    var n: usize = 0;
    for (p.groups) |*g| {
        n += idsSize(g.external_ids);
        for (g.duplicates) |*d| {
            n += idsSize(d.external_ids);
            for (d.summaries) |*s| n += per_item + idsSize(s.external_ids);
        }
    }
    return n;
}

fn researchResourcesSize(r: *const model.ResearchResources) usize {
    var n: usize = 0;
    for (r.groups) |*g| n += idsSize(g.external_ids) + g.summaries.len * per_item;
    return n;
}

fn activitiesSize(a: *const model.ActivitiesSummary) usize {
    var n = optAffiliationsSize(&a.distinctions) + optAffiliationsSize(&a.educations) +
        optAffiliationsSize(&a.employments) + optAffiliationsSize(&a.invited_positions) +
        optAffiliationsSize(&a.memberships) + optAffiliationsSize(&a.qualifications) +
        optAffiliationsSize(&a.services);
    if (a.works) |*w| n += worksSize(w);
    if (a.fundings) |*f| n += fundingsSize(f);
    if (a.peer_reviews) |*p| n += peerReviewsSize(p);
    if (a.research_resources) |*r| n += researchResourcesSize(r);
    return n;
}

fn personSize(p: *const model.Person) usize {
    var items: usize = 0;
    if (p.other_names) |l| items += l.items.len;
    if (p.researcher_urls) |l| items += l.items.len;
    if (p.emails) |l| items += l.items.len;
    if (p.addresses) |l| items += l.items.len;
    if (p.keywords) |l| items += l.items.len;
    if (p.external_identifiers) |l| items += l.items.len;
    var n: usize = 2048 + items * per_item;
    if (p.biography) |b| {
        if (b.content) |c| n += c.len;
    }
    return n;
}

fn estimate(root: *const model.Root) usize {
    return 4096 + switch (root.*) {
        .record => |*r| (if (r.person) |*p| personSize(p) else 0) +
            (if (r.activities_summary) |*a| activitiesSize(a) else 0),
        .activities_summary => |*a| activitiesSize(a),
        .works => |*w| worksSize(w),
        .fundings => |*f| fundingsSize(f),
        .affiliations => |*a| affiliationsSize(a),
        .peer_reviews => |*p| peerReviewsSize(p),
        .research_resources => |*r| researchResourcesSize(r),
        .person => |*p| personSize(p),
        .bulk => |*b| b.items.len * 4 * per_item,
        else => 0,
    };
}

// ================================================================== common

const E = Emitter;

fn metaAttrs(e: *E, m: *const model.ItemMeta) WriteError!void {
    if (m.put_code) |v| try e.attrInt("put-code", v);
    try e.attr("path", m.path);
    try e.attr("visibility", if (m.visibility) |v| v.text() else null);
    if (m.display_index_text) |t| {
        try e.attr("display-index", t);
    } else if (m.display_index) |v| {
        try e.attrInt("display-index", v);
    }
}

fn metaKids(e: *E, m: *const model.ItemMeta) WriteError!void {
    try e.leaf(.common, "created-date", m.created_date);
    try e.leaf(.common, "last-modified-date", m.last_modified_date);
    if (m.source) |*s| try source(e, s);
}

/// Begins an element with the item attributes and `element-summary` children.
fn item(e: *E, ns: Ns, name: []const u8, m: *const model.ItemMeta) WriteError!void {
    try e.begin(ns, name);
    try metaAttrs(e, m);
    try metaKids(e, m);
}

fn identifier(e: *E, ns: Ns, name: []const u8, id: *const model.OrcidIdentifier) WriteError!void {
    try e.begin(ns, name);
    try e.leaf(.common, "uri", id.uri);
    try e.leaf(.common, "path", id.path);
    try e.leaf(.common, "host", id.host);
    try e.end();
}

fn optIdentifier(e: *E, ns: Ns, name: []const u8, id: *const ?model.OrcidIdentifier) WriteError!void {
    if (id.*) |*v| try identifier(e, ns, name, v);
}

fn source(e: *E, s: *const model.Source) WriteError!void {
    try e.begin(.common, "source");
    try optIdentifier(e, .common, "source-orcid", &s.source_orcid);
    try optIdentifier(e, .common, "source-client-id", &s.source_client_id);
    try e.leaf(.common, "source-name", s.source_name);
    try optIdentifier(e, .common, "assertion-origin-orcid", &s.assertion_origin_orcid);
    try optIdentifier(e, .common, "assertion-origin-client-id", &s.assertion_origin_client_id);
    try e.leaf(.common, "assertion-origin-name", s.assertion_origin_name);
    try e.end();
}

fn date(e: *E, ns: Ns, name: []const u8, d: *const ?model.FuzzyDate) WriteError!void {
    const v = d.* orelse return;
    try e.begin(ns, name);
    var buf: [24]u8 = undefined;
    if (v.year) |y| try e.leafRaw(.common, "year", padInt(&buf, y, 4));
    if (v.month) |m| try e.leafRaw(.common, "month", padInt(&buf, m, 2));
    if (v.day) |day| try e.leafRaw(.common, "day", padInt(&buf, day, 2));
    try e.end();
}

fn organization(e: *E, ns: Ns, name: []const u8, o: *const model.Organization) WriteError!void {
    try e.begin(ns, name);
    try e.leaf(.common, "name", o.name);
    if (o.address) |*a| {
        try e.begin(.common, "address");
        try e.leaf(.common, "city", a.city);
        try e.leaf(.common, "region", a.region);
        try e.leaf(.common, "country", a.country);
        try e.end();
    }
    if (o.disambiguated_organization) |*d| {
        try e.begin(.common, "disambiguated-organization");
        try e.leaf(.common, "disambiguated-organization-identifier", d.identifier);
        try e.leaf(.common, "disambiguation-source", d.source);
        try e.end();
    }
    try e.end();
}

fn optOrganization(e: *E, ns: Ns, name: []const u8, o: *const ?model.Organization) WriteError!void {
    if (o.*) |*v| try organization(e, ns, name, v);
}

fn externalId(e: *E, ns: Ns, name: []const u8, x: *const model.ExternalId) WriteError!void {
    try item(e, ns, name, &x.meta);
    try e.leaf(.common, "external-id-type", x.id_type);
    try e.leaf(.common, "external-id-value", x.value);
    if (x.normalized) |*t| {
        try e.begin(.common, "external-id-normalized");
        try e.attrBool("transient", t.transient);
        try e.endWith(t.value);
    }
    if (x.normalized_error) |*er| {
        try e.begin(.common, "external-id-normalized-error");
        try e.attrBool("transient", er.transient);
        try e.leaf(.common, "error-code", er.error_code);
        try e.leaf(.common, "error-message", er.error_message);
        try e.end();
    }
    try e.leaf(.common, "external-id-url", x.url);
    try e.leafVocab(.common, "external-id-relationship", x.relationship);
    try e.end();
}

/// `<ns:name>` holding `common:external-id` children (always written).
fn externalIdsIn(e: *E, ns: Ns, name: []const u8, ids: []const model.ExternalId) WriteError!void {
    try e.begin(ns, name);
    for (ids) |*x| try externalId(e, .common, "external-id", x);
    try e.end();
}

/// `common:external-ids`, always written (groups, proposals, resource items).
fn externalIds(e: *E, ids: []const model.ExternalId) WriteError!void {
    return externalIdsIn(e, .common, "external-ids", ids);
}

/// `common:external-ids`, written only when there is at least one id.
fn optExternalIds(e: *E, ids: []const model.ExternalId) WriteError!void {
    if (ids.len > 0) try externalIds(e, ids);
}

fn title(e: *E, ns: Ns, name: []const u8, t: *const ?model.Title) WriteError!void {
    const v = if (t.*) |*x| x else return;
    try e.begin(ns, name);
    try e.leaf(.common, "title", v.title);
    try e.leaf(.common, "subtitle", v.subtitle);
    if (v.translated_title) |*tt| {
        try e.begin(.common, "translated-title");
        try e.attr("language-code", tt.language_code);
        try e.endWith(tt.value);
    }
    try e.end();
}

fn contributor(e: *E, ns: Ns, c: *const model.Contributor) WriteError!void {
    try e.begin(ns, "contributor");
    try optIdentifier(e, .common, "contributor-orcid", &c.contributor_orcid);
    try e.leaf(ns, "credit-name", c.credit_name);
    try e.leaf(ns, "contributor-email", c.contributor_email);
    if (c.attributes) |*a| {
        try e.begin(ns, "contributor-attributes");
        if (ns == .funding) {
            if (a.sequence != null) return e.unwritable("contributor-sequence", "a funding contributor has no contributor-sequence (funding-3.0.xsd)", null);
        } else {
            try e.leafVocab(ns, "contributor-sequence", a.sequence);
        }
        try e.leafVocab(ns, "contributor-role", a.role);
        try e.end();
    }
    try e.end();
}

fn optContributors(e: *E, ns: Ns, cs: []const model.Contributor) WriteError!void {
    if (cs.len == 0) return;
    try e.begin(ns, "contributors");
    for (cs) |*c| try contributor(e, ns, c);
    try e.end();
}

/// Begins `<ns:name path=...>` with `common:last-modified-date`.
fn container(e: *E, ns: Ns, name: []const u8, path: ?Text, lmd: ?Text) WriteError!void {
    try e.begin(ns, name);
    try e.attr("path", path);
    try e.leaf(.common, "last-modified-date", lmd);
}

/// Begins a group: `common:last-modified-date`, `common:external-ids` (always).
fn group(e: *E, name: []const u8, lmd: ?Text, ids: []const model.ExternalId) WriteError!void {
    try e.begin(.activities, name);
    try e.leaf(.common, "last-modified-date", lmd);
    try externalIds(e, ids);
}

// =================================================================== works

fn work(e: *E, w: *const model.Work) WriteError!void {
    try item(e, .work, "work", &w.meta);
    try title(e, .work, "title", &w.title);
    try e.leaf(.work, "journal-title", w.journal_title);
    try e.leaf(.work, "short-description", w.short_description);
    if (w.citation) |*c| {
        try e.begin(.work, "citation");
        try e.leafVocab(.work, "citation-type", c.citation_type);
        try e.leaf(.work, "citation-value", c.citation_value);
        try e.end();
    }
    try e.leafVocab(.work, "type", w.work_type);
    try date(e, .common, "publication-date", &w.publication_date);
    try optExternalIds(e, w.external_ids);
    try e.leaf(.common, "url", w.url);
    try optContributors(e, .work, w.contributors);
    try e.leaf(.common, "language-code", w.language_code);
    if (w.country) |*c| {
        try e.begin(.common, "country");
        try e.attr("visibility", if (c.visibility) |v| v.text() else null);
        try e.endWith(c.value);
    }
    try e.end();
}

fn workSummary(e: *E, w: *const model.WorkSummary) WriteError!void {
    try item(e, .work, "work-summary", &w.meta);
    try title(e, .work, "title", &w.title);
    try optExternalIds(e, w.external_ids);
    try e.leaf(.common, "url", w.url);
    try e.leafVocab(.work, "type", w.work_type);
    try date(e, .common, "publication-date", &w.publication_date);
    try e.leaf(.work, "journal-title", w.journal_title);
    try e.end();
}

fn works(e: *E, w: *const model.Works) WriteError!void {
    try container(e, .activities, "works", w.path, w.last_modified_date);
    for (w.groups) |*g| {
        try group(e, "group", g.last_modified_date, g.external_ids);
        for (g.work_summaries) |*s| try workSummary(e, s);
        try e.end();
    }
    try e.end();
}

// ================================================================ fundings

fn funding(e: *E, f: *const model.Funding) WriteError!void {
    try item(e, .funding, "funding", &f.meta);
    try e.leafVocab(.funding, "type", f.funding_type);
    try e.leaf(.funding, "organization-defined-type", f.organization_defined_type);
    try title(e, .funding, "title", &f.title);
    try e.leaf(.funding, "short-description", f.short_description);
    if (f.amount) |*a| {
        try e.begin(.funding, "amount");
        try e.attr("currency-code", a.currency_code);
        try e.endWith(a.value);
    }
    try e.leaf(.common, "url", f.url);
    try date(e, .common, "start-date", &f.start_date);
    try date(e, .common, "end-date", &f.end_date);
    try optExternalIds(e, f.external_ids);
    try optContributors(e, .funding, f.contributors);
    try optOrganization(e, .common, "organization", &f.organization);
    try e.end();
}

fn fundingSummary(e: *E, f: *const model.FundingSummary) WriteError!void {
    try item(e, .funding, "funding-summary", &f.meta);
    try title(e, .funding, "title", &f.title);
    try optExternalIds(e, f.external_ids);
    try e.leaf(.common, "url", f.url);
    try e.leafVocab(.funding, "type", f.funding_type);
    try date(e, .common, "start-date", &f.start_date);
    try date(e, .common, "end-date", &f.end_date);
    try optOrganization(e, .common, "organization", &f.organization);
    try e.end();
}

fn fundings(e: *E, f: *const model.Fundings) WriteError!void {
    try container(e, .activities, "fundings", f.path, f.last_modified_date);
    for (f.groups) |*g| {
        try group(e, "group", g.last_modified_date, g.external_ids);
        for (g.funding_summaries) |*s| try fundingSummary(e, s);
        try e.end();
    }
    try e.end();
}

// ============================================================ affiliations

fn affiliation(e: *E, a: *const model.Affiliation, summary: bool) WriteError!void {
    const name = if (summary) a.kind.summaryElement() else a.kind.element();
    try item(e, Ns.ofAffiliation(a.kind), name, &a.meta);
    try e.leaf(.common, "department-name", a.department_name);
    try e.leaf(.common, "role-title", a.role_title);
    try date(e, .common, "start-date", &a.start_date);
    try date(e, .common, "end-date", &a.end_date);
    try optOrganization(e, .common, "organization", &a.organization);
    try e.leaf(.common, "url", a.url);
    try optExternalIds(e, a.external_ids);
    try e.end();
}

fn affiliations(e: *E, a: *const model.Affiliations) WriteError!void {
    try container(e, .activities, a.kind.containerElement(), a.path, a.last_modified_date);
    for (a.groups) |*g| {
        try group(e, "affiliation-group", g.last_modified_date, g.external_ids);
        for (g.summaries) |*s| try affiliation(e, s, true);
        try e.end();
    }
    try e.end();
}

fn optAffiliations(e: *E, a: *const ?model.Affiliations) WriteError!void {
    if (a.*) |*v| try affiliations(e, v);
}

// ============================================================ peer reviews

fn peerReviewSummary(e: *E, p: *const model.PeerReviewSummary) WriteError!void {
    try item(e, .peer_review, "peer-review-summary", &p.meta);
    try e.leafVocab(.peer_review, "reviewer-role", p.reviewer_role);
    try optExternalIds(e, p.external_ids);
    try e.leaf(.peer_review, "review-url", p.review_url);
    try e.leafVocab(.peer_review, "review-type", p.review_type);
    try date(e, .peer_review, "completion-date", &p.completion_date);
    try e.leaf(.peer_review, "review-group-id", p.review_group_id);
    try optOrganization(e, .peer_review, "convening-organization", &p.convening_organization);
    try e.end();
}

fn peerReview(e: *E, p: *const model.PeerReview) WriteError!void {
    try item(e, .peer_review, "peer-review", &p.meta);
    try e.leafVocab(.peer_review, "reviewer-role", p.reviewer_role);
    try externalIdsIn(e, .peer_review, "review-identifiers", p.review_identifiers);
    try e.leaf(.peer_review, "review-url", p.review_url);
    try e.leafVocab(.peer_review, "review-type", p.review_type);
    try date(e, .peer_review, "review-completion-date", &p.review_completion_date);
    try e.leaf(.peer_review, "review-group-id", p.review_group_id);
    if (p.subject_external_identifier) |*x| try externalId(e, .peer_review, "subject-external-identifier", x);
    try e.leaf(.peer_review, "subject-container-name", p.subject_container_name);
    try e.leaf(.peer_review, "subject-type", p.subject_type);
    try title(e, .peer_review, "subject-name", &p.subject_name);
    try e.leaf(.peer_review, "subject-url", p.subject_url);
    try optOrganization(e, .peer_review, "convening-organization", &p.convening_organization);
    try e.end();
}

fn peerReviews(e: *E, p: *const model.PeerReviews) WriteError!void {
    try container(e, .activities, "peer-reviews", p.path, p.last_modified_date);
    for (p.groups) |*g| {
        try group(e, "group", g.last_modified_date, g.external_ids);
        for (g.duplicates) |*d| {
            try group(e, "peer-review-group", d.last_modified_date, d.external_ids);
            for (d.summaries) |*s| try peerReviewSummary(e, s);
            try e.end();
        }
        try e.end();
    }
    try e.end();
}

// ====================================================== research resources

fn hosts(e: *E, orgs: []const model.Organization) WriteError!void {
    try e.begin(.research_resource, "hosts");
    for (orgs) |*o| try organization(e, .common, "organization", o);
    try e.end();
}

fn proposal(e: *E, p: *const model.Proposal) WriteError!void {
    try e.begin(.research_resource, "proposal");
    try title(e, .research_resource, "title", &p.title);
    try hosts(e, p.hosts);
    try externalIds(e, p.external_ids);
    try date(e, .common, "start-date", &p.start_date);
    try date(e, .common, "end-date", &p.end_date);
    try e.leaf(.common, "url", p.url);
    try e.end();
}

fn resourceItem(e: *E, r: *const model.ResourceItem) WriteError!void {
    try e.begin(.research_resource, "resource-item");
    try e.leaf(.research_resource, "resource-name", r.resource_name);
    try e.leafVocab(.research_resource, "resource-type", r.resource_type);
    try hosts(e, r.hosts);
    try externalIds(e, r.external_ids);
    try e.leaf(.common, "url", r.url);
    try e.end();
}

fn researchResource(e: *E, r: *const model.ResearchResource) WriteError!void {
    try item(e, .research_resource, "research-resource", &r.meta);
    if (r.proposal) |*p| try proposal(e, p);
    try e.begin(.research_resource, "resource-items");
    for (r.resource_items) |*i| try resourceItem(e, i);
    try e.end();
    try e.end();
}

fn researchResourceSummary(e: *E, r: *const model.ResearchResourceSummary) WriteError!void {
    try item(e, .research_resource, "research-resource-summary", &r.meta);
    if (r.proposal) |*p| try proposal(e, p);
    try e.end();
}

fn researchResources(e: *E, r: *const model.ResearchResources) WriteError!void {
    try container(e, .activities, "research-resources", r.path, r.last_modified_date);
    for (r.groups) |*g| {
        try group(e, "group", g.last_modified_date, g.external_ids);
        for (g.summaries) |*s| try researchResourceSummary(e, s);
        try e.end();
    }
    try e.end();
}

fn activitiesSummary(e: *E, a: *const model.ActivitiesSummary) WriteError!void {
    try container(e, .activities, "activities-summary", a.path, a.last_modified_date);
    try optAffiliations(e, &a.distinctions);
    try optAffiliations(e, &a.educations);
    try optAffiliations(e, &a.employments);
    if (a.fundings) |*f| try fundings(e, f);
    try optAffiliations(e, &a.invited_positions);
    try optAffiliations(e, &a.memberships);
    if (a.peer_reviews) |*p| try peerReviews(e, p);
    try optAffiliations(e, &a.qualifications);
    if (a.research_resources) |*r| try researchResources(e, r);
    try optAffiliations(e, &a.services);
    if (a.works) |*w| try works(e, w);
    try e.end();
}

// ================================================================== person

fn personName(e: *E, ns: Ns, n: *const model.Name) WriteError!void {
    try e.begin(ns, "name");
    try e.attr("visibility", if (n.visibility) |v| v.text() else null);
    try e.attr("path", n.path);
    try e.leaf(.common, "created-date", n.created_date);
    try e.leaf(.common, "last-modified-date", n.last_modified_date);
    try e.leaf(.personal_details, "given-names", n.given_names);
    try e.leaf(.personal_details, "family-name", n.family_name);
    try e.leaf(.personal_details, "credit-name", n.credit_name);
    try e.end();
}

fn biography(e: *E, ns: Ns, b: *const model.Biography) WriteError!void {
    try e.begin(ns, "biography");
    try e.attr("visibility", if (b.visibility) |v| v.text() else null);
    try e.attr("path", b.path);
    try e.leaf(.common, "created-date", b.created_date);
    try e.leaf(.common, "last-modified-date", b.last_modified_date);
    try e.leaf(.personal_details, "content", b.content);
    try e.end();
}

fn otherName(e: *E, x: *const model.OtherName) WriteError!void {
    try item(e, .other_name, "other-name", &x.meta);
    try e.leaf(.other_name, "content", x.content);
    try e.end();
}

fn researcherUrl(e: *E, x: *const model.ResearcherUrl) WriteError!void {
    try item(e, .researcher_url, "researcher-url", &x.meta);
    try e.leaf(.researcher_url, "url-name", x.url_name);
    try e.leaf(.researcher_url, "url", x.url);
    try e.end();
}

fn email(e: *E, x: *const model.Email) WriteError!void {
    try e.begin(.email, "email");
    try metaAttrs(e, &x.meta);
    try e.attrBool("verified", x.verified);
    try e.attrBool("primary", x.primary);
    try metaKids(e, &x.meta);
    try e.leaf(.email, "email", x.email);
    try e.end();
}

fn address(e: *E, x: *const model.Address) WriteError!void {
    try item(e, .address, "address", &x.meta);
    try e.leaf(.address, "country", x.country);
    try e.end();
}

fn keyword(e: *E, x: *const model.Keyword) WriteError!void {
    try item(e, .keyword, "keyword", &x.meta);
    try e.leaf(.keyword, "content", x.content);
    try e.end();
}

fn personExternalIdentifier(e: *E, x: *const model.ExternalId) WriteError!void {
    return externalId(e, .external_identifier, "external-identifier", x);
}

fn itemList(
    comptime T: type,
    e: *E,
    ns: Ns,
    tag: []const u8,
    l: *const model.ItemList(T),
    comptime each: fn (*E, *const T) WriteError!void,
) WriteError!void {
    try container(e, ns, tag, l.path, l.last_modified_date);
    for (l.items) |*x| try each(e, x);
    try e.end();
}

fn otherNames(e: *E, l: *const model.OtherNames) WriteError!void {
    return itemList(model.OtherName, e, .other_name, "other-names", l, otherName);
}
fn researcherUrls(e: *E, l: *const model.ResearcherUrls) WriteError!void {
    return itemList(model.ResearcherUrl, e, .researcher_url, "researcher-urls", l, researcherUrl);
}
fn emails(e: *E, l: *const model.Emails) WriteError!void {
    return itemList(model.Email, e, .email, "emails", l, email);
}
fn addresses(e: *E, l: *const model.Addresses) WriteError!void {
    return itemList(model.Address, e, .address, "addresses", l, address);
}
fn keywords(e: *E, l: *const model.Keywords) WriteError!void {
    return itemList(model.Keyword, e, .keyword, "keywords", l, keyword);
}
fn externalIdentifiers(e: *E, l: *const model.ExternalIdentifiers) WriteError!void {
    return itemList(model.ExternalId, e, .external_identifier, "external-identifiers", l, personExternalIdentifier);
}

fn person(e: *E, p: *const model.Person) WriteError!void {
    try container(e, .person, "person", p.path, p.last_modified_date);
    if (p.name) |*x| try personName(e, .person, x);
    if (p.other_names) |*x| try otherNames(e, x);
    if (p.biography) |*x| try biography(e, .person, x);
    if (p.researcher_urls) |*x| try researcherUrls(e, x);
    if (p.emails) |*x| try emails(e, x);
    if (p.addresses) |*x| try addresses(e, x);
    if (p.keywords) |*x| try keywords(e, x);
    if (p.external_identifiers) |*x| try externalIdentifiers(e, x);
    try e.end();
}

fn personalDetails(e: *E, p: *const model.PersonalDetails) WriteError!void {
    try container(e, .personal_details, "personal-details", p.path, p.last_modified_date);
    if (p.name) |*x| try personName(e, .personal_details, x);
    if (p.other_names) |*x| try otherNames(e, x);
    if (p.biography) |*x| try biography(e, .personal_details, x);
    try e.end();
}

// ================================================================== record

fn history(e: *E, h: *const model.History) WriteError!void {
    try e.begin(.history, "history");
    try e.attr("visibility", if (h.visibility) |v| v.text() else null);
    try e.leafVocab(.history, "creation-method", h.creation_method);
    try e.leaf(.history, "completion-date", h.completion_date);
    try e.leaf(.history, "submission-date", h.submission_date);
    try e.leaf(.common, "last-modified-date", h.last_modified_date);
    try e.leafBool(.history, "claimed", h.claimed);
    if (h.source) |*s| try source(e, s);
    try e.leaf(.history, "deactivation-date", h.deactivation_date);
    try e.leafBool(.history, "verified-email", h.verified_email);
    try e.leafBool(.history, "verified-primary-email", h.verified_primary_email);
    try e.end();
}

fn preferences(e: *E, p: *const model.Preferences) WriteError!void {
    try e.begin(.preferences, "preferences");
    try e.leaf(.preferences, "locale", p.locale);
    try e.end();
}

fn record(e: *E, r: *const model.Record) WriteError!void {
    try e.begin(.record, "record");
    try e.attr("path", r.path);
    try optIdentifier(e, .common, "orcid-identifier", &r.orcid_identifier);
    if (r.preferences) |*p| try preferences(e, p);
    if (r.history) |*h| try history(e, h);
    if (r.person) |*p| try person(e, p);
    if (r.activities_summary) |*a| try activitiesSummary(e, a);
    try e.end();
}

fn orcidError(e: *E, x: *const model.OrcidError) WriteError!void {
    try e.begin(.@"error", "error");
    try e.leafInt(.@"error", "response-code", x.response_code);
    try e.leaf(.@"error", "developer-message", x.developer_message);
    try e.leaf(.@"error", "user-message", x.user_message);
    try e.leafInt(.@"error", "error-code", x.error_code);
    try e.leaf(.@"error", "more-info", x.more_info);
    try e.end();
}

fn bulk(e: *E, b: *const model.Bulk) WriteError!void {
    try e.begin(.bulk, "bulk");
    for (b.items) |*i| switch (i.*) {
        .work => |*w| try work(e, w),
        .@"error" => |*x| try orcidError(e, x),
    };
    try e.end();
}

fn search(e: *E, s: *const model.Search) WriteError!void {
    try e.begin(.search, "search");
    if (s.num_found) |v| try e.attrInt("num-found", v);
    for (s.results) |*r| {
        try e.begin(.search, "result");
        try identifier(e, .common, "orcid-identifier", r);
        try e.end();
    }
    try e.end();
}

fn expandedSearch(e: *E, s: *const model.ExpandedSearch) WriteError!void {
    const ns: Ns = .expanded_search;
    try e.begin(ns, "expanded-search");
    if (s.num_found) |v| try e.attrInt("num-found", v);
    for (s.results) |*r| {
        try e.begin(ns, "expanded-result");
        try e.leaf(ns, "orcid-id", r.orcid_id);
        try e.leaf(ns, "given-names", r.given_names);
        try e.leaf(ns, "family-names", r.family_names);
        try e.leaf(ns, "credit-name", r.credit_name);
        for (r.other_names) |v| try e.leaf(ns, "other-name", v);
        for (r.emails) |v| try e.leaf(ns, "email", v);
        for (r.institution_names) |v| try e.leaf(ns, "institution-name", v);
        try e.end();
    }
    try e.end();
}

fn rootNode(e: *E, root: *const model.Root) WriteError!void {
    switch (root.*) {
        .record => |*x| try record(e, x),
        .activities_summary => |*x| try activitiesSummary(e, x),
        .works => |*x| try works(e, x),
        .work => |*x| try work(e, x),
        .work_summary => |*x| try workSummary(e, x),
        .fundings => |*x| try fundings(e, x),
        .funding => |*x| try funding(e, x),
        .funding_summary => |*x| try fundingSummary(e, x),
        .affiliations => |*x| try affiliations(e, x),
        .affiliation => |*x| try affiliation(e, x, false),
        .affiliation_summary => |*x| try affiliation(e, x, true),
        .peer_reviews => |*x| try peerReviews(e, x),
        .peer_review => |*x| try peerReview(e, x),
        .peer_review_summary => |*x| try peerReviewSummary(e, x),
        .research_resources => |*x| try researchResources(e, x),
        .research_resource => |*x| try researchResource(e, x),
        .research_resource_summary => |*x| try researchResourceSummary(e, x),
        .person => |*x| try person(e, x),
        .personal_details => |*x| try personalDetails(e, x),
        .name => |*x| try personName(e, .personal_details, x),
        .biography => |*x| try biography(e, .personal_details, x),
        .credit_name => |x| {
            try e.begin(.personal_details, "credit-name");
            try e.endWith(x);
        },
        .other_names => |*x| try otherNames(e, x),
        .other_name => |*x| try otherName(e, x),
        .researcher_urls => |*x| try researcherUrls(e, x),
        .researcher_url => |*x| try researcherUrl(e, x),
        .emails => |*x| try emails(e, x),
        .email => |*x| try email(e, x),
        .addresses => |*x| try addresses(e, x),
        .address => |*x| try address(e, x),
        .keywords => |*x| try keywords(e, x),
        .keyword => |*x| try keyword(e, x),
        .external_identifiers => |*x| try externalIdentifiers(e, x),
        .external_identifier => |*x| try personExternalIdentifier(e, x),
        .history => |*x| try history(e, x),
        .preferences => |*x| try preferences(e, x),
        .bulk => |*x| try bulk(e, x),
        .@"error" => |*x| try orcidError(e, x),
        .search => |*x| try search(e, x),
        .expanded_search => |*x| try expandedSearch(e, x),
        // written by `write` / `toOwned` without this emitter (see "group ids")
        .group_id_record, .group_id_records => {
            if (e.diag) |d| {
                d.setPath(root.kind().?);
                d.message = "group-id documents are written by write and toOwned";
                d.code_point = null;
            }
            return error.Unwritable;
        },
        .unknown => |n| {
            if (e.diag) |d| {
                d.setPath(n);
                d.message = "unknown root element";
                d.code_point = null;
            }
            return error.Unwritable;
        },
    }
}

// ================================================================= driving

/// One document from its generator.
fn Generator(comptime Ctx: type, comptime gen: fn (*E, Ctx) WriteError!void) type {
    return struct {
        /// Into any writer: a dry run into a discarding writer for the
        /// namespaces (and any error, before `w` sees a byte), then the
        /// document, declaring them as the root is written.
        fn into(w: *Writer, ctx: Ctx, diag: ?*Diagnostic) WriteError!void {
            var scratch: [1024]u8 = undefined;
            var discarding: Writer.Discarding = .init(&scratch);
            var probe: E = .{ .w = &discarding.writer, .diag = diag };
            try gen(&probe, ctx);
            var out: E = .{ .w = w, .diag = diag, .declare = probe.used };
            try w.writeAll(xml_decl);
            try gen(&out, ctx);
        }

        /// One pass into a buffer of `size_hint` bytes (plus the XML
        /// declaration and room for the namespace declarations), which are
        /// inserted after the root's name at the end.
        fn owned(gpa: std.mem.Allocator, ctx: Ctx, diag: ?*Diagnostic, size_hint: usize) (WriteError || error{OutOfMemory})![]u8 {
            var aw = try Writer.Allocating.initCapacity(gpa, xml_decl.len + size_hint + decl_room);
            defer aw.deinit();
            var e: E = .{ .w = &aw.writer, .diag = diag };
            aw.writer.writeAll(xml_decl) catch return error.OutOfMemory;
            gen(&e, ctx) catch |err| switch (err) {
                // Allocating reports allocation failure as WriteFailed
                error.WriteFailed => return error.OutOfMemory,
                error.Unwritable => return error.Unwritable,
            };
            try insertDeclarations(&aw, e.root_end, e.used);
            return aw.toOwnedSlice();
        }
    };
}

const RootDocument = Generator(*const model.Root, rootNode);

/// Writes any document root as ORCID v3.0 XML, exactly as the model holds it
/// (no validation; this is what the round-trip tests use). Nothing is
/// written if it fails with `error.Unwritable`.
pub fn write(w: *Writer, root: *const model.Root, diag: ?*Diagnostic) WriteError!void {
    if (groupIdDoc(root)) |doc| return groupIdInto(w, doc, diag);
    return RootDocument.into(w, root, diag);
}

/// `write` into a new allocated buffer (caller frees), in one pass.
pub fn toOwned(gpa: std.mem.Allocator, root: *const model.Root, diag: ?*Diagnostic) (WriteError || error{OutOfMemory})![]u8 {
    if (groupIdDoc(root)) |doc| {
        var aw: Writer.Allocating = .init(gpa);
        defer aw.deinit();
        groupIdInto(&aw.writer, doc, diag) catch |err| switch (err) {
            // Allocating reports allocation failure as WriteFailed
            error.WriteFailed => return error.OutOfMemory,
            error.Unwritable => return error.Unwritable,
        };
        return aw.toOwnedSlice();
    }
    return RootDocument.owned(gpa, root, diag, estimate(root));
}

// =============================================================== group ids
//
// group-id-3.0 documents (`group-id-record`, `group-id-records`). Their
// `group-id` namespace is not one of `Ns` (the record namespaces), so they
// are written by this small emitter rather than by `Emitter`, which stays
// as it is, with the same layout: the XML declaration, two-space
// indentation, `<x/>` for an element with no content, the namespaces used
// declared on the root in prefix order (`common` before `group-id`) before
// its attributes, the same escaping. Elements follow ORCID's `GroupIdRecord`
// (`propOrder`): `common:last-modified-date`, `common:created-date`, `name`,
// `group-id`, `description`, `type`, `common:source`; the page is
// `common:last-modified-date`, `total`, `page`, `page-size`, then the
// records. The same bytes as yorc-rs's `xml/write/group_id.rs`. Like
// `write`, a dry run into a discarding writer first finds the namespaces
// and any error, so nothing reaches `w` when the model is unwritable.

const common_q = "common:";
const group_id_q = "group-id:";

const GroupIdDoc = union(enum) {
    record: *const model.GroupIdRecord,
    records: *const model.GroupIdRecords,
};

fn groupIdDoc(root: *const model.Root) ?GroupIdDoc {
    return switch (root.*) {
        .group_id_record => |*r| .{ .record = r },
        .group_id_records => |*r| .{ .records = r },
        else => null,
    };
}

const GOpen = struct { q: []const u8, name: []const u8 };

const G = struct {
    w: *Writer,
    diag: ?*Diagnostic,
    /// Whether to declare `common` on the root (known from the dry run);
    /// null in the dry run, which declares nothing.
    declare: ?bool = null,
    /// A `common:` element was written.
    common: bool = false,
    open: [8]GOpen = undefined,
    depth: usize = 0,
    pending: bool = false,

    fn closing(g: *G) []const u8 {
        if (!g.pending) return "";
        g.pending = false;
        return ">\n";
    }

    fn indent(g: *const G) []const u8 {
        return indent_spaces[0 .. 2 * g.depth];
    }

    fn note(g: *G, q: []const u8) void {
        if (std.mem.eql(u8, q, common_q)) g.common = true;
    }

    fn badText(g: *const G, name: []const u8, bad: Bad) WriteError {
        if (g.diag) |d| {
            d.path_len = 0;
            for (g.open[0..g.depth]) |o| d.pushPath(o.name);
            d.pushPath(name);
            d.message = bad.reason();
            d.code_point = bad.cp;
        }
        return error.Unwritable;
    }

    fn begin(g: *G, q: []const u8, name: []const u8) WriteError!void {
        if (g.depth >= g.open.len) return error.Unwritable;
        g.note(q);
        try put(g.w, .{ g.closing(), g.indent(), "<", q, name });
        if (g.depth == 0) {
            if (g.declare) |with_common| {
                if (with_common) try g.w.writeAll(" xmlns:common=\"" ++ Ns.uri_base ++ "common\"");
                try g.w.writeAll(" xmlns:group-id=\"" ++ Ns.uri_base ++ "group-id\"");
            }
        }
        g.open[g.depth] = .{ .q = q, .name = name };
        g.depth += 1;
        g.pending = true;
    }

    fn attrInt(g: *G, name: []const u8, value: ?i64) WriteError!void {
        const v = value orelse return;
        var buf: [24]u8 = undefined;
        try put(g.w, .{ " ", name, "=\"", padInt(&buf, v, 0), "\"" });
    }

    fn end(g: *G) WriteError!void {
        g.depth -= 1;
        const o = g.open[g.depth];
        if (g.pending) {
            g.pending = false;
            try g.w.writeAll("/>\n");
            return;
        }
        try put(g.w, .{ g.indent(), "</", o.q, o.name, ">\n" });
    }

    fn leaf(g: *G, q: []const u8, name: []const u8, value: ?[]const u8) WriteError!void {
        const v = value orelse return;
        g.note(q);
        try put(g.w, .{ g.closing(), g.indent(), "<", q, name, ">" });
        if (try escape(false, g.w, v)) |bad| return g.badText(name, bad);
        try put(g.w, .{ "</", q, name, ">\n" });
    }

    fn leafInt(g: *G, q: []const u8, name: []const u8, value: ?i64) WriteError!void {
        const v = value orelse return;
        var buf: [24]u8 = undefined;
        g.note(q);
        try put(g.w, .{ g.closing(), g.indent(), "<", q, name, ">", padInt(&buf, v, 0), "</", q, name, ">\n" });
    }

    fn writeIdentifier(g: *G, name: []const u8, id: *const ?model.OrcidIdentifier) WriteError!void {
        const v = if (id.*) |*x| x else return;
        try g.begin(common_q, name);
        try g.leaf(common_q, "uri", v.uri);
        try g.leaf(common_q, "path", v.path);
        try g.leaf(common_q, "host", v.host);
        try g.end();
    }

    /// `common:source`, as the record writer writes it.
    fn writeSource(g: *G, s: *const model.Source) WriteError!void {
        try g.begin(common_q, "source");
        try g.writeIdentifier("source-orcid", &s.source_orcid);
        try g.writeIdentifier("source-client-id", &s.source_client_id);
        try g.leaf(common_q, "source-name", s.source_name);
        try g.writeIdentifier("assertion-origin-orcid", &s.assertion_origin_orcid);
        try g.writeIdentifier("assertion-origin-client-id", &s.assertion_origin_client_id);
        try g.leaf(common_q, "assertion-origin-name", s.assertion_origin_name);
        try g.end();
    }

    fn writeRecord(g: *G, r: *const model.GroupIdRecord) WriteError!void {
        try g.begin(group_id_q, "group-id-record");
        try g.attrInt("put-code", r.put_code);
        try g.leaf(common_q, "last-modified-date", r.last_modified_date);
        try g.leaf(common_q, "created-date", r.created_date);
        try g.leaf(group_id_q, "name", r.name);
        try g.leaf(group_id_q, "group-id", r.group_id);
        try g.leaf(group_id_q, "description", r.description);
        try g.leaf(group_id_q, "type", if (r.group_type) |t| t.text() else null);
        if (r.source) |*src| try g.writeSource(src);
        try g.end();
    }

    fn document(g: *G, doc: GroupIdDoc) WriteError!void {
        switch (doc) {
            .record => |r| try g.writeRecord(r),
            .records => |pg| {
                try g.begin(group_id_q, "group-id-records");
                try g.leaf(common_q, "last-modified-date", pg.last_modified_date);
                try g.leafInt(group_id_q, "total", pg.total);
                try g.leafInt(group_id_q, "page", pg.page);
                try g.leafInt(group_id_q, "page-size", pg.page_size);
                for (pg.records) |*r| try g.writeRecord(r);
                try g.end();
            },
        }
    }
};

fn groupIdInto(w: *Writer, doc: GroupIdDoc, diag: ?*Diagnostic) WriteError!void {
    var scratch: [1024]u8 = undefined;
    var discarding: Writer.Discarding = .init(&scratch);
    var probe: G = .{ .w = &discarding.writer, .diag = diag };
    try probe.document(doc);
    var out: G = .{ .w = w, .diag = diag, .declare = probe.common };
    try w.writeAll(xml_decl);
    try out.document(doc);
}

// ================================================================== tests

const testing = std.testing;

test "deterministic layout and escaping" {
    const root: model.Root = .{ .keyword = .{
        .meta = .{ .put_code = 7, .visibility = .{ .known = .public } },
        .content = "R&D <x> \"q\"",
    } };
    const xml = try toOwned(testing.allocator, &root, null);
    defer testing.allocator.free(xml);
    try testing.expectEqualStrings(
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n" ++
            "<keyword:keyword xmlns:keyword=\"http://www.orcid.org/ns/keyword\" put-code=\"7\" visibility=\"public\">\n" ++
            "  <keyword:content>R&amp;D &lt;x&gt; \"q\"</keyword:content>\n" ++
            "</keyword:keyword>\n",
        xml,
    );
}

test "dates are padded and namespaces declared in order" {
    const gpa = testing.allocator;
    const a: model.Root = .{ .address = .{
        .country = "US",
        .meta = .{ .source = .{ .source_name = "x" } },
    } };
    const x1 = try toOwned(gpa, &a, null);
    defer gpa.free(x1);
    try testing.expect(std.mem.indexOf(u8, x1, "<address:address xmlns:address=\"http://www.orcid.org/ns/address\" xmlns:common=\"http://www.orcid.org/ns/common\">") != null);
    const w: model.Root = .{ .work = .{ .publication_date = .{ .year = 2012, .month = 1, .day = 2 } } };
    const x2 = try toOwned(gpa, &w, null);
    defer gpa.free(x2);
    try testing.expect(std.mem.indexOf(u8, x2, "<common:year>2012</common:year>") != null);
    try testing.expect(std.mem.indexOf(u8, x2, "<common:month>01</common:month>") != null);
    try testing.expect(std.mem.indexOf(u8, x2, "<common:day>02</common:day>") != null);
    var buf: [24]u8 = undefined;
    try testing.expectEqualStrings("-005", padInt(&buf, -5, 4));
    try testing.expectEqualStrings("12345", padInt(&buf, 12345, 4));
    try testing.expectEqualStrings("0000", padInt(&buf, 0, 4));
    try testing.expectEqualStrings("-9223372036854775808", padInt(&buf, std.math.minInt(i64), 4));
    try testing.expectEqualStrings("9223372036854775807", padInt(&buf, std.math.maxInt(i64), 0));
    try testing.expectEqualStrings("-1", padInt(&buf, -1, 2));
}

test "unwritable input is an error, not a panic" {
    const gpa = testing.allocator;
    var d: Diagnostic = .{};
    const k: model.Root = .{ .keyword = .{ .content = "bell\x07" } };
    try testing.expectError(error.Unwritable, toOwned(gpa, &k, &d));
    try testing.expectEqualStrings("keyword/content", d.path());
    try testing.expectEqual(@as(?u21, 7), d.code_point);
    const bad_attr: model.Root = .{ .keyword = .{ .meta = .{ .path = "a\x01" } } };
    try testing.expectError(error.Unwritable, toOwned(gpa, &bad_attr, &d));
    try testing.expectEqualStrings("keyword/@path", d.path());
    const not_utf8: model.Root = .{ .keyword = .{ .content = "\xff" } };
    try testing.expectError(error.Unwritable, toOwned(gpa, &not_utf8, &d));
    try testing.expectEqualStrings("not valid UTF-8", d.message);
    try testing.expectEqual(@as(?u21, 0xFFFD), d.code_point);
    const u: model.Root = .{ .unknown = "x" };
    try testing.expectError(error.Unwritable, toOwned(gpa, &u, &d));
}

test "funding contributor-sequence is unwritable" {
    const gpa = testing.allocator;
    var d: Diagnostic = .{};
    const f: model.Root = .{ .funding = .{ .contributors = &.{.{ .attributes = .{ .sequence = .{ .known = .first } } }} } };
    try testing.expectError(error.Unwritable, toOwned(gpa, &f, &d));
    try testing.expectEqualStrings("funding/contributors/contributor/contributor-attributes/contributor-sequence", d.path());
}

test "write into any writer: same bytes, nothing written on error" {
    const gpa = testing.allocator;
    const root: model.Root = .{ .work = .{
        .title = .{ .title = "T & <t>" },
        .publication_date = .{ .year = 2020 },
        .meta = .{ .put_code = 1, .path = "/0000-0002-1825-0097/work/1" },
    } };
    const owned = try toOwned(gpa, &root, null);
    defer gpa.free(owned);
    var aw: Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try write(&aw.writer, &root, null);
    try testing.expectEqualStrings(owned, aw.written());
    // a 7-byte buffer: most writes go through `drain`
    var small: [7]u8 = undefined;
    var sink: Writer.Discarding = .init(&small);
    try write(&sink.writer, &root, null);
    try testing.expectEqual(@as(u64, owned.len), sink.fullCount());

    const bad: model.Root = .{ .work = .{ .title = .{ .title = "ok" }, .url = "\x00" } };
    var aw2: Writer.Allocating = .init(gpa);
    defer aw2.deinit();
    var d: Diagnostic = .{};
    try testing.expectError(error.Unwritable, write(&aw2.writer, &bad, &d));
    try testing.expectEqual(@as(usize, 0), aw2.written().len);
    try testing.expectEqualStrings("work/url", d.path());
}

test "all 28 namespace declarations fit their room" {
    var buf: [decl_room]u8 = undefined;
    const all = declarations(&buf, std.math.maxInt(u32));
    try testing.expectEqual(@as(usize, 1490), all.len);
    try testing.expect(std.mem.startsWith(u8, all, " xmlns:activities=\"http://www.orcid.org/ns/activities\" xmlns:address="));
    try testing.expect(std.mem.endsWith(u8, all, " xmlns:work=\"http://www.orcid.org/ns/work\""));
    try testing.expectEqual(@as(usize, 0), declarations(&buf, 0).len);
}

/// The escape scan's result for `s`, as text written to `out` (or the bad
/// character).
fn escapeTo(comptime attr: bool, out: *Writer.Allocating, s: []const u8) !?Bad {
    out.clearRetainingCapacity();
    return escape(attr, &out.writer, s);
}

/// Byte-at-a-time reference: the old writer's check and escape.
fn referenceEscape(gpa: std.mem.Allocator, comptime attr: bool, s: []const u8) !union(enum) { ok: []u8, bad: Bad } {
    if (utf8.firstNonXmlChar(s)) |cp| {
        return .{ .bad = .{ .cp = cp, .invalid_utf8 = cp == 0xFFFD and !utf8.isValid(s) } };
    }
    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(gpa);
    for (s) |c| {
        const rep: ?[]const u8 = switch (c) {
            '&' => "&amp;",
            '<' => "&lt;",
            '>' => "&gt;",
            '\r' => "&#13;",
            '"' => if (attr) "&quot;" else null,
            '\t' => if (attr) "&#9;" else null,
            '\n' => if (attr) "&#10;" else null,
            else => null,
        };
        if (rep) |r| try list.appendSlice(gpa, r) else try list.append(gpa, c);
    }
    return .{ .ok = try list.toOwnedSlice(gpa) };
}

fn expectSameEscape(gpa: std.mem.Allocator, out: *Writer.Allocating, s: []const u8) !void {
    inline for (.{ false, true }) |attr| {
        const got = try escapeTo(attr, out, s);
        switch (try referenceEscape(gpa, attr, s)) {
            .ok => |want| {
                defer gpa.free(want);
                if (got) |b| {
                    std.debug.print("escape({any}) of {any}: refused U+{X:0>4}, expected {s}\n", .{ attr, s, b.cp, want });
                    return error.TestUnexpectedBad;
                }
                try testing.expectEqualStrings(want, out.written());
            },
            .bad => |want| {
                const b = got orelse {
                    std.debug.print("escape({any}) of {any}: accepted, expected U+{X:0>4}\n", .{ attr, s, want.cp });
                    return error.TestExpectedBad;
                };
                try testing.expectEqual(want.cp, b.cp);
                try testing.expectEqual(want.invalid_utf8, b.invalid_utf8);
            },
        }
    }
}

test "escape scan: every special byte at every chunk offset" {
    const gpa = testing.allocator;
    var out: Writer.Allocating = .init(gpa);
    defer out.deinit();
    // longer than two vectors, so the vector, 16-, 8-byte and byte paths
    // each see the special byte at each of their positions
    const len = 2 * vec_len + 16 + 8 + 7;
    const specials = [_][]const u8{
        // escaped or kept
        "&",        "<",    ">",    "\"",           "\r",           "\t",               "\n",           "\x7f",         "=",            "?",
        // refused control characters
        "\x00",     "\x01", "\x1f",
        // multi-byte UTF-8, the 0xEF look-alikes U+FF0C and U+FFFD among them
        "\xc3\xa9",     "\xe4\xb8\xad", "\xf0\x9f\x98\x80", "\xef\xbc\x8c", "\xef\xbf\xbd",
        // U+FFFE, U+FFFF
        "\xef\xbf\xbe", "\xef\xbf\xbf",
        // not UTF-8: truncated, lone, surrogate, overlong
        "\xef\xbf", "\xff", "\xc3", "\xed\xa0\x80", "\xc0\xaf",     "\xe2\x82",         "\xef",         "\x80",
    };
    var buf: [len + 8]u8 = undefined;
    for (specials) |sp| {
        for (0..len) |at| {
            // plain text, the special bytes at `at`, plain text to `len`
            @memset(&buf, 'a');
            const n = @min(sp.len, len - at);
            @memcpy(buf[at..][0..n], sp[0..n]);
            for ([_]usize{ at + n, len }) |end| {
                try expectSameEscape(gpa, &out, buf[0..end]);
                try expectSameEscape(gpa, &out, buf[at..end]);
            }
        }
    }
}

test "escape scan: two specials in one chunk, multi-byte text next to escapes" {
    const gpa = testing.allocator;
    var out: Writer.Allocating = .init(gpa);
    defer out.deinit();
    const cases = [_][]const u8{
        "",
        "plain ASCII text that is longer than any vector the scan uses, with no special byte at all",
        "&<>\"\r\t\n",
        "&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&",
        "é&é<é>é\"é\r\té\n",
        "中&lt;😀&amp;",
        "&\u{FF0C}<\u{FFFD}>\u{FF0C}\u{FFFD}&",
        "12345678&1234567<\u{FF0C}",
        "\u{FF0C}\u{FF0C}\u{FF0C}\u{FF0C}\u{FF0C}\u{FF0C}\u{FF0C}\u{FF0C}\u{FF0C}\u{FF0C}\u{FF0C}&",
        "\u{FFFD}\u{FFFD}\u{FFFD}\u{FFFD}\u{FFFD}\u{FFFD}\u{FFFD}\u{FFFD}\u{FFFD}\u{FFFD}\u{FFFD}<",
        "x\u{FFFE}",
        "\u{FFFF}y",
        "\u{FFFD}\u{FFFE}",
        "\u{FF0C}\u{FFFF}",
        "\u{EFFFF}\u{FEFF}\u{FFEF}", // more 0xEF lead and continuation bytes
        "a\x01b\xffc", // a control character before invalid UTF-8
        "a\xffb\x01c", // invalid UTF-8 before a control character
        "é\xc3",
        "😀\xf0\x9f\x98",
        " & <é中😀> \"q\" 'a' \r\t\nx\u{FFFD}&",
        " &<>\"\t\n\ré😀'x",
    };
    for (cases) |s| try expectSameEscape(gpa, &out, s);
    // every split point of a mixed string, so each special and each
    // multi-byte sequence meets every chunk boundary
    const part = "a&b<c>d\"e\rf\tg\nhé中😀\u{FF0C}\u{FFFD}";
    const mixed = part ++ part ++ part;
    for (0..mixed.len) |at| {
        try expectSameEscape(gpa, &out, mixed[at..]);
        try expectSameEscape(gpa, &out, mixed[0..at]);
    }
}

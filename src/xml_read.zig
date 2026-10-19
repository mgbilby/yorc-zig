//! ORCID v3.0 XML → `Document`.
//!
//! The input is scanned (xml_scan.zig) into a small element tree in a
//! temporary arena, then mapped onto the model in the document's arena.
//! Elements are matched by local name (prefixes and namespace URIs are
//! ignored, as in yorc-duckdb and yorc-rs); unknown elements and
//! attributes are skipped. Text rules: an element's text is the text after
//! its last child element, trimmed of ASCII space/tab/CR/LF; empty text is
//! absent; when an element that may occur once is repeated, each field keeps
//! its first non-empty value (repeated containers merge).
const std = @import("std");
const model = @import("model.zig");
const scan = @import("xml_scan.zig");
const utf8 = @import("utf8.zig");
const Diagnostic = @import("diag.zig").Diagnostic;

const Allocator = std.mem.Allocator;
const OOM = error{OutOfMemory};
const Text = model.Text;

pub const ParseError = error{
    /// Malformed XML (see `Diagnostic.position` / `message`).
    MalformedXml,
    /// The input is not UTF-8 (`Diagnostic.position` = valid bytes).
    InvalidUtf8,
    /// No root element.
    NoRootElement,
    /// Nesting deeper than `Options.max_depth`.
    TooDeep,
    OutOfMemory,
};

pub const Options = struct {
    /// Maximum element nesting depth (ORCID documents nest about 12 deep).
    max_depth: usize = 256,
};

// ================================================================== the tree

pub const Attr = struct {
    /// Local name.
    name: []const u8,
    /// Decoded, untrimmed value.
    value: []const u8,
};

pub const Elem = struct {
    /// Local name.
    name: []const u8,
    attrs: []const Attr = &.{},
    children: []const Elem = &.{},
    /// Text after the last child, trimmed (empty if none).
    text: []const u8 = "",

    /// Raw (decoded, untrimmed) value of the attribute with this local name.
    pub fn attrRaw(e: *const Elem, name: []const u8) ?[]const u8 {
        for (e.attrs) |a| if (std.mem.eql(u8, a.name, name)) return a.value;
        return null;
    }

    /// Trimmed attribute value; null if absent or empty.
    pub fn attr(e: *const Elem, name: []const u8) ?[]const u8 {
        const v = model.trimXmlSpace(e.attrRaw(name) orelse return null);
        return if (v.len == 0) null else v;
    }

    fn is(e: *const Elem, name: []const u8) bool {
        return std.mem.eql(u8, e.name, name);
    }
};

const Frame = struct {
    qname: []const u8,
    local: []const u8,
    attrs: []const Attr,
    children: std.ArrayList(Elem),
    text: std.ArrayList(u8),
};

/// Builds the element tree. Tree memory comes from `tree`; `scratch` holds
/// the per-depth text buffers and is freed before returning.
pub fn buildTree(tree: Allocator, scratch: Allocator, input: []const u8, options: Options, diag: ?*Diagnostic) ParseError!Elem {
    var frames: std.ArrayList(Frame) = .empty;
    defer {
        for (frames.items) |*f| f.text.deinit(scratch);
        frames.deinit(scratch);
    }
    var depth: usize = 0;
    var root: ?Elem = null;
    var sc: scan.Scanner = .init(input);

    while (true) {
        const tok = sc.next() catch return fail(diag, error.MalformedXml, "malformed markup", sc.pos);
        switch (tok) {
            .eof => break,
            .text => |raw| if (depth > 0) {
                try scan.decodeText(&frames.items[depth - 1].text, scratch, raw);
            },
            .cdata => |raw| if (depth > 0) {
                try frames.items[depth - 1].text.appendSlice(scratch, raw);
            },
            .start => |st| {
                if (depth >= options.max_depth) return fail(diag, error.TooDeep, "nesting too deep", sc.pos);
                if (depth > 0) frames.items[depth - 1].text.clearRetainingCapacity();
                const attrs = attributes(tree, st) catch |err| switch (err) {
                    error.MalformedXml => return fail(diag, error.MalformedXml, "malformed attribute", sc.pos),
                    error.OutOfMemory => return error.OutOfMemory,
                };
                const local = scan.localName(st.name);
                if (st.empty) {
                    const el: Elem = .{ .name = local, .attrs = attrs };
                    if (depth > 0) {
                        try frames.items[depth - 1].children.append(tree, el);
                    } else if (root == null) {
                        root = el;
                    }
                    continue;
                }
                if (depth == frames.items.len) {
                    try frames.append(scratch, .{ .qname = "", .local = "", .attrs = &.{}, .children = .empty, .text = .empty });
                }
                const f = &frames.items[depth];
                f.qname = st.name;
                f.local = local;
                f.attrs = attrs;
                f.children = .empty;
                f.text.clearRetainingCapacity();
                depth += 1;
            },
            .end => |qname| {
                if (depth == 0) return fail(diag, error.MalformedXml, "unbalanced end tag", sc.pos);
                const f = &frames.items[depth - 1];
                if (!std.mem.eql(u8, f.qname, qname)) return fail(diag, error.MalformedXml, "end tag does not match the start tag", sc.pos);
                const trimmed = model.trimXmlSpace(f.text.items);
                const el: Elem = .{
                    .name = f.local,
                    .attrs = f.attrs,
                    .children = f.children.items,
                    .text = if (trimmed.len == 0) "" else try tree.dupe(u8, trimmed),
                };
                f.attrs = &.{};
                f.children = .empty;
                depth -= 1;
                if (depth > 0) {
                    const parent = &frames.items[depth - 1];
                    parent.text.clearRetainingCapacity();
                    try parent.children.append(tree, el);
                } else if (root == null) {
                    root = el;
                }
            },
        }
    }
    if (depth > 0) return fail(diag, error.MalformedXml, "unexpected end of document inside an element", sc.pos);
    return root orelse fail(diag, error.NoRootElement, "document has no root element", sc.pos);
}

fn fail(diag: ?*Diagnostic, err: anytype, message: []const u8, position: usize) @TypeOf(err) {
    if (diag) |d| {
        d.message = message;
        d.position = position;
    }
    return err;
}

/// Attributes of a start tag (namespace declarations dropped, duplicates
/// after the first ignored), values decoded.
fn attributes(tree: Allocator, st: scan.Start) (error{MalformedXml} || OOM)![]const Attr {
    var out: std.ArrayList(Attr) = .empty;
    var seen: std.ArrayList([]const u8) = .empty; // qualified names
    var it = st.attributes();
    while (try it.next()) |a| {
        if (std.mem.eql(u8, a.name, "xmlns") or std.mem.startsWith(u8, a.name, "xmlns:")) continue;
        if (contains(seen.items, a.name)) continue;
        try seen.append(tree, a.name);
        const value: []const u8 = if (std.mem.indexOfScalar(u8, a.raw_value, '&') == null) a.raw_value else v: {
            var buf: std.ArrayList(u8) = .empty;
            try scan.decodeAttribute(&buf, tree, a.raw_value);
            break :v buf.items;
        };
        try out.append(tree, .{ .name = scan.localName(a.name), .value = value });
    }
    return out.items;
}

fn contains(names: []const []const u8, name: []const u8) bool {
    for (names) |q| {
        if (std.mem.eql(u8, q, name)) return true;
    }
    return false;
}

// ============================================================== entry points

/// Parses an ORCID XML document (UTF-8, optional BOM). The returned
/// Document owns its memory; call `deinit`. `input` may be freed afterwards.
pub fn parse(gpa: Allocator, input: []const u8, options: Options, diag: ?*Diagnostic) ParseError!model.Document {
    const bytes = if (std.mem.startsWith(u8, input, "\xEF\xBB\xBF")) input[3..] else input;
    if (utf8.invalidIndex(bytes)) |bad| return fail(diag, error.InvalidUtf8, "input is not UTF-8", bad);

    var tree_arena: std.heap.ArenaAllocator = .init(gpa);
    defer tree_arena.deinit();
    const root = try buildTree(tree_arena.allocator(), gpa, bytes, options, diag);

    const arena = try gpa.create(std.heap.ArenaAllocator);
    errdefer gpa.destroy(arena);
    arena.* = .init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();
    const body = try document(a, &root);
    return .{
        .arena = arena,
        .root_name = try a.dupe(u8, root.name),
        .root_path = if (root.attrRaw("path")) |p| try a.dupe(u8, p) else null,
        .root = body,
    };
}

// ================================================================== helpers

/// Owned trimmed text of an element, null if empty.
fn text(a: Allocator, e: *const Elem) OOM!?Text {
    if (e.text.len == 0) return null;
    return try a.dupe(u8, e.text);
}

/// Sets a text field unless it already has a value (first non-empty wins).
fn setText(a: Allocator, slot: *?Text, e: *const Elem) OOM!void {
    if (slot.* == null) slot.* = try text(a, e);
}

fn attrOwned(a: Allocator, e: *const Elem, name: []const u8) OOM!?Text {
    const v = e.attr(name) orelse return null;
    return try a.dupe(u8, v);
}

/// yorc-duckdb's integer rule: 1..=`max_digits` ASCII digits, nothing else.
pub fn parseInteger(s: []const u8, max_digits: usize) ?i64 {
    if (s.len == 0 or s.len > max_digits) return null;
    var v: i64 = 0;
    for (s) |c| {
        if (c < '0' or c > '9') return null;
        v = v * 10 + (c - '0');
    }
    return v;
}

pub fn parseI32(s: []const u8) ?i32 {
    const v = parseInteger(s, 9) orelse return null;
    return std.math.cast(i32, v);
}

/// yorc-duckdb's boolean rule: `true`/`1`, `false`/`0`.
pub fn parseBool(s: []const u8) ?bool {
    if (std.mem.eql(u8, s, "true") or std.mem.eql(u8, s, "1")) return true;
    if (std.mem.eql(u8, s, "false") or std.mem.eql(u8, s, "0")) return false;
    return null;
}

/// Rust `i64::from_str`: optional sign, then ASCII digits, no overflow.
pub fn parseSigned(s: []const u8) ?i64 {
    var t = s;
    var neg = false;
    if (t.len > 0 and (t[0] == '+' or t[0] == '-')) {
        neg = t[0] == '-';
        t = t[1..];
    }
    if (t.len == 0) return null;
    var v: i64 = 0;
    for (t) |c| {
        if (c < '0' or c > '9') return null;
        const d: i64 = c - '0';
        v = std.math.mul(i64, v, 10) catch return null;
        v = (if (neg) std.math.sub(i64, v, d) else std.math.add(i64, v, d)) catch return null;
    }
    return v;
}

fn setI32(slot: *?i32, e: *const Elem) void {
    if (slot.* == null and e.text.len > 0) slot.* = parseI32(e.text);
}

fn setBool(slot: *?bool, e: *const Elem) void {
    if (slot.* == null and e.text.len > 0) slot.* = parseBool(e.text);
}

fn setSigned(slot: *?i64, e: *const Elem) void {
    if (slot.* == null and e.text.len > 0) slot.* = parseSigned(e.text);
}

fn setEnum(comptime V: type, a: Allocator, slot: *?V, e: *const Elem) OOM!void {
    if (slot.* == null and e.text.len > 0) slot.* = V.parse(try a.dupe(u8, e.text));
}

fn enumAttr(comptime V: type, a: Allocator, e: *const Elem, name: []const u8) OOM!?V {
    const v = e.attr(name) orelse return null;
    return V.parse(try a.dupe(u8, v));
}

fn boolAttr(e: *const Elem, name: []const u8) ?bool {
    return parseBool(e.attr(name) orelse return null);
}

/// The payload of an optional child, created on first use: repeated
/// occurrences of a single-valued element merge field by field.
fn child(comptime T: type, slot: *?T) *T {
    if (slot.* == null) slot.* = .{};
    return &slot.*.?;
}

/// A list builder that continues an existing slice (repeated containers).
fn List(comptime T: type) type {
    return struct {
        items: std.ArrayList(T),

        fn from(a: Allocator, existing: []const T) OOM!@This() {
            var l: std.ArrayList(T) = .empty;
            try l.appendSlice(a, existing);
            return .{ .items = l };
        }

        fn add(l: *@This(), a: Allocator, v: T) OOM!void {
            try l.items.append(a, v);
        }

        fn slice(l: *@This()) []const T {
            return l.items.items;
        }
    };
}

// =================================================================== common

fn metaAttrs(a: Allocator, m: *model.ItemMeta, e: *const Elem) OOM!void {
    m.put_code = if (e.attr("put-code")) |v| parseInteger(v, 18) else null;
    m.visibility = try enumAttr(model.Visibility, a, e, "visibility");
    const di = e.attr("display-index");
    m.display_index = if (di) |v| parseI32(v) else null;
    m.display_index_text = null;
    if (di) |t| {
        var buf: [16]u8 = undefined;
        const same = if (m.display_index) |v|
            std.mem.eql(u8, std.fmt.bufPrint(&buf, "{d}", .{v}) catch "", t)
        else
            false;
        if (!same) m.display_index_text = try a.dupe(u8, t);
    }
    m.path = try attrOwned(a, e, "path");
}

/// Handles an `element-summary` child; false if `c` is not one.
fn metaChild(a: Allocator, m: *model.ItemMeta, c: *const Elem) OOM!bool {
    if (c.is("created-date")) {
        try setText(a, &m.created_date, c);
    } else if (c.is("last-modified-date")) {
        try setText(a, &m.last_modified_date, c);
    } else if (c.is("source")) {
        try fillSource(a, child(model.Source, &m.source), c);
    } else return false;
    return true;
}

fn fillIdentifier(a: Allocator, id: *model.OrcidIdentifier, e: *const Elem) OOM!void {
    for (e.children) |*c| {
        if (c.is("uri")) try setText(a, &id.uri, c) else if (c.is("path")) try setText(a, &id.path, c) else if (c.is("host")) try setText(a, &id.host, c);
    }
}

fn fillSource(a: Allocator, s: *model.Source, e: *const Elem) OOM!void {
    for (e.children) |*c| {
        if (c.is("source-orcid")) {
            try fillIdentifier(a, child(model.OrcidIdentifier, &s.source_orcid), c);
        } else if (c.is("source-client-id")) {
            try fillIdentifier(a, child(model.OrcidIdentifier, &s.source_client_id), c);
        } else if (c.is("source-name")) {
            try setText(a, &s.source_name, c);
        } else if (c.is("assertion-origin-orcid")) {
            try fillIdentifier(a, child(model.OrcidIdentifier, &s.assertion_origin_orcid), c);
        } else if (c.is("assertion-origin-client-id")) {
            try fillIdentifier(a, child(model.OrcidIdentifier, &s.assertion_origin_client_id), c);
        } else if (c.is("assertion-origin-name")) {
            try setText(a, &s.assertion_origin_name, c);
        }
    }
}

fn fillDate(d: *model.FuzzyDate, e: *const Elem) void {
    for (e.children) |*c| {
        if (c.is("year")) setI32(&d.year, c) else if (c.is("month")) setI32(&d.month, c) else if (c.is("day")) setI32(&d.day, c);
    }
}

fn fillOrganization(a: Allocator, o: *model.Organization, e: *const Elem) OOM!void {
    for (e.children) |*c| {
        if (c.is("name")) {
            try setText(a, &o.name, c);
        } else if (c.is("address")) {
            const ad = child(model.OrganizationAddress, &o.address);
            for (c.children) |*g| {
                if (g.is("city")) try setText(a, &ad.city, g) else if (g.is("region")) try setText(a, &ad.region, g) else if (g.is("country")) try setText(a, &ad.country, g);
            }
        } else if (c.is("disambiguated-organization")) {
            const d = child(model.DisambiguatedOrganization, &o.disambiguated_organization);
            for (c.children) |*g| {
                if (g.is("disambiguated-organization-identifier")) {
                    try setText(a, &d.identifier, g);
                } else if (g.is("disambiguation-source")) {
                    try setText(a, &d.source, g);
                }
            }
        }
    }
}

fn organization(a: Allocator, e: *const Elem) OOM!model.Organization {
    var o: model.Organization = .{};
    try fillOrganization(a, &o, e);
    return o;
}

fn externalId(a: Allocator, e: *const Elem) OOM!model.ExternalId {
    var x: model.ExternalId = .{};
    try metaAttrs(a, &x.meta, e);
    for (e.children) |*c| {
        if (try metaChild(a, &x.meta, c)) continue;
        if (c.is("external-id-type")) {
            try setText(a, &x.id_type, c);
        } else if (c.is("external-id-value")) {
            try setText(a, &x.value, c);
        } else if (c.is("external-id-normalized")) {
            const n = child(model.TransientString, &x.normalized);
            try setText(a, &n.value, c);
            if (n.transient == null) n.transient = boolAttr(c, "transient");
        } else if (c.is("external-id-normalized-error")) {
            const n = child(model.TransientError, &x.normalized_error);
            for (c.children) |*g| {
                if (g.is("error-code")) try setText(a, &n.error_code, g) else if (g.is("error-message")) try setText(a, &n.error_message, g);
            }
            if (n.transient == null) n.transient = boolAttr(c, "transient");
        } else if (c.is("external-id-url")) {
            try setText(a, &x.url, c);
        } else if (c.is("external-id-relationship")) {
            try setEnum(model.Relationship, a, &x.relationship, c);
        }
    }
    return x;
}

/// Appends the `external-id` children of an `external-ids` element.
fn externalIds(a: Allocator, out: *List(model.ExternalId), e: *const Elem) OOM!void {
    for (e.children) |*c| {
        if (c.is("external-id")) try out.add(a, try externalId(a, c));
    }
}

fn fillTitle(a: Allocator, t: *model.Title, e: *const Elem) OOM!void {
    for (e.children) |*c| {
        if (c.is("title")) {
            try setText(a, &t.title, c);
        } else if (c.is("subtitle")) {
            try setText(a, &t.subtitle, c);
        } else if (c.is("translated-title")) {
            const tt = child(model.TranslatedTitle, &t.translated_title);
            try setText(a, &tt.value, c);
            if (tt.language_code == null) tt.language_code = try attrOwned(a, c, "language-code");
        }
    }
}

fn contributor(a: Allocator, e: *const Elem) OOM!model.Contributor {
    var x: model.Contributor = .{};
    for (e.children) |*c| {
        if (c.is("contributor-orcid")) {
            try fillIdentifier(a, child(model.OrcidIdentifier, &x.contributor_orcid), c);
        } else if (c.is("credit-name")) {
            try setText(a, &x.credit_name, c);
        } else if (c.is("contributor-email")) {
            try setText(a, &x.contributor_email, c);
        } else if (c.is("contributor-attributes")) {
            const at = child(model.ContributorAttributes, &x.attributes);
            for (c.children) |*g| {
                if (g.is("contributor-sequence")) {
                    try setEnum(model.ContributorSequence, a, &at.sequence, g);
                } else if (g.is("contributor-role")) {
                    try setEnum(model.ContributorRole, a, &at.role, g);
                }
            }
        }
    }
    return x;
}

/// Appends the `contributor` children of a `contributors` element.
fn contributors(a: Allocator, out: *List(model.Contributor), e: *const Elem) OOM!void {
    for (e.children) |*c| {
        if (c.is("contributor")) try out.add(a, try contributor(a, c));
    }
}

// ==================================================================== works

fn workSummary(a: Allocator, e: *const Elem) OOM!model.WorkSummary {
    var w: model.WorkSummary = .{};
    try metaAttrs(a, &w.meta, e);
    var ids = try List(model.ExternalId).from(a, &.{});
    for (e.children) |*c| {
        if (try metaChild(a, &w.meta, c)) continue;
        if (c.is("title")) {
            try fillTitle(a, child(model.Title, &w.title), c);
        } else if (c.is("external-ids")) {
            try externalIds(a, &ids, c);
        } else if (c.is("url")) {
            try setText(a, &w.url, c);
        } else if (c.is("type")) {
            try setEnum(model.WorkType, a, &w.work_type, c);
        } else if (c.is("publication-date")) {
            fillDate(child(model.FuzzyDate, &w.publication_date), c);
        } else if (c.is("journal-title")) {
            try setText(a, &w.journal_title, c);
        }
    }
    w.external_ids = ids.slice();
    return w;
}

pub fn work(a: Allocator, e: *const Elem) OOM!model.Work {
    var w: model.Work = .{};
    try metaAttrs(a, &w.meta, e);
    var ids = try List(model.ExternalId).from(a, &.{});
    var cs = try List(model.Contributor).from(a, &.{});
    for (e.children) |*c| {
        if (try metaChild(a, &w.meta, c)) continue;
        if (c.is("title")) {
            try fillTitle(a, child(model.Title, &w.title), c);
        } else if (c.is("journal-title")) {
            try setText(a, &w.journal_title, c);
        } else if (c.is("short-description")) {
            try setText(a, &w.short_description, c);
        } else if (c.is("citation")) {
            const ci = child(model.Citation, &w.citation);
            for (c.children) |*g| {
                if (g.is("citation-type")) {
                    try setEnum(model.CitationType, a, &ci.citation_type, g);
                } else if (g.is("citation-value")) {
                    try setText(a, &ci.citation_value, g);
                }
            }
        } else if (c.is("type")) {
            try setEnum(model.WorkType, a, &w.work_type, c);
        } else if (c.is("publication-date")) {
            fillDate(child(model.FuzzyDate, &w.publication_date), c);
        } else if (c.is("external-ids")) {
            try externalIds(a, &ids, c);
        } else if (c.is("url")) {
            try setText(a, &w.url, c);
        } else if (c.is("contributors")) {
            try contributors(a, &cs, c);
        } else if (c.is("language-code")) {
            try setText(a, &w.language_code, c);
        } else if (c.is("country")) {
            const k = child(model.Country, &w.country);
            try setText(a, &k.value, c);
            if (k.visibility == null) k.visibility = try enumAttr(model.Visibility, a, c, "visibility");
        }
    }
    w.external_ids = ids.slice();
    w.contributors = cs.slice();
    return w;
}

fn fillWorks(a: Allocator, w: *model.Works, e: *const Elem) OOM!void {
    if (w.path == null) w.path = try attrOwned(a, e, "path");
    var groups = try List(model.WorkGroup).from(a, w.groups);
    for (e.children) |*c| {
        if (c.is("last-modified-date")) {
            try setText(a, &w.last_modified_date, c);
        } else if (c.is("group")) {
            var g: model.WorkGroup = .{};
            var ids = try List(model.ExternalId).from(a, &.{});
            var items = try List(model.WorkSummary).from(a, &.{});
            for (c.children) |*i| {
                if (i.is("last-modified-date")) {
                    try setText(a, &g.last_modified_date, i);
                } else if (i.is("external-ids")) {
                    try externalIds(a, &ids, i);
                } else if (i.is("work-summary")) {
                    try items.add(a, try workSummary(a, i));
                }
            }
            g.external_ids = ids.slice();
            g.work_summaries = items.slice();
            try groups.add(a, g);
        }
    }
    w.groups = groups.slice();
}

// ================================================================= fundings

fn fundingSummary(a: Allocator, e: *const Elem) OOM!model.FundingSummary {
    var f: model.FundingSummary = .{};
    try metaAttrs(a, &f.meta, e);
    var ids = try List(model.ExternalId).from(a, &.{});
    for (e.children) |*c| {
        if (try metaChild(a, &f.meta, c)) continue;
        if (c.is("title")) {
            try fillTitle(a, child(model.Title, &f.title), c);
        } else if (c.is("external-ids")) {
            try externalIds(a, &ids, c);
        } else if (c.is("url")) {
            try setText(a, &f.url, c);
        } else if (c.is("type")) {
            try setEnum(model.FundingType, a, &f.funding_type, c);
        } else if (c.is("start-date")) {
            fillDate(child(model.FuzzyDate, &f.start_date), c);
        } else if (c.is("end-date")) {
            fillDate(child(model.FuzzyDate, &f.end_date), c);
        } else if (c.is("organization")) {
            try fillOrganization(a, child(model.Organization, &f.organization), c);
        }
    }
    f.external_ids = ids.slice();
    return f;
}

fn funding(a: Allocator, e: *const Elem) OOM!model.Funding {
    var f: model.Funding = .{};
    try metaAttrs(a, &f.meta, e);
    var ids = try List(model.ExternalId).from(a, &.{});
    var cs = try List(model.Contributor).from(a, &.{});
    for (e.children) |*c| {
        if (try metaChild(a, &f.meta, c)) continue;
        if (c.is("type")) {
            try setEnum(model.FundingType, a, &f.funding_type, c);
        } else if (c.is("organization-defined-type")) {
            try setText(a, &f.organization_defined_type, c);
        } else if (c.is("title")) {
            try fillTitle(a, child(model.Title, &f.title), c);
        } else if (c.is("short-description")) {
            try setText(a, &f.short_description, c);
        } else if (c.is("amount")) {
            const am = child(model.Amount, &f.amount);
            try setText(a, &am.value, c);
            if (am.currency_code == null) am.currency_code = try attrOwned(a, c, "currency-code");
        } else if (c.is("url")) {
            try setText(a, &f.url, c);
        } else if (c.is("start-date")) {
            fillDate(child(model.FuzzyDate, &f.start_date), c);
        } else if (c.is("end-date")) {
            fillDate(child(model.FuzzyDate, &f.end_date), c);
        } else if (c.is("external-ids")) {
            try externalIds(a, &ids, c);
        } else if (c.is("contributors")) {
            try contributors(a, &cs, c);
        } else if (c.is("organization")) {
            try fillOrganization(a, child(model.Organization, &f.organization), c);
        }
    }
    f.external_ids = ids.slice();
    f.contributors = cs.slice();
    return f;
}

fn fillFundings(a: Allocator, f: *model.Fundings, e: *const Elem) OOM!void {
    if (f.path == null) f.path = try attrOwned(a, e, "path");
    var groups = try List(model.FundingGroup).from(a, f.groups);
    for (e.children) |*c| {
        if (c.is("last-modified-date")) {
            try setText(a, &f.last_modified_date, c);
        } else if (c.is("group")) {
            var g: model.FundingGroup = .{};
            var ids = try List(model.ExternalId).from(a, &.{});
            var items = try List(model.FundingSummary).from(a, &.{});
            for (c.children) |*i| {
                if (i.is("last-modified-date")) {
                    try setText(a, &g.last_modified_date, i);
                } else if (i.is("external-ids")) {
                    try externalIds(a, &ids, i);
                } else if (i.is("funding-summary")) {
                    try items.add(a, try fundingSummary(a, i));
                }
            }
            g.external_ids = ids.slice();
            g.funding_summaries = items.slice();
            try groups.add(a, g);
        }
    }
    f.groups = groups.slice();
}

// ============================================================= affiliations

fn affiliation(a: Allocator, kind: model.AffiliationKind, e: *const Elem) OOM!model.Affiliation {
    var x: model.Affiliation = .{ .kind = kind };
    try metaAttrs(a, &x.meta, e);
    var ids = try List(model.ExternalId).from(a, &.{});
    for (e.children) |*c| {
        if (try metaChild(a, &x.meta, c)) continue;
        if (c.is("department-name")) {
            try setText(a, &x.department_name, c);
        } else if (c.is("role-title")) {
            try setText(a, &x.role_title, c);
        } else if (c.is("start-date")) {
            fillDate(child(model.FuzzyDate, &x.start_date), c);
        } else if (c.is("end-date")) {
            fillDate(child(model.FuzzyDate, &x.end_date), c);
        } else if (c.is("organization")) {
            try fillOrganization(a, child(model.Organization, &x.organization), c);
        } else if (c.is("url")) {
            try setText(a, &x.url, c);
        } else if (c.is("external-ids")) {
            try externalIds(a, &ids, c);
        }
    }
    x.external_ids = ids.slice();
    return x;
}

fn fillAffiliations(a: Allocator, l: *model.Affiliations, e: *const Elem) OOM!void {
    if (l.path == null) l.path = try attrOwned(a, e, "path");
    var groups = try List(model.AffiliationGroup).from(a, l.groups);
    for (e.children) |*c| {
        if (c.is("last-modified-date")) {
            try setText(a, &l.last_modified_date, c);
        } else if (c.is("affiliation-group")) {
            var g: model.AffiliationGroup = .{};
            var ids = try List(model.ExternalId).from(a, &.{});
            var items = try List(model.Affiliation).from(a, &.{});
            for (c.children) |*i| {
                if (i.is("last-modified-date")) {
                    try setText(a, &g.last_modified_date, i);
                } else if (i.is("external-ids")) {
                    try externalIds(a, &ids, i);
                } else if (model.AffiliationKind.fromSummaryElement(i.name)) |kind| {
                    try items.add(a, try affiliation(a, kind, i));
                }
            }
            g.external_ids = ids.slice();
            g.summaries = items.slice();
            try groups.add(a, g);
        }
    }
    l.groups = groups.slice();
}

// ============================================================= peer reviews

fn peerReviewSummary(a: Allocator, e: *const Elem) OOM!model.PeerReviewSummary {
    var p: model.PeerReviewSummary = .{};
    try metaAttrs(a, &p.meta, e);
    var ids = try List(model.ExternalId).from(a, &.{});
    for (e.children) |*c| {
        if (try metaChild(a, &p.meta, c)) continue;
        if (c.is("reviewer-role")) {
            try setEnum(model.PeerReviewRole, a, &p.reviewer_role, c);
        } else if (c.is("external-ids")) {
            try externalIds(a, &ids, c);
        } else if (c.is("review-url")) {
            try setText(a, &p.review_url, c);
        } else if (c.is("review-type")) {
            try setEnum(model.PeerReviewType, a, &p.review_type, c);
        } else if (c.is("completion-date")) {
            fillDate(child(model.FuzzyDate, &p.completion_date), c);
        } else if (c.is("review-group-id")) {
            try setText(a, &p.review_group_id, c);
        } else if (c.is("convening-organization")) {
            try fillOrganization(a, child(model.Organization, &p.convening_organization), c);
        }
    }
    p.external_ids = ids.slice();
    return p;
}

fn peerReview(a: Allocator, e: *const Elem) OOM!model.PeerReview {
    var p: model.PeerReview = .{};
    try metaAttrs(a, &p.meta, e);
    var ids = try List(model.ExternalId).from(a, &.{});
    for (e.children) |*c| {
        if (try metaChild(a, &p.meta, c)) continue;
        if (c.is("reviewer-role")) {
            try setEnum(model.PeerReviewRole, a, &p.reviewer_role, c);
        } else if (c.is("review-identifiers")) {
            try externalIds(a, &ids, c);
        } else if (c.is("review-url")) {
            try setText(a, &p.review_url, c);
        } else if (c.is("review-type")) {
            try setEnum(model.PeerReviewType, a, &p.review_type, c);
        } else if (c.is("review-completion-date")) {
            fillDate(child(model.FuzzyDate, &p.review_completion_date), c);
        } else if (c.is("review-group-id")) {
            try setText(a, &p.review_group_id, c);
        } else if (c.is("subject-external-identifier")) {
            if (p.subject_external_identifier == null) p.subject_external_identifier = try externalId(a, c);
        } else if (c.is("subject-container-name")) {
            try setText(a, &p.subject_container_name, c);
        } else if (c.is("subject-type")) {
            try setText(a, &p.subject_type, c);
        } else if (c.is("subject-name")) {
            try fillTitle(a, child(model.Title, &p.subject_name), c);
        } else if (c.is("subject-url")) {
            try setText(a, &p.subject_url, c);
        } else if (c.is("convening-organization")) {
            try fillOrganization(a, child(model.Organization, &p.convening_organization), c);
        }
    }
    p.review_identifiers = ids.slice();
    return p;
}

fn fillPeerReviews(a: Allocator, p: *model.PeerReviews, e: *const Elem) OOM!void {
    if (p.path == null) p.path = try attrOwned(a, e, "path");
    var groups = try List(model.PeerReviewGroup).from(a, p.groups);
    for (e.children) |*c| {
        if (c.is("last-modified-date")) {
            try setText(a, &p.last_modified_date, c);
        } else if (c.is("group")) {
            var g: model.PeerReviewGroup = .{};
            var ids = try List(model.ExternalId).from(a, &.{});
            var dups = try List(model.PeerReviewDuplicates).from(a, &.{});
            for (c.children) |*i| {
                if (i.is("last-modified-date")) {
                    try setText(a, &g.last_modified_date, i);
                } else if (i.is("external-ids")) {
                    try externalIds(a, &ids, i);
                } else if (i.is("peer-review-group")) {
                    var d: model.PeerReviewDuplicates = .{};
                    var dids = try List(model.ExternalId).from(a, &.{});
                    var items = try List(model.PeerReviewSummary).from(a, &.{});
                    for (i.children) |*j| {
                        if (j.is("last-modified-date")) {
                            try setText(a, &d.last_modified_date, j);
                        } else if (j.is("external-ids")) {
                            try externalIds(a, &dids, j);
                        } else if (j.is("peer-review-summary")) {
                            try items.add(a, try peerReviewSummary(a, j));
                        }
                    }
                    d.external_ids = dids.slice();
                    d.summaries = items.slice();
                    try dups.add(a, d);
                }
            }
            g.external_ids = ids.slice();
            g.duplicates = dups.slice();
            try groups.add(a, g);
        }
    }
    p.groups = groups.slice();
}

// ======================================================= research resources

/// Appends the `organization` children of a `hosts` element.
fn hosts(a: Allocator, out: *List(model.Organization), e: *const Elem) OOM!void {
    for (e.children) |*c| {
        if (c.is("organization")) try out.add(a, try organization(a, c));
    }
}

fn fillProposal(a: Allocator, p: *model.Proposal, e: *const Elem) OOM!void {
    var hs = try List(model.Organization).from(a, p.hosts);
    var ids = try List(model.ExternalId).from(a, p.external_ids);
    for (e.children) |*c| {
        if (c.is("title")) {
            try fillTitle(a, child(model.Title, &p.title), c);
        } else if (c.is("hosts")) {
            try hosts(a, &hs, c);
        } else if (c.is("external-ids")) {
            try externalIds(a, &ids, c);
        } else if (c.is("start-date")) {
            fillDate(child(model.FuzzyDate, &p.start_date), c);
        } else if (c.is("end-date")) {
            fillDate(child(model.FuzzyDate, &p.end_date), c);
        } else if (c.is("url")) {
            try setText(a, &p.url, c);
        }
    }
    p.hosts = hs.slice();
    p.external_ids = ids.slice();
}

fn resourceItem(a: Allocator, e: *const Elem) OOM!model.ResourceItem {
    var r: model.ResourceItem = .{};
    var hs = try List(model.Organization).from(a, &.{});
    var ids = try List(model.ExternalId).from(a, &.{});
    for (e.children) |*c| {
        if (c.is("resource-name")) {
            try setText(a, &r.resource_name, c);
        } else if (c.is("resource-type")) {
            try setEnum(model.ResourceType, a, &r.resource_type, c);
        } else if (c.is("hosts")) {
            try hosts(a, &hs, c);
        } else if (c.is("external-ids")) {
            try externalIds(a, &ids, c);
        } else if (c.is("url")) {
            try setText(a, &r.url, c);
        }
    }
    r.hosts = hs.slice();
    r.external_ids = ids.slice();
    return r;
}

fn researchResourceSummary(a: Allocator, e: *const Elem) OOM!model.ResearchResourceSummary {
    var r: model.ResearchResourceSummary = .{};
    try metaAttrs(a, &r.meta, e);
    for (e.children) |*c| {
        if (try metaChild(a, &r.meta, c)) continue;
        if (c.is("proposal")) try fillProposal(a, child(model.Proposal, &r.proposal), c);
    }
    return r;
}

fn researchResource(a: Allocator, e: *const Elem) OOM!model.ResearchResource {
    var r: model.ResearchResource = .{};
    try metaAttrs(a, &r.meta, e);
    var items = try List(model.ResourceItem).from(a, &.{});
    for (e.children) |*c| {
        if (try metaChild(a, &r.meta, c)) continue;
        if (c.is("proposal")) {
            try fillProposal(a, child(model.Proposal, &r.proposal), c);
        } else if (c.is("resource-items")) {
            for (c.children) |*i| {
                if (i.is("resource-item")) try items.add(a, try resourceItem(a, i));
            }
        }
    }
    r.resource_items = items.slice();
    return r;
}

fn fillResearchResources(a: Allocator, r: *model.ResearchResources, e: *const Elem) OOM!void {
    if (r.path == null) r.path = try attrOwned(a, e, "path");
    var groups = try List(model.ResearchResourceGroup).from(a, r.groups);
    for (e.children) |*c| {
        if (c.is("last-modified-date")) {
            try setText(a, &r.last_modified_date, c);
        } else if (c.is("group")) {
            var g: model.ResearchResourceGroup = .{};
            var ids = try List(model.ExternalId).from(a, &.{});
            var items = try List(model.ResearchResourceSummary).from(a, &.{});
            for (c.children) |*i| {
                if (i.is("last-modified-date")) {
                    try setText(a, &g.last_modified_date, i);
                } else if (i.is("external-ids")) {
                    try externalIds(a, &ids, i);
                } else if (i.is("research-resource-summary")) {
                    try items.add(a, try researchResourceSummary(a, i));
                }
            }
            g.external_ids = ids.slice();
            g.summaries = items.slice();
            try groups.add(a, g);
        }
    }
    r.groups = groups.slice();
}

// ======================================================= activities summary

fn fillActivities(a: Allocator, s: *model.ActivitiesSummary, e: *const Elem) OOM!void {
    if (s.path == null) s.path = try attrOwned(a, e, "path");
    for (e.children) |*c| {
        if (c.is("last-modified-date")) {
            try setText(a, &s.last_modified_date, c);
        } else if (c.is("fundings")) {
            try fillFundings(a, child(model.Fundings, &s.fundings), c);
        } else if (c.is("peer-reviews")) {
            try fillPeerReviews(a, child(model.PeerReviews, &s.peer_reviews), c);
        } else if (c.is("research-resources")) {
            try fillResearchResources(a, child(model.ResearchResources, &s.research_resources), c);
        } else if (c.is("works")) {
            try fillWorks(a, child(model.Works, &s.works), c);
        } else if (model.AffiliationKind.fromContainerElement(c.name)) |kind| {
            const slot = s.affiliationsSlot(kind);
            if (slot.* == null) slot.* = .{ .kind = kind };
            try fillAffiliations(a, &slot.*.?, c);
        }
    }
}

// =================================================================== person

fn fillName(a: Allocator, n: *model.Name, e: *const Elem) OOM!void {
    if (n.visibility == null) n.visibility = try enumAttr(model.Visibility, a, e, "visibility");
    if (n.path == null) n.path = try attrOwned(a, e, "path");
    for (e.children) |*c| {
        if (c.is("created-date")) {
            try setText(a, &n.created_date, c);
        } else if (c.is("last-modified-date")) {
            try setText(a, &n.last_modified_date, c);
        } else if (c.is("given-names")) {
            try setText(a, &n.given_names, c);
        } else if (c.is("family-name")) {
            try setText(a, &n.family_name, c);
        } else if (c.is("credit-name")) {
            try setText(a, &n.credit_name, c);
        }
    }
}

fn fillBiography(a: Allocator, b: *model.Biography, e: *const Elem) OOM!void {
    if (b.visibility == null) b.visibility = try enumAttr(model.Visibility, a, e, "visibility");
    if (b.path == null) b.path = try attrOwned(a, e, "path");
    for (e.children) |*c| {
        if (c.is("created-date")) {
            try setText(a, &b.created_date, c);
        } else if (c.is("last-modified-date")) {
            try setText(a, &b.last_modified_date, c);
        } else if (c.is("content")) {
            try setText(a, &b.content, c);
        }
    }
}

fn otherName(a: Allocator, e: *const Elem) OOM!model.OtherName {
    var x: model.OtherName = .{};
    try metaAttrs(a, &x.meta, e);
    for (e.children) |*c| {
        if (!try metaChild(a, &x.meta, c) and c.is("content")) try setText(a, &x.content, c);
    }
    return x;
}

fn researcherUrl(a: Allocator, e: *const Elem) OOM!model.ResearcherUrl {
    var x: model.ResearcherUrl = .{};
    try metaAttrs(a, &x.meta, e);
    for (e.children) |*c| {
        if (try metaChild(a, &x.meta, c)) continue;
        if (c.is("url-name")) try setText(a, &x.url_name, c) else if (c.is("url")) try setText(a, &x.url, c);
    }
    return x;
}

fn email(a: Allocator, e: *const Elem) OOM!model.Email {
    var x: model.Email = .{};
    try metaAttrs(a, &x.meta, e);
    x.verified = boolAttr(e, "verified");
    x.primary = boolAttr(e, "primary");
    for (e.children) |*c| {
        if (!try metaChild(a, &x.meta, c) and c.is("email")) try setText(a, &x.email, c);
    }
    return x;
}

fn address(a: Allocator, e: *const Elem) OOM!model.Address {
    var x: model.Address = .{};
    try metaAttrs(a, &x.meta, e);
    for (e.children) |*c| {
        if (!try metaChild(a, &x.meta, c) and c.is("country")) try setText(a, &x.country, c);
    }
    return x;
}

fn keyword(a: Allocator, e: *const Elem) OOM!model.Keyword {
    var x: model.Keyword = .{};
    try metaAttrs(a, &x.meta, e);
    for (e.children) |*c| {
        if (!try metaChild(a, &x.meta, c) and c.is("content")) try setText(a, &x.content, c);
    }
    return x;
}

/// Fills a person item container (`other-names`, `emails`, ...).
fn fillList(
    comptime T: type,
    a: Allocator,
    lst: *model.ItemList(T),
    e: *const Elem,
    item: []const u8,
    comptime parseItem: fn (Allocator, *const Elem) OOM!T,
) OOM!void {
    if (lst.path == null) lst.path = try attrOwned(a, e, "path");
    var items = try List(T).from(a, lst.items);
    for (e.children) |*c| {
        if (c.is("last-modified-date")) {
            try setText(a, &lst.last_modified_date, c);
        } else if (c.is(item)) {
            try items.add(a, try parseItem(a, c));
        }
    }
    lst.items = items.slice();
}

fn fillPerson(a: Allocator, p: *model.Person, e: *const Elem) OOM!void {
    if (p.path == null) p.path = try attrOwned(a, e, "path");
    for (e.children) |*c| {
        if (c.is("last-modified-date")) {
            try setText(a, &p.last_modified_date, c);
        } else if (c.is("name")) {
            try fillName(a, child(model.Name, &p.name), c);
        } else if (c.is("other-names")) {
            try fillList(model.OtherName, a, child(model.OtherNames, &p.other_names), c, "other-name", otherName);
        } else if (c.is("biography")) {
            try fillBiography(a, child(model.Biography, &p.biography), c);
        } else if (c.is("researcher-urls")) {
            try fillList(model.ResearcherUrl, a, child(model.ResearcherUrls, &p.researcher_urls), c, "researcher-url", researcherUrl);
        } else if (c.is("emails")) {
            try fillList(model.Email, a, child(model.Emails, &p.emails), c, "email", email);
        } else if (c.is("addresses")) {
            try fillList(model.Address, a, child(model.Addresses, &p.addresses), c, "address", address);
        } else if (c.is("keywords")) {
            try fillList(model.Keyword, a, child(model.Keywords, &p.keywords), c, "keyword", keyword);
        } else if (c.is("external-identifiers")) {
            try fillList(model.ExternalId, a, child(model.ExternalIdentifiers, &p.external_identifiers), c, "external-identifier", externalId);
        }
    }
}

fn fillPersonalDetails(a: Allocator, p: *model.PersonalDetails, e: *const Elem) OOM!void {
    if (p.path == null) p.path = try attrOwned(a, e, "path");
    for (e.children) |*c| {
        if (c.is("last-modified-date")) {
            try setText(a, &p.last_modified_date, c);
        } else if (c.is("name")) {
            try fillName(a, child(model.Name, &p.name), c);
        } else if (c.is("other-names")) {
            try fillList(model.OtherName, a, child(model.OtherNames, &p.other_names), c, "other-name", otherName);
        } else if (c.is("biography")) {
            try fillBiography(a, child(model.Biography, &p.biography), c);
        }
    }
}

// =================================================================== record

fn fillHistory(a: Allocator, h: *model.History, e: *const Elem) OOM!void {
    if (h.visibility == null) h.visibility = try enumAttr(model.Visibility, a, e, "visibility");
    for (e.children) |*c| {
        if (c.is("creation-method")) {
            try setEnum(model.CreationMethod, a, &h.creation_method, c);
        } else if (c.is("completion-date")) {
            try setText(a, &h.completion_date, c);
        } else if (c.is("submission-date")) {
            try setText(a, &h.submission_date, c);
        } else if (c.is("last-modified-date")) {
            try setText(a, &h.last_modified_date, c);
        } else if (c.is("claimed")) {
            setBool(&h.claimed, c);
        } else if (c.is("source")) {
            try fillSource(a, child(model.Source, &h.source), c);
        } else if (c.is("deactivation-date")) {
            try setText(a, &h.deactivation_date, c);
        } else if (c.is("verified-email")) {
            setBool(&h.verified_email, c);
        } else if (c.is("verified-primary-email")) {
            setBool(&h.verified_primary_email, c);
        }
    }
}

fn fillPreferences(a: Allocator, p: *model.Preferences, e: *const Elem) OOM!void {
    for (e.children) |*c| {
        if (c.is("locale")) try setText(a, &p.locale, c);
    }
}

fn fillRecord(a: Allocator, r: *model.Record, e: *const Elem) OOM!void {
    if (r.path == null) r.path = try attrOwned(a, e, "path");
    for (e.children) |*c| {
        if (c.is("orcid-identifier")) {
            try fillIdentifier(a, child(model.OrcidIdentifier, &r.orcid_identifier), c);
        } else if (c.is("preferences")) {
            try fillPreferences(a, child(model.Preferences, &r.preferences), c);
        } else if (c.is("history")) {
            try fillHistory(a, child(model.History, &r.history), c);
        } else if (c.is("person")) {
            try fillPerson(a, child(model.Person, &r.person), c);
        } else if (c.is("activities-summary")) {
            try fillActivities(a, child(model.ActivitiesSummary, &r.activities_summary), c);
        }
    }
}

pub fn orcidError(a: Allocator, e: *const Elem) OOM!model.OrcidError {
    var x: model.OrcidError = .{};
    for (e.children) |*c| {
        if (c.is("response-code")) {
            setSigned(&x.response_code, c);
        } else if (c.is("developer-message")) {
            try setText(a, &x.developer_message, c);
        } else if (c.is("user-message")) {
            try setText(a, &x.user_message, c);
        } else if (c.is("error-code")) {
            setSigned(&x.error_code, c);
        } else if (c.is("more-info")) {
            try setText(a, &x.more_info, c);
        }
    }
    return x;
}

fn bulk(a: Allocator, e: *const Elem) OOM!model.Bulk {
    var items = try List(model.BulkItem).from(a, &.{});
    for (e.children) |*c| {
        if (c.is("work")) {
            try items.add(a, .{ .work = try work(a, c) });
        } else if (c.is("error")) {
            try items.add(a, .{ .@"error" = try orcidError(a, c) });
        }
    }
    return .{ .items = items.slice() };
}

fn search(a: Allocator, e: *const Elem) OOM!model.Search {
    var s: model.Search = .{ .num_found = if (e.attr("num-found")) |v| parseSigned(v) else null };
    var results = try List(model.OrcidIdentifier).from(a, &.{});
    for (e.children) |*c| {
        if (!c.is("result")) continue;
        for (c.children) |*g| {
            if (g.is("orcid-identifier")) {
                var id: model.OrcidIdentifier = .{};
                try fillIdentifier(a, &id, g);
                try results.add(a, id);
            }
        }
    }
    s.results = results.slice();
    return s;
}

fn expandedSearch(a: Allocator, e: *const Elem) OOM!model.ExpandedSearch {
    var s: model.ExpandedSearch = .{ .num_found = if (e.attr("num-found")) |v| parseSigned(v) else null };
    var results = try List(model.ExpandedResult).from(a, &.{});
    for (e.children) |*c| {
        if (!c.is("expanded-result")) continue;
        var r: model.ExpandedResult = .{};
        var others = try List(Text).from(a, &.{});
        var emails = try List(Text).from(a, &.{});
        var insts = try List(Text).from(a, &.{});
        for (c.children) |*g| {
            if (g.is("orcid-id")) {
                try setText(a, &r.orcid_id, g);
            } else if (g.is("given-names")) {
                try setText(a, &r.given_names, g);
            } else if (g.is("family-names")) {
                try setText(a, &r.family_names, g);
            } else if (g.is("credit-name")) {
                try setText(a, &r.credit_name, g);
            } else if (g.is("other-name")) {
                if (try text(a, g)) |t| try others.add(a, t);
            } else if (g.is("email")) {
                if (try text(a, g)) |t| try emails.add(a, t);
            } else if (g.is("institution-name")) {
                if (try text(a, g)) |t| try insts.add(a, t);
            }
        }
        r.other_names = others.slice();
        r.emails = emails.slice();
        r.institution_names = insts.slice();
        try results.add(a, r);
    }
    s.results = results.slice();
    return s;
}

/// `group-id-record`: `common:source`, or common-2.1's inline source fields
/// (the XSD's `source-type` extension), into `source`; first non-empty value
/// per field, in document order (yorc-rs's `group_id_record`).
fn groupIdRecord(a: Allocator, e: *const Elem) OOM!model.GroupIdRecord {
    var g: model.GroupIdRecord = .{
        .put_code = if (e.attr("put-code")) |v| parseInteger(v, 18) else null,
    };
    for (e.children) |*c| {
        if (c.is("created-date")) {
            try setText(a, &g.created_date, c);
        } else if (c.is("last-modified-date")) {
            try setText(a, &g.last_modified_date, c);
        } else if (c.is("name")) {
            try setText(a, &g.name, c);
        } else if (c.is("group-id")) {
            try setText(a, &g.group_id, c);
        } else if (c.is("description")) {
            try setText(a, &g.description, c);
        } else if (c.is("type")) {
            try setEnum(model.GroupType, a, &g.group_type, c);
        } else if (c.is("source")) {
            try fillSource(a, child(model.Source, &g.source), c);
        } else if (c.is("source-orcid")) {
            try fillIdentifier(a, child(model.OrcidIdentifier, &child(model.Source, &g.source).source_orcid), c);
        } else if (c.is("source-client-id")) {
            try fillIdentifier(a, child(model.OrcidIdentifier, &child(model.Source, &g.source).source_client_id), c);
        } else if (c.is("source-name")) {
            if (c.text.len > 0) {
                const src = child(model.Source, &g.source);
                if (src.source_name == null) src.source_name = try a.dupe(u8, c.text);
            }
        }
    }
    return g;
}

/// `group-id-records`: `total`, `page` and `page-size` are the first
/// non-empty text of each, as integers (1 to 9 ASCII digits, else null).
fn groupIdRecords(a: Allocator, e: *const Elem) OOM!model.GroupIdRecords {
    var p: model.GroupIdRecords = .{};
    var total: ?[]const u8 = null;
    var page: ?[]const u8 = null;
    var page_size: ?[]const u8 = null;
    var records = try List(model.GroupIdRecord).from(a, &.{});
    for (e.children) |*c| {
        if (c.is("last-modified-date")) {
            try setText(a, &p.last_modified_date, c);
        } else if (c.is("total")) {
            if (total == null and c.text.len > 0) total = c.text;
        } else if (c.is("page")) {
            if (page == null and c.text.len > 0) page = c.text;
        } else if (c.is("page-size")) {
            if (page_size == null and c.text.len > 0) page_size = c.text;
        } else if (c.is("group-id-record")) {
            try records.add(a, try groupIdRecord(a, c));
        }
    }
    p.total = if (total) |t| parseInteger(t, 9) else null;
    p.page = if (page) |t| parseInteger(t, 9) else null;
    p.page_size = if (page_size) |t| parseInteger(t, 9) else null;
    p.records = records.slice();
    return p;
}

fn build(comptime T: type, a: Allocator, e: *const Elem, comptime fill: fn (Allocator, *T, *const Elem) OOM!void) OOM!T {
    var v: T = .{};
    try fill(a, &v, e);
    return v;
}

fn list(comptime T: type, a: Allocator, e: *const Elem, item: []const u8, comptime parseItem: fn (Allocator, *const Elem) OOM!T) OOM!model.ItemList(T) {
    var l: model.ItemList(T) = .{};
    try fillList(T, a, &l, e, item, parseItem);
    return l;
}

/// Maps a root element onto the model.
pub fn document(a: Allocator, root: *const Elem) OOM!model.Root {
    const n = root.name;
    const eq = struct {
        fn f(x: []const u8, y: []const u8) bool {
            return std.mem.eql(u8, x, y);
        }
    }.f;
    if (eq(n, "record")) return .{ .record = try build(model.Record, a, root, fillRecord) };
    if (eq(n, "activities-summary")) return .{ .activities_summary = try build(model.ActivitiesSummary, a, root, fillActivities) };
    if (eq(n, "works")) return .{ .works = try build(model.Works, a, root, fillWorks) };
    if (eq(n, "work")) return .{ .work = try work(a, root) };
    if (eq(n, "work-summary")) return .{ .work_summary = try workSummary(a, root) };
    if (eq(n, "fundings")) return .{ .fundings = try build(model.Fundings, a, root, fillFundings) };
    if (eq(n, "funding")) return .{ .funding = try funding(a, root) };
    if (eq(n, "funding-summary")) return .{ .funding_summary = try fundingSummary(a, root) };
    if (eq(n, "peer-reviews")) return .{ .peer_reviews = try build(model.PeerReviews, a, root, fillPeerReviews) };
    if (eq(n, "peer-review")) return .{ .peer_review = try peerReview(a, root) };
    if (eq(n, "peer-review-summary")) return .{ .peer_review_summary = try peerReviewSummary(a, root) };
    if (eq(n, "research-resources")) return .{ .research_resources = try build(model.ResearchResources, a, root, fillResearchResources) };
    if (eq(n, "research-resource")) return .{ .research_resource = try researchResource(a, root) };
    if (eq(n, "research-resource-summary")) return .{ .research_resource_summary = try researchResourceSummary(a, root) };
    if (eq(n, "person")) return .{ .person = try build(model.Person, a, root, fillPerson) };
    if (eq(n, "personal-details")) return .{ .personal_details = try build(model.PersonalDetails, a, root, fillPersonalDetails) };
    if (eq(n, "name")) return .{ .name = try build(model.Name, a, root, fillName) };
    if (eq(n, "biography")) return .{ .biography = try build(model.Biography, a, root, fillBiography) };
    if (eq(n, "credit-name")) return .{ .credit_name = try text(a, root) };
    if (eq(n, "other-names")) return .{ .other_names = try list(model.OtherName, a, root, "other-name", otherName) };
    if (eq(n, "other-name")) return .{ .other_name = try otherName(a, root) };
    if (eq(n, "researcher-urls")) return .{ .researcher_urls = try list(model.ResearcherUrl, a, root, "researcher-url", researcherUrl) };
    if (eq(n, "researcher-url")) return .{ .researcher_url = try researcherUrl(a, root) };
    if (eq(n, "emails")) return .{ .emails = try list(model.Email, a, root, "email", email) };
    if (eq(n, "email")) return .{ .email = try email(a, root) };
    if (eq(n, "addresses")) return .{ .addresses = try list(model.Address, a, root, "address", address) };
    if (eq(n, "address")) return .{ .address = try address(a, root) };
    if (eq(n, "keywords")) return .{ .keywords = try list(model.Keyword, a, root, "keyword", keyword) };
    if (eq(n, "keyword")) return .{ .keyword = try keyword(a, root) };
    if (eq(n, "external-identifiers")) return .{ .external_identifiers = try list(model.ExternalId, a, root, "external-identifier", externalId) };
    if (eq(n, "external-identifier")) return .{ .external_identifier = try externalId(a, root) };
    if (eq(n, "history")) return .{ .history = try build(model.History, a, root, fillHistory) };
    if (eq(n, "preferences")) return .{ .preferences = try build(model.Preferences, a, root, fillPreferences) };
    if (eq(n, "bulk")) return .{ .bulk = try bulk(a, root) };
    if (eq(n, "error")) return .{ .@"error" = try orcidError(a, root) };
    if (eq(n, "search")) return .{ .search = try search(a, root) };
    if (eq(n, "expanded-search")) return .{ .expanded_search = try expandedSearch(a, root) };
    if (eq(n, "group-id-record")) return .{ .group_id_record = try groupIdRecord(a, root) };
    if (eq(n, "group-id-records")) return .{ .group_id_records = try groupIdRecords(a, root) };
    if (model.AffiliationKind.fromContainerElement(n)) |kind| {
        var l: model.Affiliations = .{ .kind = kind };
        try fillAffiliations(a, &l, root);
        return .{ .affiliations = l };
    }
    if (model.AffiliationKind.fromElement(n)) |kind| return .{ .affiliation = try affiliation(a, kind, root) };
    if (model.AffiliationKind.fromSummaryElement(n)) |kind| return .{ .affiliation_summary = try affiliation(a, kind, root) };
    return .{ .unknown = try a.dupe(u8, n) };
}

// ==================================================================== tests

const testing = std.testing;

test "entities, CDATA and the text rule" {
    var doc = try parse(testing.allocator,
        \\<?xml version="1.0"?>
        \\<!-- comment -->
        \\<work:work xmlns:work="w" xmlns:common="c" put-code=" 7 " path="/0000-0002-1825-0097/work/7">
        \\  <work:title><common:title>Fish &amp; Chips &#x2014; &#233;t&#xE9; &lt;3 &foo;</common:title>
        \\    <common:translated-title language-code="fr"> Poisson </common:translated-title></work:title>
        \\  <work:journal-title><![CDATA[A <raw> & journal]]></work:journal-title>
        \\  <work:journal-title>second</work:journal-title>
        \\  <work:type>book</work:type>
        \\  <common:url/>
        \\  <common:publication-date><common:year>1999</common:year><common:month>xx</common:month><common:day>007</common:day></common:publication-date>
        \\</work:work>
    , .{}, null);
    defer doc.deinit();
    try testing.expectEqualStrings("work", doc.root_name);
    try testing.expectEqualStrings("0000-0002-1825-0097", doc.orcid().?);
    const w = doc.root.work;
    const t = w.title.?;
    try testing.expectEqualStrings("Fish & Chips \u{2014} \u{e9}t\u{e9} <3 &foo;", t.title.?);
    try testing.expectEqualStrings("Poisson", t.translated_title.?.value.?);
    try testing.expectEqualStrings("fr", t.translated_title.?.language_code.?);
    try testing.expectEqualStrings("A <raw> & journal", w.journal_title.?);
    try testing.expect(w.work_type.?.is(.book));
    try testing.expect(w.url == null);
    try testing.expectEqual(@as(?i64, 7), w.meta.put_code);
    const d = w.publication_date.?;
    try testing.expectEqual(@as(?i32, 1999), d.year);
    try testing.expectEqual(@as(?i32, null), d.month);
    try testing.expectEqual(@as(?i32, 7), d.day);
}

test "mixed content keeps the text after the last child" {
    var doc = try parse(testing.allocator, "<credit-name>a<x/>b</credit-name>", .{}, null);
    defer doc.deinit();
    try testing.expectEqualStrings("b", doc.root.credit_name.?);
}

test "unknown values and elements" {
    var doc = try parse(testing.allocator, "<work-summary visibility=\"friends\"><type>new-type</type><new-element>x</new-element></work-summary>", .{}, null);
    defer doc.deinit();
    const w = doc.root.work_summary;
    try testing.expectEqualStrings("new-type", w.work_type.?.other);
    try testing.expectEqualStrings("friends", w.meta.visibility.?.other);
    var doc2 = try parse(testing.allocator, "<something-else/>", .{}, null);
    defer doc2.deinit();
    try testing.expectEqualStrings("something-else", doc2.root.unknown);
}

test "malformed documents are errors" {
    const gpa = testing.allocator;
    try testing.expectError(error.MalformedXml, parse(gpa, "<a><b></a>", .{}, null));
    try testing.expectError(error.MalformedXml, parse(gpa, "<a><b>", .{}, null));
    try testing.expectError(error.MalformedXml, parse(gpa, "</a>", .{}, null));
    try testing.expectError(error.NoRootElement, parse(gpa, "  ", .{}, null));
    var d: Diagnostic = .{};
    try testing.expectError(error.InvalidUtf8, parse(gpa, "<a>\xff</a>", .{}, &d));
    try testing.expectEqual(@as(usize, 3), d.position);
    try testing.expectError(error.TooDeep, parse(gpa, "<a><a><a><a></a></a></a></a>", .{ .max_depth = 3 }, null));
}

test "integer and boolean rules" {
    try testing.expectEqual(@as(?i64, 42), parseInteger("0042", 9));
    try testing.expectEqual(@as(?i64, null), parseInteger("4x", 9));
    try testing.expectEqual(@as(?i64, null), parseInteger("", 9));
    try testing.expectEqual(@as(?i64, null), parseInteger("1234567890", 9));
    try testing.expectEqual(@as(?i64, null), parseInteger("-1", 9));
    try testing.expectEqual(@as(?bool, true), parseBool("true"));
    try testing.expectEqual(@as(?bool, false), parseBool("0"));
    try testing.expectEqual(@as(?bool, null), parseBool("yes"));
    try testing.expectEqual(@as(?i64, -9037), parseSigned("-9037"));
    try testing.expectEqual(@as(?i64, null), parseSigned("1_0"));
}

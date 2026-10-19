//! The model flattened into yorc-duckdb's section tables: the eleven
//! record sections (`works` ... `history`), two API-message sections
//! (`search_results`, `errors`) and `research_resource_hosts`, with the same table names, column names,
//! column order and column types as `yorc-duckdb/src/core/sections.cpp`
//! (documented in yorc-duckdb's docs/REFERENCE.md), so `Tables.fromXml(xml)`
//! yields the rows `orcid_<section>_xml(xml)` returns. The rules are
//! yorc-rs's `rows`:
//! * `orcid`: the first segment of the root element's `path` attribute, else
//!   the first non-empty `orcid-identifier/path`, else the first segment of
//!   the item's own `path` attribute.
//! * `group_index`: 1-based position of the enclosing `group` /
//!   `affiliation-group` (`peer-review-group` is not a group).
//! * `owner`/`owner_put_code` (contributors, external ids, resource items):
//!   the nearest enclosing item with a put-code; without one, the nearest
//!   `group`, `affiliation-group` or `peer-review-group` (and no put-code).
//! * `doi` (works): the first `external-ids/external-id` of the work with
//!   type `doi` and relationship `self`, ASCII-lowercased.
//! * `source_hash`: lowercase hex SHA-256 of the document bytes.
//! * Repeated single-valued elements: first non-empty value per column (for
//!   research-resource hosts, per host column).
//! * `research_resource_hosts`: one row per `hosts/organization`, in
//!   document order (the proposal's hosts, then each resource item's;
//!   summaries too), `container` = `proposal` or `resource-item`,
//!   `item_ordinal` the resource item's 1-based position (NULL for the
//!   proposal), `orcid` the document's iD (no item-path fallback).
//! * `search_results`: one row per `search/result` (`item` = `result`) or
//!   `expanded-search/expanded-result` (`expanded-result`); `num_found` is
//!   the document's `@num-found` on every row, `ordinal` the 1-based
//!   position; `other_names`, `emails` and `institution_names` join every
//!   value with `; `.
//! * `errors`: one row per `error` document, or per `error` entry of a
//!   `bulk` document (`container` = `bulk`, `position` = the 1-based entry
//!   index among works and errors; NULL and 1 for a standalone error).
//!   `orcid` falls back to the valid iD after `ORCID ` in
//!   `developer-message`, then `user-message` (locked and deprecated
//!   records), and `primary_orcid` is the valid iD after `refer to account:`
//!   (deprecated records), as yorc-duckdb's `orcid_errors`.
//! * `response_code`, `error_code` (INTEGER) and `num_found` (BIGINT): 0 to
//!   9 or 18 digits, else NULL (yorc-duckdb's integer rule).
//! * The 21 columns appended on 2026-10-18 (after each section's existing
//!   columns): the assertion origin (`assertion_origin_orcid`,
//!   `assertion_origin_client_id`; also `assertion_origin_name` in
//!   person items and history), `contributor_orcid_host`,
//!   `normalized_error_code` (external ids; with `normalized` and
//!   `normalized_error` in person items, from a person external identifier
//!   only), and `person.orcid_uri` / `orcid_host`: the record's
//!   `orcid-identifier`, NULL unless the document element is a `record`.
//!
//! Tables own copies of the document's strings, so they outlive the Document
//! (static texts, such as item names and known vocabulary values, are not
//! copied). Rows are counted before they are built: each section's row list
//! and cells are allocated once, at their final size.
const std = @import("std");
const model = @import("model.zig");
const xml_read = @import("xml_read.zig");
const hash = @import("hash.zig");
const orcid_id = @import("id.zig");
const Bump = @import("bump.zig").Bump;

const Allocator = std.mem.Allocator;
const OOM = error{OutOfMemory};
const Text = model.Text;

// Opt-in, outside `Section.all` and `Tables` (which they leave as they are):
// yorc-duckdb's `timeline` and `group_ids` sections and its `orcid_changes`
// (rows_extra.zig), and `sectionRows`.
const rows_extra = @import("rows_extra.zig");
pub const Extra = rows_extra.Extra;
pub const ExtraRows = rows_extra.ExtraRows;
pub const extraRows = rows_extra.extraRows;
pub const extraFromXml = rows_extra.extraFromXml;
pub const timeline = rows_extra.timeline;
pub const groupIds = rows_extra.groupIds;
pub const Change = rows_extra.Change;
pub const ChangeKind = rows_extra.ChangeKind;
pub const Changes = rows_extra.Changes;
pub const changes = rows_extra.changes;
pub const change_columns = rows_extra.change_columns;
pub const diff_sections = rows_extra.diff_sections;
pub const SectionRows = rows_extra.SectionRows;
pub const sectionRows = rows_extra.sectionRows;

/// DuckDB column type of a section column.
pub const ColType = enum { varchar, integer, bigint, boolean };

/// One column of a section table.
pub const Column = struct {
    name: []const u8,
    ty: ColType,
};

fn col(name: []const u8, ty: ColType) Column {
    return .{ .name = name, .ty = ty };
}

/// A cell: VARCHAR, INTEGER/BIGINT, BOOLEAN or NULL.
pub const Cell = union(enum) {
    null,
    varchar: []const u8,
    integer: i64,
    boolean: bool,

    pub fn isNull(c: Cell) bool {
        return c == .null;
    }

    pub fn asStr(c: Cell) ?[]const u8 {
        return switch (c) {
            .varchar => |s| s,
            else => null,
        };
    }

    pub fn asInt(c: Cell) ?i64 {
        return switch (c) {
            .integer => |v| v,
            else => null,
        };
    }

    pub fn asBool(c: Cell) ?bool {
        return switch (c) {
            .boolean => |v| v,
            else => null,
        };
    }

    fn fits(c: Cell, ty: ColType) bool {
        return switch (c) {
            .null => true,
            .varchar => ty == .varchar,
            .integer => ty == .integer or ty == .bigint,
            .boolean => ty == .boolean,
        };
    }

    /// `{f}`: the convention of yorc-duckdb's core tests (NULL as `<null>`).
    pub fn format(c: Cell, w: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (c) {
            .null => try w.writeAll("<null>"),
            .varchar => |s| try w.writeAll(s),
            .integer => |v| try w.print("{d}", .{v}),
            .boolean => |v| try w.writeAll(if (v) "true" else "false"),
        }
    }
};

/// One row, cells in `Section.columns` order.
pub const Row = []const Cell;

/// The sections of yorc-duckdb this library produces, in yorc-rs's order:
/// the eleven record sections, then `search_results`, `errors` and
/// `research_resource_hosts`.
pub const Section = enum {
    works,
    fundings,
    affiliations,
    peer_reviews,
    research_resources,
    research_resource_items,
    contributors,
    external_ids,
    person,
    person_items,
    history,
    search_results,
    errors,
    research_resource_hosts,

    pub const all = [_]Section{
        .works,              .fundings,                .affiliations, .peer_reviews,
        .research_resources, .research_resource_items, .contributors, .external_ids,
        .person,             .person_items,            .history,      .search_results,
        .errors,             .research_resource_hosts,
    };

    /// Table name (`works`, ..., `history`, `search_results`, `errors`).
    pub fn name(s: Section) []const u8 {
        return @tagName(s);
    }

    pub fn fromName(text: []const u8) ?Section {
        return std.meta.stringToEnum(Section, text);
    }

    /// Columns in table order.
    pub fn columns(s: Section) []const Column {
        return switch (s) {
            .works => &works_cols,
            .fundings => &fundings_cols,
            .affiliations => &affiliations_cols,
            .peer_reviews => &peer_reviews_cols,
            .research_resources => &research_resources_cols,
            .research_resource_items => &research_resource_items_cols,
            .contributors => &contributors_cols,
            .external_ids => &external_ids_cols,
            .person => &person_cols,
            .person_items => &person_items_cols,
            .history => &history_cols,
            .search_results => &search_results_cols,
            .errors => &errors_cols,
            .research_resource_hosts => &research_resource_hosts_cols,
        };
    }

    /// Position of a column, by name.
    pub fn columnIndex(s: Section, column: []const u8) ?usize {
        for (s.columns(), 0..) |c, i| if (std.mem.eql(u8, c.name, column)) return i;
        return null;
    }

    fn index(s: Section) usize {
        return @backingInt(s);
    }
};

/// Rows of every section for one document.
pub const Tables = struct {
    arena: *std.heap.ArenaAllocator,
    rows: [Section.all.len]std.ArrayList(Row),

    /// Rows of all sections. `source_hash` fills the `source_hash` column
    /// (normally `hash.sha256Hex` of the document bytes).
    pub fn fromDocument(gpa: Allocator, doc: *const model.Document, source_hash: ?[]const u8) OOM!Tables {
        const arena = try gpa.create(std.heap.ArenaAllocator);
        errdefer gpa.destroy(arena);
        arena.* = .init(gpa);
        errdefer arena.deinit();
        var t: Tables = .{ .arena = arena, .rows = @splat(.empty) };
        const a = arena.allocator();
        var w: Walker = .{
            .a = a,
            .strings = try Bump.init(a, 16 * 1024, 64 * 1024),
            .doc_orcid = if (doc.orcid()) |o| try a.dupe(u8, o) else null,
            .record_id = recordId(doc),
            .hash = if (source_hash) |h| try a.dupe(u8, h) else null,
            .tables = &t,
            .free = undefined,
        };
        var counter: Counter = .{};
        counter.document(doc);
        for (Section.all, counter.n, &t.rows, &w.free) |sec, n, *list, *block| {
            try list.ensureTotalCapacityPrecise(a, n);
            block.* = try a.alloc(Cell, n * sec.columns().len);
            @memset(block.*, .null);
        }
        try w.document(doc);
        return t;
    }

    pub const FromXmlError = xml_read.ParseError;

    /// Parses `xml` and returns the rows of all sections, with `source_hash`
    /// = SHA-256 of `xml`: what `orcid_<section>_xml(xml)` returns.
    pub fn fromXml(gpa: Allocator, xml: []const u8) FromXmlError!Tables {
        var doc = try xml_read.parse(gpa, xml, .{}, null);
        defer doc.deinit();
        const h = hash.sha256Hex(xml);
        return fromDocument(gpa, &doc, &h);
    }

    pub fn deinit(t: *Tables) void {
        const child = t.arena.child_allocator;
        t.arena.deinit();
        child.destroy(t.arena);
        t.* = undefined;
    }

    pub fn get(t: *const Tables, section: Section) []const Row {
        return t.rows[section.index()].items;
    }

    pub fn count(t: *const Tables, section: Section) usize {
        return t.rows[section.index()].items.len;
    }

    /// Moves the rows of one section out, leaving none (yorc-rs's
    /// `Tables::take`). They stay in the tables' memory: valid until
    /// `deinit`.
    pub fn take(t: *Tables, section: Section) []const Row {
        const out = t.rows[section.index()].items;
        t.rows[section.index()] = .empty;
        return out;
    }

    /// Value of column `column` in row `row` of `section`.
    pub fn cell(t: *const Tables, section: Section, row: usize, column: []const u8) ?Cell {
        const i = section.columnIndex(column) orelse return null;
        const rows = t.get(section);
        if (row >= rows.len) return null;
        return rows[row][i];
    }
};

// ============================================================== row builder

/// One row of section `sec` being filled. Columns are named at compile time
/// and resolved to their index there (a column the section lacks is a
/// compile error), so setting a cell is a store.
fn RowBuilder(comptime sec: Section) type {
    return struct {
        cells: []Cell,

        const Self = @This();
        const section = sec;
        const columns = sec.columns();

        fn find(comptime column: []const u8) ?usize {
            @setEvalBranchQuota(20_000);
            for (columns, 0..) |c, i| {
                if (std.mem.eql(u8, c.name, column)) return i;
            }
            return null;
        }

        /// Whether the section has this column.
        fn has(comptime column: []const u8) bool {
            return comptime find(column) != null;
        }

        /// Sets a column this section has.
        fn set(rb: Self, comptime column: []const u8, c: Cell) void {
            const i = comptime find(column) orelse @compileError(@tagName(sec) ++ " has no column " ++ column);
            std.debug.assert(c.fits(columns[i].ty));
            rb.cells[i] = c;
        }
    };
}

/// A VARCHAR cell for text the tables do not copy: static strings (item and
/// container names, known vocabulary values) and the tables' own copies.
fn own(v: ?[]const u8) Cell {
    return if (v) |x| .{ .varchar = x } else .null;
}

fn integer(v: ?i64) Cell {
    return if (v) |n| .{ .integer = n } else .null;
}

fn int32(v: ?i32) Cell {
    return if (v) |n| .{ .integer = n } else .null;
}

fn boolean(v: ?bool) Cell {
    return if (v) |b| .{ .boolean = b } else .null;
}

fn idPath(id: ?model.OrcidIdentifier) ?Text {
    const x = id orelse return null;
    return x.path;
}

/// `<prefix>_year`, `<prefix>_month`, `<prefix>_day`.
fn dateCols(rb: anytype, comptime prefix: []const u8, d: ?model.FuzzyDate) void {
    rb.set(prefix ++ "_year", int32(if (d) |x| x.year else null));
    rb.set(prefix ++ "_month", int32(if (d) |x| x.month else null));
    rb.set(prefix ++ "_day", int32(if (d) |x| x.day else null));
}

/// Owner of nested rows (contributors, external ids).
const Owner = struct {
    name: ?[]const u8 = null,
    put_code: ?i64 = null,

    const none: Owner = .{};

    fn group(n: []const u8) Owner {
        return .{ .name = n };
    }

    /// The item itself if it has a put-code, else `fallback` (a group).
    fn item(n: []const u8, put_code: ?i64, fallback: Owner) Owner {
        return if (put_code != null) .{ .name = n, .put_code = put_code } else fallback;
    }
};

/// `doi` of a work: first `doi`/`self` external id, ASCII-lowercased (into
/// `strings`).
fn workDoi(strings: *Bump, ids: []const model.ExternalId) OOM!?[]const u8 {
    for (ids) |*x| {
        const is_doi = if (x.id_type) |t| std.mem.eql(u8, t, "doi") else false;
        const is_self = if (x.relationship) |r| std.mem.eql(u8, r.text(), "self") else false;
        if (is_doi and is_self) {
            if (x.value) |v| {
                const out = try strings.alloc(u8, v.len);
                return std.ascii.lowerString(out, v);
            }
        }
    }
    return null;
}

/// Fields shared by `work` and `work-summary`.
const WorkView = struct {
    meta: *const model.ItemMeta,
    title: ?model.Title,
    journal_title: ?Text,
    work_type: ?model.WorkType,
    publication_date: ?model.FuzzyDate,
    url: ?Text,
    external_ids: []const model.ExternalId,
    short_description: ?Text = null,
    citation: ?model.Citation = null,
    language_code: ?Text = null,
    country: ?Text = null,
};

/// Fields shared by `funding` and `funding-summary`.
const FundingView = struct {
    meta: *const model.ItemMeta,
    title: ?model.Title,
    funding_type: ?model.FundingType,
    organization_defined_type: ?Text = null,
    short_description: ?Text = null,
    amount: ?model.Amount = null,
    start_date: ?model.FuzzyDate,
    end_date: ?model.FuzzyDate,
    organization: ?*const model.Organization,
    url: ?Text,
};

/// Fields shared by `peer-review` and `peer-review-summary`.
const PeerReviewView = struct {
    meta: *const model.ItemMeta,
    reviewer_role: ?model.PeerReviewRole,
    review_type: ?model.PeerReviewType,
    review_url: ?Text,
    completion_date: ?model.FuzzyDate,
    review_group_id: ?Text,
    subject_type: ?Text = null,
    subject_name: ?model.Title = null,
    subject_container_name: ?Text = null,
    subject_url: ?Text = null,
    subject_external_identifier: ?*const model.ExternalId = null,
    convening_organization: ?*const model.Organization,
};

fn one(o: ?*const model.Organization) []const model.Organization {
    return if (o) |p| p[0..1] else &.{};
}

fn optPtr(comptime T: type, v: *const ?T) ?*const T {
    return if (v.*) |*x| x else null;
}

// =================================================================== walker

const Walker = struct {
    a: Allocator,
    /// The tables' copies of document text.
    strings: Bump,
    doc_orcid: ?[]const u8,
    /// The record's `orcid-identifier` (record documents only), for
    /// `person.orcid_uri` / `orcid_host`; points into the document.
    record_id: ?*const model.OrcidIdentifier,
    hash: ?[]const u8,
    tables: *Tables,
    /// Per section: the cells not yet handed to a row (one block per
    /// section, sized by `Counter`, all NULL).
    free: [Section.all.len][]Cell,

    /// A VARCHAR cell holding a copy of document text.
    fn copy(w: *Walker, v: ?[]const u8) OOM!Cell {
        const x = v orelse return .null;
        return .{ .varchar = try w.strings.dupe(x) };
    }

    /// A vocabulary value: its static tag name when known, else a copy.
    fn vocab(w: *Walker, v: anytype) OOM!Cell {
        const x = v orelse return .null;
        return switch (x) {
            .known => |k| .{ .varchar = @tagName(k) },
            .other => |o| try w.copy(o),
        };
    }

    /// The row's `orcid`: the document's, else the item path's first segment.
    fn orcid(w: *Walker, item_path: ?[]const u8) OOM!Cell {
        if (w.doc_orcid) |o| return own(o);
        const p = item_path orelse return .null;
        const seg = model.firstPathSegment(model.trimXmlSpace(p));
        if (seg.len == 0) return .null;
        return w.copy(seg);
    }

    fn row(w: *Walker, comptime sec: Section) OOM!RowBuilder(sec) {
        const n = comptime sec.columns().len;
        const left = &w.free[sec.index()];
        if (left.len >= n) {
            const cells = left.*[0..n];
            left.* = left.*[n..];
            return .{ .cells = cells };
        }
        // more rows than counted (not expected): cells of its own
        const extra = try w.a.alloc(Cell, n);
        @memset(extra, .null);
        return .{ .cells = extra };
    }

    /// Sets a VARCHAR column to a copy of document text.
    fn s(w: *Walker, rb: anytype, comptime column: []const u8, v: ?[]const u8) OOM!void {
        rb.set(column, try w.copy(v));
    }

    fn push(w: *Walker, rb: anytype) OOM!void {
        rb.set("source_hash", own(w.hash));
        try w.tables.rows[@TypeOf(rb).section.index()].append(w.a, rb.cells);
    }

    fn metaCols(w: *Walker, rb: anytype, m: *const model.ItemMeta) OOM!void {
        const R = @TypeOf(rb);
        if (comptime R.has("put_code")) rb.set("put_code", integer(m.put_code));
        if (comptime R.has("display_index")) rb.set("display_index", int32(m.display_index));
        if (comptime R.has("visibility")) rb.set("visibility", try w.vocab(m.visibility));
        if (comptime R.has("path")) try w.s(rb, "path", m.path);
        if (comptime R.has("created")) try w.s(rb, "created", m.created_date);
        if (comptime R.has("last_modified")) try w.s(rb, "last_modified", m.last_modified_date);
        try w.sourceCols(rb, &m.source);
    }

    fn sourceCols(w: *Walker, rb: anytype, src: *const ?model.Source) OOM!void {
        const x = if (src.*) |*v| v else return;
        const R = @TypeOf(rb);
        if (comptime R.has("source_name")) try w.s(rb, "source_name", x.source_name);
        if (comptime R.has("source_client_id")) try w.s(rb, "source_client_id", idPath(x.source_client_id));
        if (comptime R.has("source_orcid")) try w.s(rb, "source_orcid", idPath(x.source_orcid));
        if (comptime R.has("assertion_origin_name")) try w.s(rb, "assertion_origin_name", x.assertion_origin_name);
        if (comptime R.has("assertion_origin_orcid")) try w.s(rb, "assertion_origin_orcid", idPath(x.assertion_origin_orcid));
        if (comptime R.has("assertion_origin_client_id")) try w.s(rb, "assertion_origin_client_id", idPath(x.assertion_origin_client_id));
    }

    /// `<prefix>_name`, `_city`, `_region`, `_country`, `_disambiguated_id`,
    /// `_disambiguation_source`: first non-empty value across `orgs`.
    fn orgCols(w: *Walker, rb: anytype, comptime prefix: []const u8, orgs: []const model.Organization) OOM!void {
        var name: ?Text = null;
        var city: ?Text = null;
        var region: ?Text = null;
        var country: ?Text = null;
        var did: ?Text = null;
        var dsrc: ?Text = null;
        for (orgs) |*o| {
            if (name == null) name = o.name;
            if (o.address) |ad| {
                if (city == null) city = ad.city;
                if (region == null) region = ad.region;
                if (country == null) country = ad.country;
            }
            if (o.disambiguated_organization) |d| {
                if (did == null) did = d.identifier;
                if (dsrc == null) dsrc = d.source;
            }
        }
        try w.s(rb, prefix ++ "_name", name);
        try w.s(rb, prefix ++ "_city", city);
        try w.s(rb, prefix ++ "_region", region);
        try w.s(rb, prefix ++ "_country", country);
        try w.s(rb, prefix ++ "_disambiguated_id", did);
        try w.s(rb, prefix ++ "_disambiguation_source", dsrc);
    }

    fn document(w: *Walker, doc: *const model.Document) OOM!void {
        switch (doc.root) {
            .record => |*r| {
                if (r.history) |*h| try w.history(h);
                if (r.person) |*p| try w.person(p);
                if (r.activities_summary) |*act| try w.activities(act);
            },
            .activities_summary => |*x| try w.activities(x),
            .works => |*x| try w.works(x),
            .work => |*x| try w.work(x, null, Owner.none),
            .work_summary => |*x| try w.workSummary(x, null, Owner.none),
            .fundings => |*x| try w.fundings(x),
            .funding => |*x| try w.funding(x, null, Owner.none),
            .funding_summary => |*x| try w.fundingSummary(x, null, Owner.none),
            .affiliations => |*x| try w.affiliations(x),
            .affiliation => |*x| try w.affiliation(x, x.kind.element(), null, Owner.none),
            .affiliation_summary => |*x| try w.affiliation(x, x.kind.summaryElement(), null, Owner.none),
            .peer_reviews => |*x| try w.peerReviews(x),
            .peer_review => |*x| try w.peerReview(x),
            .peer_review_summary => |*x| try w.peerReviewSummary(x, null, Owner.none),
            .research_resources => |*x| try w.researchResources(x),
            .research_resource => |*x| try w.researchResource(x),
            .research_resource_summary => |*x| try w.researchResourceSummary(x, null, Owner.none),
            .person => |*x| try w.person(x),
            .personal_details => |*x| try w.personalDetails(x),
            .other_names => |*l| for (l.items) |*x| try w.otherName(x),
            .other_name => |*x| try w.otherName(x),
            .researcher_urls => |*l| for (l.items) |*x| try w.researcherUrl(x),
            .researcher_url => |*x| try w.researcherUrl(x),
            .emails => |*l| for (l.items) |*x| try w.email(x),
            .email => |*x| try w.email(x),
            .addresses => |*l| for (l.items) |*x| try w.address(x),
            .address => |*x| try w.address(x),
            .keywords => |*l| for (l.items) |*x| try w.keyword(x),
            .keyword => |*x| try w.keyword(x),
            .external_identifiers => |*l| for (l.items) |*x| try w.personExternalIdentifier(x),
            .external_identifier => |*x| try w.personExternalIdentifier(x),
            .history => |*x| try w.history(x),
            .bulk => |*b| for (b.items, 0..) |*it, i| switch (it.*) {
                .work => |*x| try w.work(x, null, Owner.none),
                .@"error" => |*x| try w.apiError(x, "bulk", @as(i64, @intCast(i + 1))),
            },
            .@"error" => |*x| try w.apiError(x, null, 1),
            .search => |*x| try w.search(x),
            .expanded_search => |*x| try w.expandedSearch(x),
            // group ids: `group_ids` rows (`rows_extra.zig`, `Extra.group_ids`)
            .group_id_record, .group_id_records => {},
            .name, .biography, .credit_name, .preferences, .unknown => {},
        }
    }

    /// Sections in `activities-summary` (XSD) order.
    fn activities(w: *Walker, a: *const model.ActivitiesSummary) OOM!void {
        if (a.distinctions) |*x| try w.affiliations(x);
        if (a.educations) |*x| try w.affiliations(x);
        if (a.employments) |*x| try w.affiliations(x);
        if (a.fundings) |*x| try w.fundings(x);
        if (a.invited_positions) |*x| try w.affiliations(x);
        if (a.memberships) |*x| try w.affiliations(x);
        if (a.peer_reviews) |*x| try w.peerReviews(x);
        if (a.qualifications) |*x| try w.affiliations(x);
        if (a.research_resources) |*x| try w.researchResources(x);
        if (a.services) |*x| try w.affiliations(x);
        if (a.works) |*x| try w.works(x);
    }

    // ------------------------------------------------------- external ids

    fn externalIds(w: *Walker, ids: []const model.ExternalId, owner: Owner, group: ?i64, container: []const u8) OOM!void {
        for (ids) |*x| try w.externalId(x, owner, group, container);
    }

    fn externalId(w: *Walker, x: *const model.ExternalId, owner: Owner, group: ?i64, container: []const u8) OOM!void {
        const rb = try w.row(.external_ids);
        rb.set("orcid", try w.orcid(x.meta.path));
        rb.set("owner", own(owner.name));
        rb.set("owner_put_code", integer(owner.put_code));
        rb.set("group_index", integer(group));
        rb.set("container", own(container));
        try w.s(rb, "type", x.id_type);
        try w.s(rb, "value", x.value);
        try w.s(rb, "normalized", if (x.normalized) |n| n.value else null);
        try w.normalizedCols(rb, x);
        try w.s(rb, "url", x.url);
        rb.set("relationship", try w.vocab(x.relationship));
        try w.push(rb);
    }

    /// `normalized`, `normalized_error`, `normalized_error_code` of an
    /// external id (ORCID's transient normalization).
    fn normalizedCols(w: *Walker, rb: anytype, x: *const model.ExternalId) OOM!void {
        try w.s(rb, "normalized", if (x.normalized) |n| n.value else null);
        try w.s(rb, "normalized_error", if (x.normalized_error) |n| n.error_message else null);
        try w.s(rb, "normalized_error_code", if (x.normalized_error) |n| n.error_code else null);
    }

    fn contributors(w: *Walker, list: []const model.Contributor, owner: Owner) OOM!void {
        for (list, 0..) |*c, i| {
            const rb = try w.row(.contributors);
            rb.set("orcid", try w.orcid(null));
            rb.set("owner", own(owner.name));
            rb.set("owner_put_code", integer(owner.put_code));
            rb.set("ordinal", integer(@as(i64, @intCast(i + 1))));
            try w.s(rb, "contributor_orcid", idPath(c.contributor_orcid));
            try w.s(rb, "contributor_orcid_uri", if (c.contributor_orcid) |o| o.uri else null);
            try w.s(rb, "contributor_orcid_host", if (c.contributor_orcid) |o| o.host else null);
            try w.s(rb, "credit_name", c.credit_name);
            try w.s(rb, "email", c.contributor_email);
            const at = c.attributes;
            rb.set("sequence", try w.vocab(if (at) |x| x.sequence else null));
            rb.set("role", try w.vocab(if (at) |x| x.role else null));
            try w.push(rb);
        }
    }

    // -------------------------------------------------------------- works

    fn works(w: *Walker, x: *const model.Works) OOM!void {
        for (x.groups, 0..) |*g, i| {
            const gi: ?i64 = @as(i64, @intCast(i + 1));
            try w.externalIds(g.external_ids, Owner.group("group"), gi, "external-ids");
            for (g.work_summaries) |*sm| try w.workSummary(sm, gi, Owner.group("group"));
        }
    }

    fn workSummary(w: *Walker, x: *const model.WorkSummary, group: ?i64, fallback: Owner) OOM!void {
        try w.workRow("work-summary", group, .{
            .meta = &x.meta,
            .title = x.title,
            .journal_title = x.journal_title,
            .work_type = x.work_type,
            .publication_date = x.publication_date,
            .url = x.url,
            .external_ids = x.external_ids,
        });
        try w.externalIds(x.external_ids, Owner.item("work-summary", x.meta.put_code, fallback), group, "external-ids");
    }

    fn work(w: *Walker, x: *const model.Work, group: ?i64, fallback: Owner) OOM!void {
        try w.workRow("work", group, .{
            .meta = &x.meta,
            .title = x.title,
            .journal_title = x.journal_title,
            .work_type = x.work_type,
            .publication_date = x.publication_date,
            .url = x.url,
            .external_ids = x.external_ids,
            .short_description = x.short_description,
            .citation = x.citation,
            .language_code = x.language_code,
            .country = if (x.country) |c| c.value else null,
        });
        const owner = Owner.item("work", x.meta.put_code, fallback);
        try w.externalIds(x.external_ids, owner, group, "external-ids");
        try w.contributors(x.contributors, owner);
    }

    fn workRow(w: *Walker, item: []const u8, group: ?i64, v: WorkView) OOM!void {
        const rb = try w.row(.works);
        rb.set("orcid", try w.orcid(v.meta.path));
        try w.metaCols(rb, v.meta);
        rb.set("group_index", integer(group));
        try w.s(rb, "title", if (v.title) |t| t.title else null);
        try w.s(rb, "subtitle", if (v.title) |t| t.subtitle else null);
        const tt: ?model.TranslatedTitle = if (v.title) |t| t.translated_title else null;
        try w.s(rb, "translated_title", if (tt) |t| t.value else null);
        try w.s(rb, "translated_title_language", if (tt) |t| t.language_code else null);
        try w.s(rb, "journal", v.journal_title);
        rb.set("type", try w.vocab(v.work_type));
        dateCols(rb, "pub", v.publication_date);
        rb.set("doi", own(try workDoi(&w.strings, v.external_ids)));
        try w.s(rb, "url", v.url);
        try w.s(rb, "short_description", v.short_description);
        rb.set("citation_type", try w.vocab(if (v.citation) |c| c.citation_type else null));
        try w.s(rb, "citation_value", if (v.citation) |c| c.citation_value else null);
        try w.s(rb, "language_code", v.language_code);
        try w.s(rb, "country", v.country);
        rb.set("item", own(item));
        try w.push(rb);
    }

    // ----------------------------------------------------------- fundings

    fn fundings(w: *Walker, x: *const model.Fundings) OOM!void {
        for (x.groups, 0..) |*g, i| {
            const gi: ?i64 = @as(i64, @intCast(i + 1));
            try w.externalIds(g.external_ids, Owner.group("group"), gi, "external-ids");
            for (g.funding_summaries) |*sm| try w.fundingSummary(sm, gi, Owner.group("group"));
        }
    }

    fn fundingSummary(w: *Walker, x: *const model.FundingSummary, group: ?i64, fallback: Owner) OOM!void {
        try w.fundingRow("funding-summary", group, .{
            .meta = &x.meta,
            .title = x.title,
            .funding_type = x.funding_type,
            .start_date = x.start_date,
            .end_date = x.end_date,
            .organization = optPtr(model.Organization, &x.organization),
            .url = x.url,
        });
        try w.externalIds(x.external_ids, Owner.item("funding-summary", x.meta.put_code, fallback), group, "external-ids");
    }

    fn funding(w: *Walker, x: *const model.Funding, group: ?i64, fallback: Owner) OOM!void {
        try w.fundingRow("funding", group, .{
            .meta = &x.meta,
            .title = x.title,
            .funding_type = x.funding_type,
            .organization_defined_type = x.organization_defined_type,
            .short_description = x.short_description,
            .amount = x.amount,
            .start_date = x.start_date,
            .end_date = x.end_date,
            .organization = optPtr(model.Organization, &x.organization),
            .url = x.url,
        });
        const owner = Owner.item("funding", x.meta.put_code, fallback);
        try w.externalIds(x.external_ids, owner, group, "external-ids");
        try w.contributors(x.contributors, owner);
    }

    fn fundingRow(w: *Walker, item: []const u8, group: ?i64, f: FundingView) OOM!void {
        const rb = try w.row(.fundings);
        rb.set("orcid", try w.orcid(f.meta.path));
        try w.metaCols(rb, f.meta);
        rb.set("group_index", integer(group));
        try w.s(rb, "title", if (f.title) |t| t.title else null);
        const tt: ?model.TranslatedTitle = if (f.title) |t| t.translated_title else null;
        try w.s(rb, "translated_title", if (tt) |t| t.value else null);
        try w.s(rb, "translated_title_language", if (tt) |t| t.language_code else null);
        rb.set("type", try w.vocab(f.funding_type));
        try w.s(rb, "organization_defined_type", f.organization_defined_type);
        try w.s(rb, "short_description", f.short_description);
        try w.s(rb, "amount", if (f.amount) |am| am.value else null);
        try w.s(rb, "currency", if (f.amount) |am| am.currency_code else null);
        dateCols(rb, "start", f.start_date);
        dateCols(rb, "end", f.end_date);
        try w.orgCols(rb, "org", one(f.organization));
        try w.s(rb, "url", f.url);
        rb.set("item", own(item));
        try w.push(rb);
    }

    // ------------------------------------------------------- affiliations

    fn affiliations(w: *Walker, list: *const model.Affiliations) OOM!void {
        for (list.groups, 0..) |*g, i| {
            const gi: ?i64 = @as(i64, @intCast(i + 1));
            try w.externalIds(g.external_ids, Owner.group("affiliation-group"), gi, "external-ids");
            for (g.summaries) |*x| try w.affiliation(x, x.kind.summaryElement(), gi, Owner.group("affiliation-group"));
        }
    }

    fn affiliation(w: *Walker, x: *const model.Affiliation, item: []const u8, group: ?i64, fallback: Owner) OOM!void {
        const rb = try w.row(.affiliations);
        rb.set("orcid", try w.orcid(x.meta.path));
        rb.set("affiliation_type", own(x.kind.element()));
        try w.metaCols(rb, &x.meta);
        rb.set("group_index", integer(group));
        try w.s(rb, "department", x.department_name);
        try w.s(rb, "role_title", x.role_title);
        dateCols(rb, "start", x.start_date);
        dateCols(rb, "end", x.end_date);
        try w.orgCols(rb, "org", one(optPtr(model.Organization, &x.organization)));
        try w.s(rb, "url", x.url);
        rb.set("item", own(item));
        try w.push(rb);
        try w.externalIds(x.external_ids, Owner.item(item, x.meta.put_code, fallback), group, "external-ids");
    }

    // ------------------------------------------------------- peer reviews

    fn peerReviews(w: *Walker, x: *const model.PeerReviews) OOM!void {
        for (x.groups, 0..) |*g, i| {
            const gi: ?i64 = @as(i64, @intCast(i + 1));
            try w.externalIds(g.external_ids, Owner.group("group"), gi, "external-ids");
            for (g.duplicates) |*d| {
                try w.externalIds(d.external_ids, Owner.group("peer-review-group"), gi, "external-ids");
                for (d.summaries) |*sm| try w.peerReviewSummary(sm, gi, Owner.group("peer-review-group"));
            }
        }
    }

    fn peerReviewSummary(w: *Walker, x: *const model.PeerReviewSummary, group: ?i64, fallback: Owner) OOM!void {
        try w.peerReviewRow("peer-review-summary", group, .{
            .meta = &x.meta,
            .reviewer_role = x.reviewer_role,
            .review_type = x.review_type,
            .review_url = x.review_url,
            .completion_date = x.completion_date,
            .review_group_id = x.review_group_id,
            .convening_organization = optPtr(model.Organization, &x.convening_organization),
        });
        try w.externalIds(x.external_ids, Owner.item("peer-review-summary", x.meta.put_code, fallback), group, "external-ids");
    }

    fn peerReview(w: *Walker, x: *const model.PeerReview) OOM!void {
        try w.peerReviewRow("peer-review", null, .{
            .meta = &x.meta,
            .reviewer_role = x.reviewer_role,
            .review_type = x.review_type,
            .review_url = x.review_url,
            .completion_date = x.review_completion_date,
            .review_group_id = x.review_group_id,
            .subject_type = x.subject_type,
            .subject_name = x.subject_name,
            .subject_container_name = x.subject_container_name,
            .subject_url = x.subject_url,
            .subject_external_identifier = optPtr(model.ExternalId, &x.subject_external_identifier),
            .convening_organization = optPtr(model.Organization, &x.convening_organization),
        });
        const owner = Owner.item("peer-review", x.meta.put_code, Owner.none);
        try w.externalIds(x.review_identifiers, owner, null, "review-identifiers");
        if (x.subject_external_identifier) |*sei| try w.externalId(sei, owner, null, "peer-review");
    }

    fn peerReviewRow(w: *Walker, item: []const u8, group: ?i64, p: PeerReviewView) OOM!void {
        const rb = try w.row(.peer_reviews);
        rb.set("orcid", try w.orcid(p.meta.path));
        try w.metaCols(rb, p.meta);
        rb.set("group_index", integer(group));
        rb.set("reviewer_role", try w.vocab(p.reviewer_role));
        rb.set("review_type", try w.vocab(p.review_type));
        try w.s(rb, "review_url", p.review_url);
        dateCols(rb, "completion", p.completion_date);
        try w.s(rb, "review_group_id", p.review_group_id);
        try w.s(rb, "subject_type", p.subject_type);
        try w.s(rb, "subject_name", if (p.subject_name) |t| t.title else null);
        try w.s(rb, "subject_subtitle", if (p.subject_name) |t| t.subtitle else null);
        const tt: ?model.TranslatedTitle = if (p.subject_name) |t| t.translated_title else null;
        try w.s(rb, "subject_translated_name", if (tt) |t| t.value else null);
        try w.s(rb, "subject_translated_name_language", if (tt) |t| t.language_code else null);
        try w.s(rb, "subject_container_name", p.subject_container_name);
        try w.s(rb, "subject_url", p.subject_url);
        try w.s(rb, "subject_id_type", if (p.subject_external_identifier) |x| x.id_type else null);
        try w.s(rb, "subject_id_value", if (p.subject_external_identifier) |x| x.value else null);
        try w.orgCols(rb, "convening_org", one(p.convening_organization));
        rb.set("item", own(item));
        try w.push(rb);
    }

    // ------------------------------------------------- research resources

    fn researchResources(w: *Walker, x: *const model.ResearchResources) OOM!void {
        for (x.groups, 0..) |*g, i| {
            const gi: ?i64 = @as(i64, @intCast(i + 1));
            try w.externalIds(g.external_ids, Owner.group("group"), gi, "external-ids");
            for (g.summaries) |*sm| try w.researchResourceSummary(sm, gi, Owner.group("group"));
        }
    }

    fn researchResourceSummary(w: *Walker, x: *const model.ResearchResourceSummary, group: ?i64, fallback: Owner) OOM!void {
        const item = "research-resource-summary";
        try w.researchResourceRow(item, group, &x.meta, optPtr(model.Proposal, &x.proposal));
        if (x.proposal) |*p| {
            try w.externalIds(p.external_ids, Owner.item(item, x.meta.put_code, fallback), group, "external-ids");
            try w.hosts(p.hosts, x.meta.put_code, "proposal", null);
        }
    }

    fn researchResource(w: *Walker, x: *const model.ResearchResource) OOM!void {
        const item = "research-resource";
        try w.researchResourceRow(item, null, &x.meta, optPtr(model.Proposal, &x.proposal));
        const owner = Owner.item(item, x.meta.put_code, Owner.none);
        if (x.proposal) |*p| {
            try w.externalIds(p.external_ids, owner, null, "external-ids");
            try w.hosts(p.hosts, owner.put_code, "proposal", null);
        }
        for (x.resource_items, 0..) |*ri, i| {
            const rb = try w.row(.research_resource_items);
            rb.set("orcid", try w.orcid(null));
            rb.set("owner_put_code", integer(owner.put_code));
            rb.set("ordinal", integer(@as(i64, @intCast(i + 1))));
            try w.s(rb, "resource_name", ri.resource_name);
            rb.set("resource_type", try w.vocab(ri.resource_type));
            try w.orgCols(rb, "host", ri.hosts);
            try w.s(rb, "url", ri.url);
            try w.push(rb);
            try w.externalIds(ri.external_ids, owner, null, "external-ids");
            try w.hosts(ri.hosts, owner.put_code, "resource-item", @as(i64, @intCast(i + 1)));
        }
    }

    /// `research_resource_hosts`: one row per host, in document order.
    /// `container` is the element holding `hosts` (`proposal`,
    /// `resource-item`), `item_ordinal` the resource item's position.
    fn hosts(w: *Walker, orgs: []const model.Organization, put_code: ?i64, container: []const u8, item_ordinal: ?i64) OOM!void {
        for (orgs, 0..) |*o, i| {
            const rb = try w.row(.research_resource_hosts);
            rb.set("orcid", try w.orcid(null));
            rb.set("owner_put_code", integer(put_code));
            rb.set("ordinal", integer(@as(i64, @intCast(i + 1))));
            const host_org: *const [1]model.Organization = o;
            try w.orgCols(rb, "host", host_org);
            rb.set("container", own(container));
            rb.set("item_ordinal", integer(item_ordinal));
            try w.push(rb);
        }
    }

    fn researchResourceRow(w: *Walker, item: []const u8, group: ?i64, meta: *const model.ItemMeta, proposal: ?*const model.Proposal) OOM!void {
        const rb = try w.row(.research_resources);
        rb.set("orcid", try w.orcid(meta.path));
        try w.metaCols(rb, meta);
        rb.set("group_index", integer(group));
        const title: ?model.Title = if (proposal) |p| p.title else null;
        try w.s(rb, "title", if (title) |t| t.title else null);
        const tt: ?model.TranslatedTitle = if (title) |t| t.translated_title else null;
        try w.s(rb, "translated_title", if (tt) |t| t.value else null);
        try w.s(rb, "translated_title_language", if (tt) |t| t.language_code else null);
        try w.orgCols(rb, "host", if (proposal) |p| p.hosts else &.{});
        dateCols(rb, "start", if (proposal) |p| p.start_date else null);
        dateCols(rb, "end", if (proposal) |p| p.end_date else null);
        try w.s(rb, "url", if (proposal) |p| p.url else null);
        rb.set("item", own(item));
        try w.push(rb);
    }

    // ------------------------------------------------------------- person

    fn person(w: *Walker, p: *const model.Person) OOM!void {
        try w.personRow("person", p.path, p.last_modified_date, p.name, p.biography);
        if (p.other_names) |*l| for (l.items) |*x| try w.otherName(x);
        if (p.researcher_urls) |*l| for (l.items) |*x| try w.researcherUrl(x);
        if (p.emails) |*l| for (l.items) |*x| try w.email(x);
        if (p.addresses) |*l| for (l.items) |*x| try w.address(x);
        if (p.keywords) |*l| for (l.items) |*x| try w.keyword(x);
        if (p.external_identifiers) |*l| for (l.items) |*x| try w.personExternalIdentifier(x);
    }

    fn personalDetails(w: *Walker, p: *const model.PersonalDetails) OOM!void {
        try w.personRow("personal-details", p.path, p.last_modified_date, p.name, p.biography);
        if (p.other_names) |*l| for (l.items) |*x| try w.otherName(x);
    }

    fn personRow(w: *Walker, item: []const u8, path: ?Text, last_modified: ?Text, name: ?model.Name, bio: ?model.Biography) OOM!void {
        const rb = try w.row(.person);
        rb.set("orcid", try w.orcid(path));
        try w.s(rb, "given_names", if (name) |n| n.given_names else null);
        try w.s(rb, "family_name", if (name) |n| n.family_name else null);
        try w.s(rb, "credit_name", if (name) |n| n.credit_name else null);
        rb.set("name_visibility", try w.vocab(if (name) |n| n.visibility else null));
        try w.s(rb, "biography", if (bio) |b| b.content else null);
        rb.set("biography_visibility", try w.vocab(if (bio) |b| b.visibility else null));
        try w.s(rb, "last_modified", last_modified);
        try w.s(rb, "name_last_modified", if (name) |n| n.last_modified_date else null);
        try w.s(rb, "biography_last_modified", if (bio) |b| b.last_modified_date else null);
        try w.s(rb, "path", path);
        rb.set("item", own(item));
        try w.s(rb, "orcid_uri", if (w.record_id) |r| r.uri else null);
        try w.s(rb, "orcid_host", if (w.record_id) |r| r.host else null);
        try w.push(rb);
    }

    const ItemFields = struct {
        value: ?Text = null,
        url: ?Text = null,
        id_type: ?Text = null,
        relationship: ?model.Relationship = null,
        verified: ?bool = null,
        primary: ?bool = null,
        /// a person external identifier: its `normalized*` columns
        ext: ?*const model.ExternalId = null,
    };

    fn personItemRow(w: *Walker, kind: []const u8, meta: *const model.ItemMeta, f: ItemFields) OOM!void {
        const rb = try w.row(.person_items);
        rb.set("orcid", try w.orcid(meta.path));
        rb.set("kind", own(kind));
        try w.metaCols(rb, meta);
        try w.s(rb, "value", f.value);
        try w.s(rb, "url", f.url);
        try w.s(rb, "type", f.id_type);
        rb.set("relationship", try w.vocab(f.relationship));
        rb.set("verified", boolean(f.verified));
        rb.set("primary", boolean(f.primary));
        if (f.ext) |x| try w.normalizedCols(rb, x);
        try w.push(rb);
    }

    fn otherName(w: *Walker, x: *const model.OtherName) OOM!void {
        try w.personItemRow("other-name", &x.meta, .{ .value = x.content });
    }

    fn researcherUrl(w: *Walker, x: *const model.ResearcherUrl) OOM!void {
        try w.personItemRow("researcher-url", &x.meta, .{ .value = x.url_name, .url = x.url });
    }

    fn email(w: *Walker, x: *const model.Email) OOM!void {
        try w.personItemRow("email", &x.meta, .{ .value = x.email, .verified = x.verified, .primary = x.primary });
    }

    fn address(w: *Walker, x: *const model.Address) OOM!void {
        try w.personItemRow("address", &x.meta, .{ .value = x.country });
    }

    fn keyword(w: *Walker, x: *const model.Keyword) OOM!void {
        try w.personItemRow("keyword", &x.meta, .{ .value = x.content });
    }

    fn personExternalIdentifier(w: *Walker, x: *const model.ExternalId) OOM!void {
        try w.personItemRow("external-identifier", &x.meta, .{
            .value = x.value,
            .url = x.url,
            .id_type = x.id_type,
            .relationship = x.relationship,
            .ext = x,
        });
    }

    // ------------------------------------------------------------ history

    fn history(w: *Walker, h: *const model.History) OOM!void {
        const rb = try w.row(.history);
        rb.set("orcid", try w.orcid(null));
        rb.set("creation_method", try w.vocab(h.creation_method));
        try w.s(rb, "completion_date", h.completion_date);
        try w.s(rb, "submission_date", h.submission_date);
        try w.s(rb, "last_modified", h.last_modified_date);
        rb.set("claimed", boolean(h.claimed));
        try w.s(rb, "deactivation_date", h.deactivation_date);
        rb.set("verified_email", boolean(h.verified_email));
        rb.set("verified_primary_email", boolean(h.verified_primary_email));
        rb.set("visibility", try w.vocab(h.visibility));
        try w.sourceCols(rb, &h.source);
        try w.push(rb);
    }

    // ----------------------------------------------------- search results

    fn search(w: *Walker, x: *const model.Search) OOM!void {
        for (x.results, 0..) |*r, i| {
            const rb = try w.row(.search_results);
            rb.set("num_found", integer(digits(x.num_found, max_bigint)));
            rb.set("ordinal", integer(@as(i64, @intCast(i + 1))));
            try w.s(rb, "orcid", r.path);
            try w.s(rb, "orcid_uri", r.uri);
            try w.s(rb, "orcid_host", r.host);
            rb.set("item", own("result"));
            try w.push(rb);
        }
    }

    fn expandedSearch(w: *Walker, x: *const model.ExpandedSearch) OOM!void {
        for (x.results, 0..) |*r, i| {
            const rb = try w.row(.search_results);
            rb.set("num_found", integer(digits(x.num_found, max_bigint)));
            rb.set("ordinal", integer(@as(i64, @intCast(i + 1))));
            try w.s(rb, "orcid", r.orcid_id);
            try w.s(rb, "given_names", r.given_names);
            try w.s(rb, "family_names", r.family_names);
            try w.s(rb, "credit_name", r.credit_name);
            rb.set("other_names", try w.joined(r.other_names));
            rb.set("emails", try w.joined(r.emails));
            rb.set("institution_names", try w.joined(r.institution_names));
            rb.set("item", own("expanded-result"));
            try w.push(rb);
        }
    }

    /// Every value joined with `; ` (yorc-duckdb's `JOIN_SEPARATOR`) into
    /// the tables' strings; NULL for none.
    fn joined(w: *Walker, values: []const Text) OOM!Cell {
        if (values.len == 0) return .null;
        const sep = "; ";
        var len: usize = sep.len * (values.len - 1);
        for (values) |v| len += v.len;
        const out = try w.strings.alloc(u8, len);
        var at: usize = 0;
        for (values, 0..) |v, i| {
            if (i > 0) {
                @memcpy(out[at..][0..sep.len], sep);
                at += sep.len;
            }
            @memcpy(out[at..][0..v.len], v);
            at += v.len;
        }
        return .{ .varchar = out };
    }

    // ------------------------------------------------------------- errors

    /// One `errors` row. `container` is the parent element (`bulk`, or null
    /// for the document element), `position` the 1-based position among its
    /// siblings.
    fn apiError(w: *Walker, e: *const model.OrcidError, container: ?[]const u8, position: i64) OOM!void {
        const rb = try w.row(.errors);
        var who = try w.orcid(null);
        if (who == .null) {
            if (messageId(e, "ORCID ")) |c| who = try w.copy(@as([]const u8, &c));
        }
        rb.set("orcid", who);
        rb.set("response_code", integer(digits(e.response_code, max_integer)));
        try w.s(rb, "developer_message", e.developer_message);
        try w.s(rb, "user_message", e.user_message);
        rb.set("error_code", integer(digits(e.error_code, max_integer)));
        try w.s(rb, "more_info", e.more_info);
        rb.set("container", own(container));
        rb.set("position", integer(position));
        if (messageId(e, "refer to account:")) |c| rb.set("primary_orcid", try w.copy(@as([]const u8, &c)));
        try w.push(rb);
    }
};

/// The record's `orcid-identifier` when the document element is a `record`.
fn recordId(doc: *const model.Document) ?*const model.OrcidIdentifier {
    return switch (doc.root) {
        .record => |*r| if (r.orcid_identifier) |*id| id else null,
        else => null,
    };
}

/// The largest INTEGER column value yorc-duckdb reads: 9 digits.
const max_integer: i64 = 999_999_999;
/// The largest BIGINT column value yorc-duckdb reads: 18 digits.
const max_bigint: i64 = 999_999_999_999_999_999;

/// yorc-duckdb's integer rule on a number the model already holds: 0 to
/// `max` (1 to 9 or 18 ASCII digits), anything else NULL.
fn digits(v: ?i64, max: i64) ?i64 {
    const n = v orelse return null;
    return if (n >= 0 and n <= max) n else null;
}

/// The first valid iD named after `marker` in the error's
/// `developer-message`, then its `user-message` (yorc-duckdb's
/// `$message_orcid` / `$message_primary_orcid`).
fn messageId(e: *const model.OrcidError, marker: []const u8) ?orcid_id.Canonical {
    for ([_]?Text{ e.developer_message, e.user_message }) |m| {
        const text = m orelse continue;
        if (idAfter(text, marker)) |c| return c;
    }
    return null;
}

/// The first valid iD that directly follows `marker` in `text` (bare or as
/// an orcid.org URL; spaces after the marker skipped, trailing `.`, `,`,
/// `;`, `)` and `/` ignored), canonical (yorc-duckdb's `IdAfter`).
fn idAfter(text: []const u8, marker: []const u8) ?orcid_id.Canonical {
    var from: usize = 0;
    while (std.mem.indexOfPos(u8, text, from, marker)) |start| {
        const rest = std.mem.trimStart(u8, text[start + marker.len ..], " ");
        const end = std.mem.indexOfAny(u8, rest, " \t\n\r") orelse rest.len;
        const token = std.mem.trimEnd(u8, rest[0..end], ".,;)/");
        if (orcid_id.normalize(token)) |c| return c;
        from = start + 1;
    }
    return null;
}

// ================================================================= counting

/// The rows `Walker.document` produces per section, counted first so that
/// `fromDocument` allocates each section's row list and cells once, at
/// their final size. It follows the walker's structure exactly (the tests
/// check that every list ends at its capacity).
const Counter = struct {
    n: [Section.all.len]usize = @splat(0),

    fn add(c: *Counter, sec: Section, k: usize) void {
        c.n[sec.index()] += k;
    }

    fn document(c: *Counter, doc: *const model.Document) void {
        switch (doc.root) {
            .record => |*r| {
                if (r.history != null) c.add(.history, 1);
                if (r.person) |*p| c.person(p);
                if (r.activities_summary) |*act| c.activities(act);
            },
            .activities_summary => |*x| c.activities(x),
            .works => |*x| c.works(x),
            .work => |*x| c.work(x),
            .work_summary => |*x| c.workSummary(x),
            .fundings => |*x| c.fundings(x),
            .funding => |*x| c.funding(x),
            .funding_summary => |*x| c.fundingSummary(x),
            .affiliations => |*x| c.affiliations(x),
            .affiliation, .affiliation_summary => |*x| c.affiliation(x),
            .peer_reviews => |*x| c.peerReviews(x),
            .peer_review => |*x| c.peerReview(x),
            .peer_review_summary => |*x| c.peerReviewSummary(x),
            .research_resources => |*x| c.researchResources(x),
            .research_resource => |*x| c.researchResource(x),
            .research_resource_summary => |*x| c.researchResourceSummary(x),
            .person => |*x| c.person(x),
            .personal_details => |*x| {
                c.add(.person, 1);
                if (x.other_names) |*l| c.add(.person_items, l.items.len);
            },
            .other_names => |*l| c.add(.person_items, l.items.len),
            .researcher_urls => |*l| c.add(.person_items, l.items.len),
            .emails => |*l| c.add(.person_items, l.items.len),
            .addresses => |*l| c.add(.person_items, l.items.len),
            .keywords => |*l| c.add(.person_items, l.items.len),
            .external_identifiers => |*l| c.add(.person_items, l.items.len),
            .other_name, .researcher_url, .email, .address, .keyword, .external_identifier => c.add(.person_items, 1),
            .history => c.add(.history, 1),
            .bulk => |*b| for (b.items) |*it| switch (it.*) {
                .work => |*x| c.work(x),
                .@"error" => c.add(.errors, 1),
            },
            .@"error" => c.add(.errors, 1),
            .search => |*x| c.add(.search_results, x.results.len),
            .expanded_search => |*x| c.add(.search_results, x.results.len),
            .group_id_record, .group_id_records => {},
            .name, .biography, .credit_name, .preferences, .unknown => {},
        }
    }

    fn activities(c: *Counter, a: *const model.ActivitiesSummary) void {
        if (a.distinctions) |*x| c.affiliations(x);
        if (a.educations) |*x| c.affiliations(x);
        if (a.employments) |*x| c.affiliations(x);
        if (a.fundings) |*x| c.fundings(x);
        if (a.invited_positions) |*x| c.affiliations(x);
        if (a.memberships) |*x| c.affiliations(x);
        if (a.peer_reviews) |*x| c.peerReviews(x);
        if (a.qualifications) |*x| c.affiliations(x);
        if (a.research_resources) |*x| c.researchResources(x);
        if (a.services) |*x| c.affiliations(x);
        if (a.works) |*x| c.works(x);
    }

    fn works(c: *Counter, x: *const model.Works) void {
        for (x.groups) |*g| {
            c.add(.external_ids, g.external_ids.len);
            for (g.work_summaries) |*sm| c.workSummary(sm);
        }
    }

    fn workSummary(c: *Counter, x: *const model.WorkSummary) void {
        c.add(.works, 1);
        c.add(.external_ids, x.external_ids.len);
    }

    fn work(c: *Counter, x: *const model.Work) void {
        c.add(.works, 1);
        c.add(.external_ids, x.external_ids.len);
        c.add(.contributors, x.contributors.len);
    }

    fn fundings(c: *Counter, x: *const model.Fundings) void {
        for (x.groups) |*g| {
            c.add(.external_ids, g.external_ids.len);
            for (g.funding_summaries) |*sm| c.fundingSummary(sm);
        }
    }

    fn fundingSummary(c: *Counter, x: *const model.FundingSummary) void {
        c.add(.fundings, 1);
        c.add(.external_ids, x.external_ids.len);
    }

    fn funding(c: *Counter, x: *const model.Funding) void {
        c.add(.fundings, 1);
        c.add(.external_ids, x.external_ids.len);
        c.add(.contributors, x.contributors.len);
    }

    fn affiliations(c: *Counter, x: *const model.Affiliations) void {
        for (x.groups) |*g| {
            c.add(.external_ids, g.external_ids.len);
            for (g.summaries) |*sm| c.affiliation(sm);
        }
    }

    fn affiliation(c: *Counter, x: *const model.Affiliation) void {
        c.add(.affiliations, 1);
        c.add(.external_ids, x.external_ids.len);
    }

    fn peerReviews(c: *Counter, x: *const model.PeerReviews) void {
        for (x.groups) |*g| {
            c.add(.external_ids, g.external_ids.len);
            for (g.duplicates) |*d| {
                c.add(.external_ids, d.external_ids.len);
                for (d.summaries) |*sm| c.peerReviewSummary(sm);
            }
        }
    }

    fn peerReviewSummary(c: *Counter, x: *const model.PeerReviewSummary) void {
        c.add(.peer_reviews, 1);
        c.add(.external_ids, x.external_ids.len);
    }

    fn peerReview(c: *Counter, x: *const model.PeerReview) void {
        c.add(.peer_reviews, 1);
        c.add(.external_ids, x.review_identifiers.len);
        if (x.subject_external_identifier != null) c.add(.external_ids, 1);
    }

    fn researchResources(c: *Counter, x: *const model.ResearchResources) void {
        for (x.groups) |*g| {
            c.add(.external_ids, g.external_ids.len);
            for (g.summaries) |*sm| c.researchResourceSummary(sm);
        }
    }

    fn researchResourceSummary(c: *Counter, x: *const model.ResearchResourceSummary) void {
        c.add(.research_resources, 1);
        if (x.proposal) |*p| {
            c.add(.external_ids, p.external_ids.len);
            c.add(.research_resource_hosts, p.hosts.len);
        }
    }

    fn researchResource(c: *Counter, x: *const model.ResearchResource) void {
        c.add(.research_resources, 1);
        if (x.proposal) |*p| {
            c.add(.external_ids, p.external_ids.len);
            c.add(.research_resource_hosts, p.hosts.len);
        }
        c.add(.research_resource_items, x.resource_items.len);
        for (x.resource_items) |*ri| {
            c.add(.external_ids, ri.external_ids.len);
            c.add(.research_resource_hosts, ri.hosts.len);
        }
    }

    fn person(c: *Counter, p: *const model.Person) void {
        c.add(.person, 1);
        if (p.other_names) |*l| c.add(.person_items, l.items.len);
        if (p.researcher_urls) |*l| c.add(.person_items, l.items.len);
        if (p.emails) |*l| c.add(.person_items, l.items.len);
        if (p.addresses) |*l| c.add(.person_items, l.items.len);
        if (p.keywords) |*l| c.add(.person_items, l.items.len);
        if (p.external_identifiers) |*l| c.add(.person_items, l.items.len);
    }
};

// =================================================================== schema
// From yorc-duckdb/src/core/sections.cpp (kColumns); keep in sync.

const V = ColType.varchar;
const I = ColType.integer;
const B = ColType.bigint;
const Bo = ColType.boolean;

const works_cols = [_]Column{
    col("orcid", V),                      col("put_code", B),                  col("group_index", I),
    col("display_index", I),              col("title", V),                     col("subtitle", V),
    col("journal", V),                    col("type", V),                      col("pub_year", I),
    col("pub_month", I),                  col("pub_day", I),                   col("doi", V),
    col("url", V),                        col("source_name", V),               col("visibility", V),
    col("created", V),                    col("last_modified", V),             col("source_hash", V),
    col("translated_title", V),           col("translated_title_language", V), col("short_description", V),
    col("citation_type", V),              col("citation_value", V),            col("language_code", V),
    col("country", V),                    col("path", V),                      col("source_client_id", V),
    col("source_orcid", V),               col("assertion_origin_name", V),     col("assertion_origin_orcid", V),
    col("assertion_origin_client_id", V), col("item", V),
};

const fundings_cols = [_]Column{
    col("orcid", V),                      col("put_code", B),             col("group_index", I),
    col("display_index", I),              col("title", V),                col("translated_title", V),
    col("translated_title_language", V),  col("type", V),                 col("organization_defined_type", V),
    col("short_description", V),          col("amount", V),               col("currency", V),
    col("start_year", I),                 col("start_month", I),          col("start_day", I),
    col("end_year", I),                   col("end_month", I),            col("end_day", I),
    col("org_name", V),                   col("org_city", V),             col("org_region", V),
    col("org_country", V),                col("org_disambiguated_id", V), col("org_disambiguation_source", V),
    col("url", V),                        col("visibility", V),           col("path", V),
    col("source_name", V),                col("source_client_id", V),     col("source_orcid", V),
    col("assertion_origin_name", V),      col("created", V),              col("last_modified", V),
    col("item", V),                       col("source_hash", V),
    // appended on 2026-10-18, as yorc-duckdb (sections.cpp)
             col("assertion_origin_orcid", V),
    col("assertion_origin_client_id", V),
};

const affiliations_cols = [_]Column{
    col("orcid", V),                     col("affiliation_type", V),           col("put_code", B),
    col("group_index", I),               col("display_index", I),              col("department", V),
    col("role_title", V),                col("start_year", I),                 col("start_month", I),
    col("start_day", I),                 col("end_year", I),                   col("end_month", I),
    col("end_day", I),                   col("org_name", V),                   col("org_city", V),
    col("org_region", V),                col("org_country", V),                col("org_disambiguated_id", V),
    col("org_disambiguation_source", V), col("url", V),                        col("visibility", V),
    col("path", V),                      col("source_name", V),                col("source_client_id", V),
    col("source_orcid", V),              col("assertion_origin_name", V),      col("created", V),
    col("last_modified", V),             col("item", V),                       col("source_hash", V),
    // appended on 2026-10-18, as yorc-duckdb (sections.cpp)
    col("assertion_origin_orcid", V),    col("assertion_origin_client_id", V),
};

const peer_reviews_cols = [_]Column{
    col("orcid", V),                               col("put_code", B),                   col("group_index", I),
    col("display_index", I),                       col("reviewer_role", V),              col("review_type", V),
    col("review_url", V),                          col("completion_year", I),            col("completion_month", I),
    col("completion_day", I),                      col("review_group_id", V),            col("subject_type", V),
    col("subject_name", V),                        col("subject_subtitle", V),           col("subject_translated_name", V),
    col("subject_container_name", V),              col("subject_url", V),                col("subject_id_type", V),
    col("subject_id_value", V),                    col("convening_org_name", V),         col("convening_org_city", V),
    col("convening_org_region", V),                col("convening_org_country", V),      col("convening_org_disambiguated_id", V),
    col("convening_org_disambiguation_source", V), col("visibility", V),                 col("path", V),
    col("source_name", V),                         col("source_client_id", V),           col("source_orcid", V),
    col("assertion_origin_name", V),               col("created", V),                    col("last_modified", V),
    col("item", V),                                col("source_hash", V),
    // after source_hash, as yorc-duckdb appends it (sections.cpp)
                   col("subject_translated_name_language", V),
    // appended on 2026-10-18, as yorc-duckdb (sections.cpp)
    col("assertion_origin_orcid", V),              col("assertion_origin_client_id", V),
};

const research_resources_cols = [_]Column{
    col("orcid", V),                      col("put_code", B),                   col("group_index", I),
    col("display_index", I),              col("title", V),                      col("translated_title", V),
    col("translated_title_language", V),  col("host_name", V),                  col("host_city", V),
    col("host_region", V),                col("host_country", V),               col("host_disambiguated_id", V),
    col("host_disambiguation_source", V), col("start_year", I),                 col("start_month", I),
    col("start_day", I),                  col("end_year", I),                   col("end_month", I),
    col("end_day", I),                    col("url", V),                        col("visibility", V),
    col("path", V),                       col("source_name", V),                col("source_client_id", V),
    col("source_orcid", V),               col("assertion_origin_name", V),      col("created", V),
    col("last_modified", V),              col("item", V),                       col("source_hash", V),
    // appended on 2026-10-18, as yorc-duckdb (sections.cpp)
    col("assertion_origin_orcid", V),     col("assertion_origin_client_id", V),
};

const research_resource_items_cols = [_]Column{
    col("orcid", V),                 col("owner_put_code", B),             col("ordinal", I),
    col("resource_name", V),         col("resource_type", V),              col("host_name", V),
    col("host_city", V),             col("host_region", V),                col("host_country", V),
    col("host_disambiguated_id", V), col("host_disambiguation_source", V), col("url", V),
    col("source_hash", V),
};

const contributors_cols = [_]Column{
    col("orcid", V),       col("owner", V),             col("owner_put_code", B),
    col("ordinal", I),     col("contributor_orcid", V), col("contributor_orcid_uri", V),
    col("credit_name", V), col("email", V),             col("sequence", V),
    col("role", V),        col("source_hash", V),
    // appended on 2026-10-18, as yorc-duckdb (sections.cpp)
          col("contributor_orcid_host", V),
};

const external_ids_cols = [_]Column{
    col("orcid", V),                 col("owner", V),        col("owner_put_code", B),
    col("group_index", I),           col("container", V),    col("type", V),
    col("value", V),                 col("normalized", V),   col("normalized_error", V),
    col("url", V),                   col("relationship", V), col("source_hash", V),
    // appended on 2026-10-18, as yorc-duckdb (sections.cpp)
    col("normalized_error_code", V),
};

const person_cols = [_]Column{
    col("orcid", V),                   col("given_names", V),     col("family_name", V),
    col("credit_name", V),             col("name_visibility", V), col("biography", V),
    col("biography_visibility", V),    col("last_modified", V),   col("name_last_modified", V),
    col("biography_last_modified", V), col("path", V),            col("item", V),
    col("source_hash", V),
    // appended on 2026-10-18, as yorc-duckdb (sections.cpp)
                col("orcid_uri", V),       col("orcid_host", V),
};

const person_items_cols = [_]Column{
    col("orcid", V),                 col("kind", V),                   col("put_code", B),
    col("display_index", I),         col("value", V),                  col("url", V),
    col("type", V),                  col("relationship", V),           col("verified", Bo),
    col("primary", Bo),              col("visibility", V),             col("path", V),
    col("source_name", V),           col("source_client_id", V),       col("source_orcid", V),
    col("created", V),               col("last_modified", V),          col("source_hash", V),
    // appended on 2026-10-18, as yorc-duckdb (sections.cpp)
    col("assertion_origin_name", V), col("assertion_origin_orcid", V), col("assertion_origin_client_id", V),
    col("normalized", V),            col("normalized_error", V),       col("normalized_error_code", V),
};

const history_cols = [_]Column{
    col("orcid", V),                  col("creation_method", V),            col("completion_date", V),
    col("submission_date", V),        col("last_modified", V),              col("claimed", Bo),
    col("deactivation_date", V),      col("verified_email", Bo),            col("verified_primary_email", Bo),
    col("visibility", V),             col("source_name", V),                col("source_client_id", V),
    col("source_orcid", V),           col("source_hash", V),
    // appended on 2026-10-18, as yorc-duckdb (sections.cpp)
                   col("assertion_origin_name", V),
    col("assertion_origin_orcid", V), col("assertion_origin_client_id", V),
};

const search_results_cols = [_]Column{
    col("num_found", B),    col("ordinal", I),           col("orcid", V),
    col("orcid_uri", V),    col("orcid_host", V),        col("given_names", V),
    col("family_names", V), col("credit_name", V),       col("other_names", V),
    col("emails", V),       col("institution_names", V), col("item", V),
    col("source_hash", V),
};

const errors_cols = [_]Column{
    col("orcid", V),         col("response_code", I), col("developer_message", V),
    col("user_message", V),  col("error_code", I),    col("more_info", V),
    col("container", V),     col("position", I),      col("source_hash", V),
    // after source_hash, as yorc-duckdb appends it (sections.cpp)
    col("primary_orcid", V),
};

const research_resource_hosts_cols = [_]Column{
    col("orcid", V),        col("owner_put_code", B),        col("ordinal", I),
    col("host_name", V),    col("host_city", V),             col("host_region", V),
    col("host_country", V), col("host_disambiguated_id", V), col("host_disambiguation_source", V),
    col("container", V),    col("item_ordinal", I),          col("source_hash", V),
};

test "schema matches yorc-duckdb" {
    const want = [_]struct { []const u8, usize }{
        .{ "works", 32 },        .{ "fundings", 37 },                .{ "affiliations", 32 },
        .{ "peer_reviews", 38 }, .{ "research_resources", 32 },      .{ "research_resource_items", 13 },
        .{ "contributors", 12 }, .{ "external_ids", 13 },            .{ "person", 15 },
        .{ "person_items", 24 }, .{ "history", 17 },                 .{ "search_results", 13 },
        .{ "errors", 10 },       .{ "research_resource_hosts", 12 },
    };
    var total: usize = 0;
    for (Section.all, want) |s, w| {
        try std.testing.expectEqualStrings(w[0], s.name());
        try std.testing.expectEqual(w[1], s.columns().len);
        total += s.columns().len;
        try std.testing.expectEqual(@as(?Section, s), Section.fromName(s.name()));
        // search_results starts with num_found (yorc-duckdb's REFERENCE.md)
        try std.testing.expectEqualStrings(if (s == .search_results) "num_found" else "orcid", s.columns()[0].name);
        try std.testing.expect(s.columnIndex("source_hash") != null);
    }
    try std.testing.expectEqual(@as(usize, 300), total);
    try std.testing.expectEqual(@as(?Section, null), Section.fromName("timeline"));
    try std.testing.expectEqual(@as(?Section, null), Section.fromName("summary"));
}

fn expectId(want: []const u8, got: ?orcid_id.Canonical) !void {
    const g = got orelse return error.TestExpectedId;
    try std.testing.expectEqualStrings(want, &g);
}

test "idAfter follows yorc-duckdb" {
    const locked = "409 Conflict: The ORCID record is locked and cannot be edited. ORCID https://orcid.org/0000-0001-5272-5001";
    // the first "ORCID " is followed by "record": skipped
    try expectId("0000-0001-5272-5001", idAfter(locked, "ORCID "));
    const deprecated = "Please refer to account: https://orcid.org/0009-0008-8963-1314.";
    try expectId("0009-0008-8963-1314", idAfter(deprecated, "refer to account:"));
    // bare, several spaces, trailing punctuation
    try expectId("0000-0002-1825-0097", idAfter("ORCID   0000-0002-1825-0097);", "ORCID "));
    // a wrong check digit, no marker, nothing after the marker
    try std.testing.expect(idAfter("ORCID 0000-0002-1825-0098", "ORCID ") == null);
    try std.testing.expect(idAfter("no iD here", "ORCID ") == null);
    try std.testing.expect(idAfter("ORCID ", "ORCID ") == null);
    // non-ASCII text around the marker
    try expectId("0000-0002-1825-0097", idAfter("\u{e9} ORCID 0000-0002-1825-0097 \u{fc}", "ORCID "));
}

test "integer columns follow yorc-duckdb" {
    try std.testing.expectEqual(@as(?i64, 409), digits(409, max_integer));
    try std.testing.expectEqual(@as(?i64, null), digits(-1, max_integer));
    const big: i64 = 1_000_000_000; // 10 digits
    try std.testing.expectEqual(@as(?i64, null), digits(big, max_integer));
    try std.testing.expectEqual(@as(?i64, big), digits(big, max_bigint));
    try std.testing.expectEqual(@as(?i64, null), digits(null, max_bigint));
}

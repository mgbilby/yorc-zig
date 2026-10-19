//! yorc-duckdb's `timeline` and `group_ids` sections (`Extra`), its snapshot
//! diff `orcid_changes` (`changes`), and `sectionRows`: yorc-rs's
//! `rows::Extra`, `rows::timeline`, `rows::group_ids`, `rows::changes` and
//! `rows::section_rows`, with the same rules and the same rows (re-exported
//! by `rows.zig`).
//!
//! The extra sections are kept apart from `Section` and `Tables`, so that
//! those stay exactly as they are (the fourteen sections and their 300
//! columns); nothing builds them unless asked.
//!
//! `timeline`: one row per dated event of the document's items (every
//! activity, person item, name and biography): a `created` row (`event_at` =
//! `created`) and, when the last modification differs, a `modified` row
//! (`event_at` = `last_modified`); an item with only a modification date
//! gives just that row, an undated item one row with NULL `event_at` and
//! `event`. Items come in document (XSD) order: the person's name, other
//! names, biography, researcher URLs, emails, addresses, keywords and
//! external identifiers, then the activities in `activities-summary` order.
//! `kind` is the item element without `-summary`; `label` the item's title
//! (works: else its `country`), role title (affiliations), subject name
//! (full peer reviews), proposal title (research resources), value (person
//! items: content, URL name, email, country, external-id value) or given
//! names (name); `organization` the organization (fundings, affiliations),
//! convening organization (peer reviews) or first named proposal host
//! (research resources). A single person item, name or biography document
//! has no timeline rows (yorc-duckdb's patterns need the container).
//!
//! `group_ids`: one row per `group-id-record` (a document of its own, or each
//! record of a `group-id-records` page, whose `total`, `page` and `page_size`
//! repeat on every row; NULL for a single record).
//!
//! `changes`: see the function. Results own their memory (an arena; call
//! `deinit`), so they outlive the documents.
const std = @import("std");
const model = @import("model.zig");
const rows = @import("rows.zig");
const xml_read = @import("xml_read.zig");
const hash = @import("hash.zig");
const padInt = @import("xml_write.zig").padInt;

const Allocator = std.mem.Allocator;
const OOM = error{OutOfMemory};
const Text = model.Text;
const Cell = rows.Cell;
const Row = rows.Row;
const Column = rows.Column;
const Section = rows.Section;
const Tables = rows.Tables;

fn col(name: []const u8, ty: rows.ColType) Column {
    return .{ .name = name, .ty = ty };
}

/// A section of yorc-duckdb outside `Section.all`: built only on request.
pub const Extra = enum {
    timeline,
    group_ids,

    pub const all = [_]Extra{ .timeline, .group_ids };

    /// Table name (`timeline`, `group_ids`).
    pub fn name(e: Extra) []const u8 {
        return @tagName(e);
    }

    pub fn fromName(text: []const u8) ?Extra {
        return std.meta.stringToEnum(Extra, text);
    }

    /// Columns in table order (yorc-duckdb's).
    pub fn columns(e: Extra) []const Column {
        return switch (e) {
            .timeline => &timeline_cols,
            .group_ids => &group_ids_cols,
        };
    }

    /// Position of a column, by name.
    pub fn columnIndex(e: Extra, column: []const u8) ?usize {
        for (e.columns(), 0..) |c, i| if (std.mem.eql(u8, c.name, column)) return i;
        return null;
    }
};

const timeline_cols = [_]Column{
    col("orcid", .varchar),
    col("event_at", .varchar),
    col("event", .varchar),
    col("kind", .varchar),
    col("put_code", .bigint),
    col("label", .varchar),
    col("organization", .varchar),
    col("visibility", .varchar),
    col("source_name", .varchar),
    col("created", .varchar),
    col("last_modified", .varchar),
    col("path", .varchar),
    col("source_hash", .varchar),
};

const group_ids_cols = [_]Column{
    col("put_code", .bigint),
    col("name", .varchar),
    col("group_id", .varchar),
    col("description", .varchar),
    col("type", .varchar),
    col("source_name", .varchar),
    col("source_client_id", .varchar),
    col("source_orcid", .varchar),
    col("total", .integer),
    col("page", .integer),
    col("page_size", .integer),
    col("source_hash", .varchar),
};

/// The rows of one extra section, owning their memory.
pub const ExtraRows = struct {
    arena: *std.heap.ArenaAllocator,
    extra: Extra,
    rows: []const Row,

    pub fn deinit(r: *ExtraRows) void {
        const child = r.arena.child_allocator;
        r.arena.deinit();
        child.destroy(r.arena);
        r.* = undefined;
    }

    /// Value of column `column` in row `row`.
    pub fn cell(r: *const ExtraRows, row: usize, column: []const u8) ?Cell {
        const i = r.extra.columnIndex(column) orelse return null;
        if (row >= r.rows.len) return null;
        return r.rows[row][i];
    }
};

fn newArena(gpa: Allocator) OOM!*std.heap.ArenaAllocator {
    const arena = try gpa.create(std.heap.ArenaAllocator);
    arena.* = .init(gpa);
    return arena;
}

fn freeArena(arena: *std.heap.ArenaAllocator) void {
    const child = arena.child_allocator;
    arena.deinit();
    child.destroy(arena);
}

/// The rows of `extra` for one document; `source_hash` fills the
/// `source_hash` column.
pub fn extraRows(gpa: Allocator, doc: *const model.Document, extra: Extra, source_hash: ?[]const u8) OOM!ExtraRows {
    const arena = try newArena(gpa);
    errdefer freeArena(arena);
    const a = arena.allocator();
    const h: ?[]const u8 = if (source_hash) |x| try a.dupe(u8, x) else null;
    const out: []const Row = switch (extra) {
        .timeline => try timelineRows(a, doc, h),
        .group_ids => try groupIdRows(a, doc, h),
    };
    return .{ .arena = arena, .extra = extra, .rows = out };
}

/// The `timeline` rows of a document.
pub fn timeline(gpa: Allocator, doc: *const model.Document, source_hash: ?[]const u8) OOM!ExtraRows {
    return extraRows(gpa, doc, .timeline, source_hash);
}

/// The `group_ids` rows of a document: none unless it is a
/// `group-id-record` or a `group-id-records` page.
pub fn groupIds(gpa: Allocator, doc: *const model.Document, source_hash: ?[]const u8) OOM!ExtraRows {
    return extraRows(gpa, doc, .group_ids, source_hash);
}

/// Parses `xml` and returns the rows of one extra section, with
/// `source_hash` = SHA-256 of `xml`: what `orcid_<section>_xml(xml)`
/// returns.
pub fn extraFromXml(gpa: Allocator, extra: Extra, xml: []const u8) xml_read.ParseError!ExtraRows {
    var doc = try xml_read.parse(gpa, xml, .{}, null);
    defer doc.deinit();
    const h = hash.sha256Hex(xml);
    return extraRows(gpa, &doc, extra, &h);
}

// ================================================================ group ids

fn copy(a: Allocator, v: ?[]const u8) OOM!Cell {
    const x = v orelse return .null;
    return .{ .varchar = try a.dupe(u8, x) };
}

fn integer(v: ?i64) Cell {
    return if (v) |n| .{ .integer = n } else .null;
}

fn idPath(id: ?model.OrcidIdentifier) ?Text {
    const x = id orelse return null;
    return x.path;
}

fn groupIdRows(a: Allocator, doc: *const model.Document, h: ?[]const u8) OOM![]const Row {
    switch (doc.root) {
        .group_id_record => |*r| {
            const out = try a.alloc(Row, 1);
            out[0] = try groupIdRow(a, r, null, h);
            return out;
        },
        .group_id_records => |*pg| {
            const out = try a.alloc(Row, pg.records.len);
            for (pg.records, out) |*r, *slot| slot.* = try groupIdRow(a, r, pg, h);
            return out;
        },
        else => return &.{},
    }
}

fn groupIdRow(a: Allocator, r: *const model.GroupIdRecord, pg: ?*const model.GroupIdRecords, h: ?[]const u8) OOM!Row {
    const src: ?model.Source = r.source;
    const cells = try a.alloc(Cell, group_ids_cols.len);
    cells[0] = integer(r.put_code);
    cells[1] = try copy(a, r.name);
    cells[2] = try copy(a, r.group_id);
    cells[3] = try copy(a, r.description);
    cells[4] = try copy(a, if (r.group_type) |t| t.text() else null);
    cells[5] = try copy(a, if (src) |s| s.source_name else null);
    cells[6] = try copy(a, if (src) |s| idPath(s.source_client_id) else null);
    cells[7] = try copy(a, if (src) |s| idPath(s.source_orcid) else null);
    cells[8] = integer(if (pg) |x| x.total else null);
    cells[9] = integer(if (pg) |x| x.page else null);
    cells[10] = integer(if (pg) |x| x.page_size else null);
    cells[11] = if (h) |x| .{ .varchar = x } else .null;
    return cells;
}

// ================================================================= timeline

/// One dated item, before it becomes its events.
const Item = struct {
    kind: []const u8,
    put_code: ?i64 = null,
    label: ?Text = null,
    organization: ?Text = null,
    visibility: ?model.Visibility = null,
    source_name: ?Text = null,
    created: ?Text = null,
    last_modified: ?Text = null,
    path: ?Text = null,
};

fn itemOf(kind: []const u8, m: *const model.ItemMeta, label: ?Text, organization: ?Text) Item {
    return .{
        .kind = kind,
        .put_code = m.put_code,
        .label = label,
        .organization = organization,
        .visibility = m.visibility,
        .source_name = if (m.source) |s| s.source_name else null,
        .created = m.created_date,
        .last_modified = m.last_modified_date,
        .path = m.path,
    };
}

fn titleOf(t: ?model.Title) ?Text {
    const x = t orelse return null;
    return x.title;
}

fn orgName(o: ?model.Organization) ?Text {
    const x = o orelse return null;
    return x.name;
}

fn timelineRows(a: Allocator, doc: *const model.Document, h: ?[]const u8) OOM![]const Row {
    var t: Timeline = .{
        .a = a,
        .doc_orcid = if (doc.orcid()) |o| try a.dupe(u8, o) else null,
        .hash = h,
    };
    try t.document(doc);
    return t.out.items;
}

const Timeline = struct {
    a: Allocator,
    doc_orcid: ?[]const u8,
    hash: ?[]const u8,
    out: std.ArrayList(Row) = .empty,

    /// The row's `orcid`: the document's, else the item path's first segment.
    fn orcidCell(t: *Timeline, item_path: ?Text) OOM!Cell {
        if (t.doc_orcid) |o| return .{ .varchar = o };
        const p = item_path orelse return .null;
        const seg = model.firstPathSegment(model.trimXmlSpace(p));
        if (seg.len == 0) return .null;
        return copy(t.a, seg);
    }

    fn row(t: *Timeline, it: Item, event_at: ?Text, event: ?[]const u8) OOM!Row {
        const cells = try t.a.alloc(Cell, timeline_cols.len);
        cells[0] = try t.orcidCell(it.path);
        cells[1] = try copy(t.a, event_at);
        cells[2] = if (event) |e| .{ .varchar = e } else .null;
        cells[3] = .{ .varchar = it.kind };
        cells[4] = integer(it.put_code);
        cells[5] = try copy(t.a, it.label);
        cells[6] = try copy(t.a, it.organization);
        cells[7] = try copy(t.a, if (it.visibility) |v| v.text() else null);
        cells[8] = try copy(t.a, it.source_name);
        cells[9] = try copy(t.a, it.created);
        cells[10] = try copy(t.a, it.last_modified);
        cells[11] = try copy(t.a, it.path);
        cells[12] = if (t.hash) |x| .{ .varchar = x } else .null;
        return cells;
    }

    /// The item's events: `created`, then `modified` if it differs; one row
    /// with NULL `event_at` / `event` for an undated item.
    fn push(t: *Timeline, it: Item) OOM!void {
        if (it.created) |c| try t.out.append(t.a, try t.row(it, c, "created"));
        if (it.last_modified) |m| {
            const same = if (it.created) |c| std.mem.eql(u8, c, m) else false;
            if (!same) try t.out.append(t.a, try t.row(it, m, "modified"));
        }
        if (it.created == null and it.last_modified == null) try t.out.append(t.a, try t.row(it, null, null));
    }

    fn document(t: *Timeline, doc: *const model.Document) OOM!void {
        switch (doc.root) {
            .record => |*r| {
                if (r.person) |*p| try t.person(p);
                if (r.activities_summary) |*act| try t.activities(act);
            },
            .activities_summary => |*x| try t.activities(x),
            .works => |*x| try t.works(x),
            .work => |*x| try t.work(x),
            .work_summary => |*x| try t.workSummary(x),
            .fundings => |*x| try t.fundings(x),
            .funding => |*x| try t.push(itemOf("funding", &x.meta, titleOf(x.title), orgName(x.organization))),
            .funding_summary => |*x| try t.push(itemOf("funding", &x.meta, titleOf(x.title), orgName(x.organization))),
            .affiliations => |*x| try t.affiliations(x),
            .affiliation, .affiliation_summary => |*x| try t.affiliation(x),
            .peer_reviews => |*x| try t.peerReviews(x),
            .peer_review => |*x| try t.push(itemOf("peer-review", &x.meta, titleOf(x.subject_name), orgName(x.convening_organization))),
            .peer_review_summary => |*x| try t.push(itemOf("peer-review", &x.meta, null, orgName(x.convening_organization))),
            .research_resources => |*x| try t.researchResources(x),
            .research_resource => |*x| try t.researchResource(&x.meta, x.proposal),
            .research_resource_summary => |*x| try t.researchResource(&x.meta, x.proposal),
            .person => |*x| try t.person(x),
            .personal_details => |*x| {
                try t.name(x.name);
                try t.otherNames(x.other_names);
                try t.biography(x.biography);
            },
            .other_names => |*l| try t.otherNames(l.*),
            .researcher_urls => |*l| try t.researcherUrls(l.*),
            .emails => |*l| try t.emails(l.*),
            .addresses => |*l| try t.addresses(l.*),
            .keywords => |*l| try t.keywords(l.*),
            .external_identifiers => |*l| try t.externalIdentifiers(l.*),
            .bulk => |*b| for (b.items) |*item| switch (item.*) {
                .work => |*x| try t.work(x),
                .@"error" => {},
            },
            // a single person item, name or biography is not a timeline item
            // on its own (yorc-duckdb's patterns need its container)
            .name, .biography, .credit_name, .other_name, .researcher_url, .email, .address, .keyword, .external_identifier, .history, .preferences, .@"error", .search, .expanded_search, .group_id_record, .group_id_records, .unknown => {},
        }
    }

    // ------------------------------------------------------------- person

    fn person(t: *Timeline, p: *const model.Person) OOM!void {
        try t.name(p.name);
        try t.otherNames(p.other_names);
        try t.biography(p.biography);
        try t.researcherUrls(p.researcher_urls);
        try t.emails(p.emails);
        try t.addresses(p.addresses);
        try t.keywords(p.keywords);
        try t.externalIdentifiers(p.external_identifiers);
    }

    fn name(t: *Timeline, n: ?model.Name) OOM!void {
        const x = n orelse return;
        try t.push(.{
            .kind = "name",
            .label = x.given_names,
            .visibility = x.visibility,
            .created = x.created_date,
            .last_modified = x.last_modified_date,
            .path = x.path,
        });
    }

    fn biography(t: *Timeline, b: ?model.Biography) OOM!void {
        const x = b orelse return;
        try t.push(.{
            .kind = "biography",
            .label = x.content,
            .visibility = x.visibility,
            .created = x.created_date,
            .last_modified = x.last_modified_date,
            .path = x.path,
        });
    }

    fn otherNames(t: *Timeline, l: ?model.OtherNames) OOM!void {
        const x = l orelse return;
        for (x.items) |*i| try t.push(itemOf("other-name", &i.meta, i.content, null));
    }

    fn researcherUrls(t: *Timeline, l: ?model.ResearcherUrls) OOM!void {
        const x = l orelse return;
        for (x.items) |*i| try t.push(itemOf("researcher-url", &i.meta, i.url_name, null));
    }

    fn emails(t: *Timeline, l: ?model.Emails) OOM!void {
        const x = l orelse return;
        for (x.items) |*i| try t.push(itemOf("email", &i.meta, i.email, null));
    }

    fn addresses(t: *Timeline, l: ?model.Addresses) OOM!void {
        const x = l orelse return;
        for (x.items) |*i| try t.push(itemOf("address", &i.meta, i.country, null));
    }

    fn keywords(t: *Timeline, l: ?model.Keywords) OOM!void {
        const x = l orelse return;
        for (x.items) |*i| try t.push(itemOf("keyword", &i.meta, i.content, null));
    }

    fn externalIdentifiers(t: *Timeline, l: ?model.ExternalIdentifiers) OOM!void {
        const x = l orelse return;
        for (x.items) |*i| try t.push(itemOf("external-identifier", &i.meta, i.value, null));
    }

    // --------------------------------------------------------- activities

    /// Sections in `activities-summary` (XSD) order.
    fn activities(t: *Timeline, s: *const model.ActivitiesSummary) OOM!void {
        if (s.distinctions) |*x| try t.affiliations(x);
        if (s.educations) |*x| try t.affiliations(x);
        if (s.employments) |*x| try t.affiliations(x);
        if (s.fundings) |*x| try t.fundings(x);
        if (s.invited_positions) |*x| try t.affiliations(x);
        if (s.memberships) |*x| try t.affiliations(x);
        if (s.peer_reviews) |*x| try t.peerReviews(x);
        if (s.qualifications) |*x| try t.affiliations(x);
        if (s.research_resources) |*x| try t.researchResources(x);
        if (s.services) |*x| try t.affiliations(x);
        if (s.works) |*x| try t.works(x);
    }

    fn works(t: *Timeline, w: *const model.Works) OOM!void {
        for (w.groups) |*g| {
            for (g.work_summaries) |*x| try t.workSummary(x);
        }
    }

    fn workSummary(t: *Timeline, x: *const model.WorkSummary) OOM!void {
        try t.push(itemOf("work", &x.meta, titleOf(x.title), null));
    }

    fn work(t: *Timeline, x: *const model.Work) OOM!void {
        // `title/title`, else `country` (its place in the work's sequence)
        const label = titleOf(x.title) orelse (if (x.country) |c| c.value else null);
        try t.push(itemOf("work", &x.meta, label, null));
    }

    fn fundings(t: *Timeline, f: *const model.Fundings) OOM!void {
        for (f.groups) |*g| {
            for (g.funding_summaries) |*x| try t.push(itemOf("funding", &x.meta, titleOf(x.title), orgName(x.organization)));
        }
    }

    fn affiliations(t: *Timeline, l: *const model.Affiliations) OOM!void {
        for (l.groups) |*g| {
            for (g.summaries) |*x| try t.affiliation(x);
        }
    }

    fn affiliation(t: *Timeline, x: *const model.Affiliation) OOM!void {
        try t.push(itemOf(x.kind.element(), &x.meta, x.role_title, orgName(x.organization)));
    }

    fn peerReviews(t: *Timeline, p: *const model.PeerReviews) OOM!void {
        for (p.groups) |*g| {
            for (g.duplicates) |*d| {
                for (d.summaries) |*x| try t.push(itemOf("peer-review", &x.meta, null, orgName(x.convening_organization)));
            }
        }
    }

    fn researchResources(t: *Timeline, r: *const model.ResearchResources) OOM!void {
        for (r.groups) |*g| {
            for (g.summaries) |*x| try t.researchResource(&x.meta, x.proposal);
        }
    }

    fn researchResource(t: *Timeline, meta: *const model.ItemMeta, proposal: ?model.Proposal) OOM!void {
        var label: ?Text = null;
        var org: ?Text = null;
        if (proposal) |p| {
            label = titleOf(p.title);
            for (p.hosts) |h| {
                if (h.name) |n| {
                    org = n;
                    break;
                }
            }
        }
        try t.push(itemOf("research-resource", meta, label, org));
    }
};

// ================================================================== changes

/// The sections `changes` compares, in output order (yorc-duckdb's
/// `DiffSections`).
pub const diff_sections = [_]Section{
    .person,
    .person_items,
    .works,
    .fundings,
    .affiliations,
    .peer_reviews,
    .research_resources,
    .history,
};

/// The columns of a change row (`Change.cells`), as yorc-duckdb's
/// `orcid_changes` returns them.
pub const change_columns = [_]Column{
    col("orcid", .varchar),
    col("section", .varchar),
    col("kind", .varchar),
    col("put_code", .bigint),
    col("change", .varchar),
    col("field", .varchar),
    col("old_value", .varchar),
    col("new_value", .varchar),
    col("label", .varchar),
};

/// How an item changed.
pub const ChangeKind = enum {
    added,
    removed,
    modified,

    pub fn text(k: ChangeKind) []const u8 {
        return @tagName(k);
    }
};

/// One difference between two snapshots (a row of yorc-duckdb's
/// `orcid_changes`).
pub const Change = struct {
    orcid: ?[]const u8 = null,
    section: Section,
    /// The item kind where the section mixes kinds (affiliations, person items).
    kind: ?[]const u8 = null,
    /// null for person and history.
    put_code: ?i64 = null,
    change: ChangeKind,
    /// The changed column (modified only).
    field: ?[]const u8 = null,
    old_value: ?[]const u8 = null,
    new_value: ?[]const u8 = null,
    /// Title, role, value, ... of the item (the new side's, except for a
    /// removed item).
    label: ?[]const u8 = null,

    /// The change as a row of `change_columns` (cells borrow the change).
    pub fn cells(c: *const Change) [change_columns.len]Cell {
        const s = struct {
            fn v(x: ?[]const u8) Cell {
                return if (x) |y| .{ .varchar = y } else .null;
            }
        }.v;
        return .{
            s(c.orcid),
            .{ .varchar = c.section.name() },
            s(c.kind),
            integer(c.put_code),
            .{ .varchar = c.change.text() },
            s(c.field),
            s(c.old_value),
            s(c.new_value),
            s(c.label),
        };
    }
};

/// The changes between two snapshots, owning their memory.
pub const Changes = struct {
    arena: *std.heap.ArenaAllocator,
    items: []const Change,

    pub fn deinit(c: *Changes) void {
        freeArena(c.arena);
        c.* = undefined;
    }
};

/// Columns whose values never count as a change.
const ignored_columns = [_][]const u8{ "source_hash", "item" };

/// Columns that label an item, in preference order.
const label_columns = [_][]const u8{
    "title",
    "role_title",
    "value",
    "subject_name",
    "org_name",
    "convening_org_name",
    "given_names",
    "creation_method",
};

/// The differences between two snapshots of a record, as yorc-duckdb's
/// `orcid_changes(old, new)` lists them (yorc-rs's `rows::changes`). null is
/// no snapshot: every item of the other side is then added (or removed).
///
/// Items are matched on section, kind and put-code (person and history on
/// the section alone); a key repeated within a snapshot pairs up in order.
/// Every column but `source_hash` and `item` is compared, so a modified item
/// gives one change per differing column, in column order. Changes come
/// section by section (`diff_sections`); within a section, modified and
/// added items in the new snapshot's order, then removed items in the old
/// one's. Values are text as ORCID writes them: integers in decimal,
/// fuzzy-date parts zero-padded (`*_year` to 4 digits, `*_month` and `*_day`
/// to 2), booleans `true`/`false` (yorc-duckdb compares the document's text:
/// `01` and `1`, or a `display-index` of `-1`, can differ there).
pub fn changes(gpa: Allocator, old: ?*const model.Document, new: ?*const model.Document) OOM!Changes {
    const arena = try newArena(gpa);
    errdefer freeArena(arena);
    const a = arena.allocator();
    var old_t: ?Tables = if (old) |d| try Tables.fromDocument(gpa, d, null) else null;
    defer if (old_t) |*t| t.deinit();
    var new_t: ?Tables = if (new) |d| try Tables.fromDocument(gpa, d, null) else null;
    defer if (new_t) |*t| t.deinit();
    var out: std.ArrayList(Change) = .empty;
    for (diff_sections) |sec| {
        const old_rows: []const Row = if (old_t) |*t| t.get(sec) else &.{};
        const new_rows: []const Row = if (new_t) |*t| t.get(sec) else &.{};
        try diffSection(gpa, a, sec, old_rows, new_rows, &out);
    }
    return .{ .arena = arena, .items = out.items };
}

/// A row's match key: kind, put-code (or `\x1e`) and its occurrence among
/// the rows with the same kind and put-code (yorc-duckdb's `KeyRows`).
const Keyed = struct {
    key: []const u8,
    kind: []const u8,
    put_code: ?i64,
};

fn keyRows(a: Allocator, scratch: Allocator, section_rows: []const Row, kind_col: ?usize, put_col: ?usize) OOM![]const Keyed {
    var seen: std.StringHashMapUnmanaged(usize) = .empty;
    defer seen.deinit(scratch);
    const out = try a.alloc(Keyed, section_rows.len);
    for (section_rows, out) |r, *k| {
        const kind: []const u8 = if (kind_col) |c| (r[c].asStr() orelse "") else "";
        const put_code: ?i64 = if (put_col) |c| r[c].asInt() else null;
        var buf: [24]u8 = undefined;
        const put_text: []const u8 = if (put_code) |p| padInt(&buf, p, 0) else "\x1e";
        const base = try std.mem.concat(a, u8, &.{ kind, "\x1f", put_text });
        const gop = try seen.getOrPut(scratch, base);
        if (!gop.found_existing) gop.value_ptr.* = 0;
        const n = gop.value_ptr.*;
        gop.value_ptr.* += 1;
        k.* = .{
            .key = try std.fmt.allocPrint(a, "{s}\x1f{d}", .{ base, n }),
            .kind = kind,
            .put_code = put_code,
        };
    }
    return out;
}

/// A cell as yorc-duckdb's change rows show it (see `changes`).
fn cellText(a: Allocator, column: []const u8, c: Cell) OOM!?[]const u8 {
    return switch (c) {
        .null => null,
        .varchar => |s| try a.dupe(u8, s),
        .integer => |v| blk: {
            const width: usize = if (std.mem.endsWith(u8, column, "_year"))
                4
            else if (std.mem.endsWith(u8, column, "_month") or std.mem.endsWith(u8, column, "_day"))
                2
            else
                0;
            var buf: [24]u8 = undefined;
            break :blk try a.dupe(u8, padInt(&buf, v, width));
        },
        .boolean => |b| if (b) "true" else "false",
    };
}

fn cellEql(x: Cell, y: Cell) bool {
    return switch (x) {
        .null => y == .null,
        .varchar => |s| y == .varchar and std.mem.eql(u8, s, y.varchar),
        .integer => |v| y == .integer and v == y.integer,
        .boolean => |b| y == .boolean and b == y.boolean,
    };
}

fn contains(list: []const []const u8, s: []const u8) bool {
    for (list) |x| if (std.mem.eql(u8, x, s)) return true;
    return false;
}

const SectionDiff = struct {
    a: Allocator,
    sec: Section,
    orcid_col: ?usize,
    label_cols: []const usize,

    fn label(d: *const SectionDiff, r: Row) OOM!?[]const u8 {
        for (d.label_cols) |c| {
            if (!r[c].isNull()) return cellText(d.a, d.sec.columns()[c].name, r[c]);
        }
        return null;
    }

    fn base(d: *const SectionDiff, k: Keyed, r: Row, change: ChangeKind) OOM!Change {
        const orcid: ?[]const u8 = if (d.orcid_col) |c| r[c].asStr() else null;
        return .{
            .orcid = if (orcid) |o| (if (o.len > 0) try d.a.dupe(u8, o) else null) else null,
            .section = d.sec,
            .kind = if (k.kind.len > 0) try d.a.dupe(u8, k.kind) else null,
            .put_code = k.put_code,
            .change = change,
            .label = try d.label(r),
        };
    }
};

fn diffSection(gpa: Allocator, a: Allocator, sec: Section, old: []const Row, new: []const Row, out: *std.ArrayList(Change)) OOM!void {
    const cols = sec.columns();
    var kind_col: ?usize = null;
    for (cols, 0..) |c, i| {
        if (std.mem.eql(u8, c.name, "affiliation_type") or std.mem.eql(u8, c.name, "kind")) {
            kind_col = i;
            break;
        }
    }
    var labels: std.ArrayList(usize) = .empty;
    for (label_columns) |n| {
        if (sec.columnIndex(n)) |i| try labels.append(a, i);
    }
    const d: SectionDiff = .{ .a = a, .sec = sec, .orcid_col = sec.columnIndex("orcid"), .label_cols = labels.items };

    const old_keyed = try keyRows(a, gpa, old, kind_col, sec.columnIndex("put_code"));
    const new_keyed = try keyRows(a, gpa, new, kind_col, sec.columnIndex("put_code"));
    var old_by_key: std.StringHashMapUnmanaged(usize) = .empty;
    defer old_by_key.deinit(gpa);
    for (old_keyed, 0..) |k, i| try old_by_key.put(gpa, k.key, i);
    const matched = try gpa.alloc(bool, old.len);
    defer gpa.free(matched);
    @memset(matched, false);

    for (new_keyed, new) |k, n| {
        const i = old_by_key.get(k.key) orelse {
            try out.append(a, try d.base(k, n, .added));
            continue;
        };
        matched[i] = true;
        const o = old[i];
        for (cols, 0..) |column, c| {
            if (contains(&ignored_columns, column.name) or cellEql(o[c], n[c])) continue;
            var change = try d.base(k, n, .modified);
            change.field = column.name;
            change.old_value = try cellText(a, column.name, o[c]);
            change.new_value = try cellText(a, column.name, n[c]);
            try out.append(a, change);
        }
    }
    for (old_keyed, old, matched) |k, o, m| {
        if (!m) try out.append(a, try d.base(k, o, .removed));
    }
}

// =============================================================== sectionRows

/// The rows of one section, with the tables that own them.
pub const SectionRows = struct {
    tables: Tables,
    rows: []const Row,

    pub fn deinit(s: *SectionRows) void {
        s.tables.deinit();
        s.* = undefined;
    }
};

/// Rows of one section (yorc-rs's `section_rows`): the tables are built
/// for the document and the section's rows taken out of them.
pub fn sectionRows(gpa: Allocator, doc: *const model.Document, section: Section, source_hash: ?[]const u8) OOM!SectionRows {
    var t = try Tables.fromDocument(gpa, doc, source_hash);
    const r = t.take(section);
    return .{ .tables = t, .rows = r };
}

// ==================================================================== tests

const testing = std.testing;

test "extra section schemas" {
    try testing.expectEqual(@as(usize, 13), Extra.timeline.columns().len);
    try testing.expectEqual(@as(usize, 12), Extra.group_ids.columns().len);
    try testing.expectEqual(Extra.group_ids, Extra.fromName("group_ids").?);
    try testing.expectEqual(@as(?usize, 8), Extra.group_ids.columnIndex("total"));
    try testing.expectEqual(@as(usize, 14), Section.all.len);
}

test "change values are text as ORCID writes them" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("02", (try cellText(a, "pub_month", .{ .integer = 2 })).?);
    try testing.expectEqualStrings("31", (try cellText(a, "start_day", .{ .integer = 31 })).?);
    try testing.expectEqualStrings("0987", (try cellText(a, "end_year", .{ .integer = 987 })).?);
    try testing.expectEqualStrings("7", (try cellText(a, "put_code", .{ .integer = 7 })).?);
    try testing.expectEqualStrings("true", (try cellText(a, "claimed", .{ .boolean = true })).?);
    try testing.expect((try cellText(a, "title", .null)) == null);
}

test "repeated keys pair up in order" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const r0 = [_]Cell{ .{ .varchar = "keyword" }, .{ .integer = 1 } };
    const r2 = [_]Cell{ .null, .null };
    const section_rows = [_]Row{ &r0, &r0, &r2 };
    const k = try keyRows(a, testing.allocator, &section_rows, 0, 1);
    try testing.expectEqualStrings("keyword\x1f1\x1f0", k[0].key);
    try testing.expectEqualStrings("keyword\x1f1\x1f1", k[1].key);
    try testing.expectEqualStrings("\x1f\x1e\x1f0", k[2].key);
    try testing.expect(k[2].put_code == null);
}

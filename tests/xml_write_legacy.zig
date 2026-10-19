//! The XML writer yorc-zig had before the one-pass writer in
//! src/xml_write.zig: the document is generated twice, once to collect the
//! namespaces in use and once to write, with `std.fmt` for numbers and a
//! check of each value before a byte-at-a-time escape. Kept unchanged (bar
//! its imports, its payload writers and its unit tests) as the oracle of the
//! differential tests in xml_write_test.zig: on any model, `yorc.xml`
//! must write the same bytes, or fail with the same error, `Diagnostic`
//! path, message and code point.
const std = @import("std");
const yorc = @import("yorc");
const model = yorc.model;
const utf8 = yorc.utf8;
const Diagnostic = yorc.Diagnostic;

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
};

// ================================================================= emitter

const max_depth = 64;

const Emitter = struct {
    /// null: collecting namespaces only.
    w: ?*Writer,
    used: [Ns.count]bool = @splat(false),
    /// Namespaces to declare on the root (write pass).
    declare: ?*const [Ns.count]bool = null,
    stack: [max_depth][]const u8 = undefined,
    stack_ns: [max_depth]Ns = undefined,
    depth: usize = 0,
    /// The innermost start tag is open (`>` not written yet).
    pending: bool = false,
    diag: ?*Diagnostic,

    fn writing(e: *const Emitter) bool {
        return e.w != null;
    }

    fn mark(e: *Emitter, ns: Ns) void {
        e.used[@backingInt(ns)] = true;
    }

    fn unwritable(e: *Emitter, extra: ?[]const u8, reason: []const u8, cp: ?u21) WriteError {
        if (e.diag) |d| {
            d.path_len = 0;
            for (e.stack[0..e.depth]) |name| d.pushPath(name);
            if (extra) |x| d.pushPath(x);
            d.message = reason;
            d.code_point = cp;
        }
        return error.Unwritable;
    }

    fn check(e: *Emitter, s: []const u8, extra: ?[]const u8) WriteError!void {
        if (utf8.firstNonXmlChar(s)) |cp| {
            return e.unwritable(extra, if (cp == 0xFFFD and !utf8.isValid(s)) "not valid UTF-8" else "character not allowed in XML 1.0", cp);
        }
    }

    fn indent(w: *Writer, depth: usize) WriteError!void {
        try w.splatByteAll(' ', depth * 2);
    }

    fn qname(w: *Writer, ns: Ns, name: []const u8) WriteError!void {
        try w.writeAll(ns.prefix());
        try w.writeByte(':');
        try w.writeAll(name);
    }

    /// Closes the parent's start tag before a child.
    fn closePending(e: *Emitter) WriteError!void {
        if (e.pending) {
            try e.w.?.writeAll(">\n");
            e.pending = false;
        }
    }

    fn begin(e: *Emitter, ns: Ns, name: []const u8) WriteError!void {
        e.mark(ns);
        if (e.depth >= max_depth) return e.unwritable(name, "nesting too deep", null);
        if (e.w) |w| {
            try e.closePending();
            try indent(w, e.depth);
            try w.writeByte('<');
            try qname(w, ns, name);
            if (e.depth == 0) {
                if (e.declare) |decl| {
                    for (decl, 0..) |on, i| {
                        if (!on) continue;
                        const n: Ns = @fromBackingInt(@intCast(i));
                        try w.writeAll(" xmlns:");
                        try w.writeAll(n.prefix());
                        try w.writeAll("=\"" ++ Ns.uri_base);
                        try w.writeAll(n.prefix());
                        try w.writeByte('"');
                    }
                }
            }
            e.pending = true;
        }
        e.stack[e.depth] = name;
        e.stack_ns[e.depth] = ns;
        e.depth += 1;
    }

    fn attr(e: *Emitter, name: []const u8, value: ?[]const u8) WriteError!void {
        const v = value orelse return;
        const w = e.w orelse return;
        var buf: [64]u8 = undefined;
        const at = std.fmt.bufPrint(&buf, "@{s}", .{name}) catch name;
        try e.check(v, at);
        try w.writeByte(' ');
        try w.writeAll(name);
        try w.writeAll("=\"");
        try escapeAttr(w, v);
        try w.writeByte('"');
    }

    /// Ends the innermost element; `body` is its text (written only if it
    /// has no children).
    fn endWith(e: *Emitter, body: ?[]const u8) WriteError!void {
        e.depth -= 1;
        const ns = e.stack_ns[e.depth];
        const name = e.stack[e.depth];
        const w = e.w orelse return;
        if (e.pending) {
            e.pending = false;
            if (body) |t| {
                e.depth += 1; // for the error path
                try e.check(t, null);
                e.depth -= 1;
                try w.writeByte('>');
                try escapeText(w, t);
                try w.writeAll("</");
                try qname(w, ns, name);
                try w.writeAll(">\n");
            } else {
                try w.writeAll("/>\n");
            }
            return;
        }
        try indent(w, e.depth);
        try w.writeAll("</");
        try qname(w, ns, name);
        try w.writeAll(">\n");
    }

    fn end(e: *Emitter) WriteError!void {
        return e.endWith(null);
    }

    /// `<ns:name>text</ns:name>` if `value` is present.
    fn leaf(e: *Emitter, ns: Ns, name: []const u8, value: ?[]const u8) WriteError!void {
        const v = value orelse return;
        try e.begin(ns, name);
        try e.endWith(v);
    }

    fn leafInt(e: *Emitter, ns: Ns, name: []const u8, value: ?i64) WriteError!void {
        const v = value orelse return;
        var buf: [24]u8 = undefined;
        try e.leaf(ns, name, std.fmt.bufPrint(&buf, "{d}", .{v}) catch unreachable);
    }

    fn leafBool(e: *Emitter, ns: Ns, name: []const u8, value: ?bool) WriteError!void {
        const v = value orelse return;
        try e.leaf(ns, name, if (v) "true" else "false");
    }

    fn leafVocab(e: *Emitter, ns: Ns, name: []const u8, value: anytype) WriteError!void {
        const v = value orelse return;
        try e.leaf(ns, name, v.text());
    }
};

fn escapeText(w: *Writer, s: []const u8) WriteError!void {
    var start: usize = 0;
    for (s, 0..) |c, i| {
        const rep: []const u8 = switch (c) {
            '&' => "&amp;",
            '<' => "&lt;",
            '>' => "&gt;",
            '\r' => "&#13;",
            else => continue,
        };
        try w.writeAll(s[start..i]);
        try w.writeAll(rep);
        start = i + 1;
    }
    try w.writeAll(s[start..]);
}

fn escapeAttr(w: *Writer, s: []const u8) WriteError!void {
    var start: usize = 0;
    for (s, 0..) |c, i| {
        const rep: []const u8 = switch (c) {
            '&' => "&amp;",
            '<' => "&lt;",
            '>' => "&gt;",
            '"' => "&quot;",
            '\t' => "&#9;",
            '\n' => "&#10;",
            '\r' => "&#13;",
            else => continue,
        };
        try w.writeAll(s[start..i]);
        try w.writeAll(rep);
        start = i + 1;
    }
    try w.writeAll(s[start..]);
}

/// Rust `format!("{:0width$}", v)`: zero padding after the sign.
pub fn padInt(buf: []u8, v: i64, width: usize) []const u8 {
    var digits: [24]u8 = undefined;
    const mag = std.fmt.bufPrint(&digits, "{d}", .{@abs(v)}) catch unreachable;
    var n: usize = 0;
    if (v < 0) {
        buf[0] = '-';
        n = 1;
    }
    while (n + mag.len < width) : (n += 1) buf[n] = '0';
    @memcpy(buf[n..][0..mag.len], mag);
    return buf[0 .. n + mag.len];
}

// ================================================================== common

const E = Emitter;

fn metaAttrs(e: *E, m: *const model.ItemMeta) WriteError!void {
    var b: [24]u8 = undefined;
    try e.attr("put-code", if (m.put_code) |v| (std.fmt.bufPrint(&b, "{d}", .{v}) catch unreachable) else null);
    try e.attr("path", m.path);
    try e.attr("visibility", if (m.visibility) |v| v.text() else null);
    var b2: [16]u8 = undefined;
    const di: ?[]const u8 = if (m.display_index_text) |t|
        t
    else if (m.display_index) |v|
        (std.fmt.bufPrint(&b2, "{d}", .{v}) catch unreachable)
    else
        null;
    try e.attr("display-index", di);
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
    var buf: [32]u8 = undefined;
    if (v.year) |y| try e.leaf(.common, "year", padInt(&buf, y, 4));
    if (v.month) |m| try e.leaf(.common, "month", padInt(&buf, m, 2));
    if (v.day) |day| try e.leaf(.common, "day", padInt(&buf, day, 2));
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
        try e.attr("transient", if (t.transient) |b| (if (b) "true" else "false") else null);
        try e.endWith(t.value);
    }
    if (x.normalized_error) |*er| {
        try e.begin(.common, "external-id-normalized-error");
        try e.attr("transient", if (er.transient) |b| (if (b) "true" else "false") else null);
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
            if (a.sequence != null) {
                e.mark(ns);
                if (e.writing()) return e.unwritable("contributor-sequence", "a funding contributor has no contributor-sequence (funding-3.0.xsd)", null);
            }
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
    try e.attr("verified", if (x.verified) |b| (if (b) "true" else "false") else null);
    try e.attr("primary", if (x.primary) |b| (if (b) "true" else "false") else null);
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
    var buf: [24]u8 = undefined;
    try e.attr("num-found", if (s.num_found) |v| (std.fmt.bufPrint(&buf, "{d}", .{v}) catch unreachable) else null);
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
    var buf: [24]u8 = undefined;
    try e.attr("num-found", if (s.num_found) |v| (std.fmt.bufPrint(&buf, "{d}", .{v}) catch unreachable) else null);
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
        // added after this writer was replaced; xml_write.zig writes them
        .group_id_record, .group_id_records => {
            if (e.diag) |d| {
                d.setPath(root.kind().?);
                d.message = "not written by the legacy writer";
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

/// A generator of one document's elements.
fn Generator(comptime Ctx: type, comptime gen: fn (*E, Ctx) WriteError!void) type {
    return struct {
        fn run(w: *Writer, ctx: Ctx, diag: ?*Diagnostic) WriteError!void {
            var collect: E = .{ .w = null, .diag = null };
            gen(&collect, ctx) catch |err| switch (err) {
                // the collecting pass writes nothing and checks nothing
                error.WriteFailed => unreachable,
                error.Unwritable => {
                    // only `.unknown` roots fail here; rerun to fill diag
                    var again: E = .{ .w = null, .diag = diag };
                    return gen(&again, ctx);
                },
            };
            var out: E = .{ .w = w, .diag = diag, .declare = &collect.used };
            try w.writeAll("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n");
            try gen(&out, ctx);
        }
    };
}

/// Writes any document root as ORCID v3.0 XML, exactly as the model holds it
/// (no validation; this is what the round-trip tests use).
pub fn write(w: *Writer, root: *const model.Root, diag: ?*Diagnostic) WriteError!void {
    return Generator(*const model.Root, rootNode).run(w, root, diag);
}

/// `write` into a new allocated buffer (caller frees).
pub fn toOwned(gpa: std.mem.Allocator, root: *const model.Root, diag: ?*Diagnostic) (WriteError || error{OutOfMemory})![]u8 {
    var aw: Writer.Allocating = .init(gpa);
    defer aw.deinit();
    write(&aw.writer, root, diag) catch |err| switch (err) {
        // Allocating reports allocation failure as WriteFailed
        error.WriteFailed => return error.OutOfMemory,
        error.Unwritable => return error.Unwritable,
    };
    return aw.toOwnedSlice();
}

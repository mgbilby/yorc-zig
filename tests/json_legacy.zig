//! The JSON reader yorc-zig had before the streaming one in src/json.zig:
//! std.json parses into a `std.json.Value` tree, and the read view `R` maps
//! that tree onto the model. Kept unchanged (bar its imports) as the oracle
//! of the differential tests in json_test.zig and fuzz_test.zig: on any
//! input, `yorc.json.parse` must give the same document, or the same error
//! and `Diagnostic.message`.
const std = @import("std");
const yorc = @import("yorc");
const model = yorc.model;
const utf8 = yorc.utf8;
const Diagnostic = yorc.Diagnostic;
const millisToDatetime = yorc.json.millisToDatetime;
const support = @import("support.zig");

const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const OOM = error{OutOfMemory};
const Text = model.Text;
const testing_gpa = std.testing.allocator;

/// The integer and boolean rules of src/xml_read.zig (not exported).
const xml_read = struct {
    fn parseInteger(s: []const u8, max_digits: usize) ?i64 {
        if (s.len == 0 or s.len > max_digits) return null;
        var v: i64 = 0;
        for (s) |c| {
            if (c < '0' or c > '9') return null;
            v = v * 10 + (c - '0');
        }
        return v;
    }

    fn parseBool(s: []const u8) ?bool {
        if (std.mem.eql(u8, s, "true") or std.mem.eql(u8, s, "1")) return true;
        if (std.mem.eql(u8, s, "false") or std.mem.eql(u8, s, "0")) return false;
        return null;
    }

    fn parseSigned(s: []const u8) ?i64 {
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
};

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
    var tmp: std.heap.ArenaAllocator = .init(gpa);
    defer tmp.deinit();
    const value = std.json.parseFromSliceLeaky(Value, tmp.allocator(), bytes, .{
        .duplicate_field_behavior = .use_last,
        .parse_numbers = false,
    }) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        if (diag) |d| d.message = @errorName(err);
        return error.MalformedJson;
    };
    return fromValue(gpa, kind, &value, diag);
}

/// Maps a parsed `std.json.Value` of the given kind onto the model.
pub fn fromValue(gpa: Allocator, kind: []const u8, value: *const Value, diag: ?*Diagnostic) ParseError!model.Document {
    if (value.* != .object) {
        if (diag) |d| d.message = "a document must be a JSON object";
        return error.MalformedJson;
    }
    const arena = try gpa.create(std.heap.ArenaAllocator);
    errdefer gpa.destroy(arena);
    arena.* = .init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();
    const r = R.of(value);
    const root = (try rootOf(a, kind, r, value)) orelse {
        if (diag) |d| d.message = "unknown document kind";
        return error.UnknownKind;
    };
    const root_path = switch (root) {
        .record => |x| x.path,
        else => try r.text(a, "path"),
    };
    return .{ .arena = arena, .root_name = try a.dupe(u8, kind), .root_path = root_path, .root = root };
}

/// The text of a JSON number as serde_json prints it: integers that fit
/// i64/u64 in decimal; anything else as written.
fn numberText(a: Allocator, raw: []const u8) OOM!Text {
    if (std.json.isNumberFormattedLikeAnInteger(raw)) {
        if (std.fmt.parseInt(i64, raw, 10)) |v| return std.fmt.allocPrint(a, "{d}", .{v}) else |_| {}
    }
    return a.dupe(u8, raw);
}

/// A JSON scalar (or `{"value": scalar}`) as owned text; strings trimmed,
/// empty → null.
fn scalarText(a: Allocator, v: *const Value) OOM!?Text {
    switch (v.*) {
        .string => |s| {
            const t = model.trimXmlSpace(s);
            return if (t.len == 0) null else try a.dupe(u8, t);
        },
        .number_string => |s| return try numberText(a, s),
        .integer => |i| return try std.fmt.allocPrint(a, "{d}", .{i}),
        .float => |f| return try std.fmt.allocPrint(a, "{d}", .{f}),
        .bool => |b| return if (b) "true" else "false",
        .object => |*o| return if (o.getPtr("value")) |inner| try scalarText(a, inner) else null,
        else => return null,
    }
}

/// An integer-formatted JSON number that fits i64 (serde's `as_i64`).
fn numberAsI64(v: *const Value) ?i64 {
    return switch (v.*) {
        .number_string => |s| if (std.json.isNumberFormattedLikeAnInteger(s)) (std.fmt.parseInt(i64, s, 10) catch null) else null,
        .integer => |i| i,
        else => null,
    };
}

/// Read view of one JSON object (absent, `null` and non-objects read as empty).
const R = struct {
    obj: ?*const std.json.ObjectMap,

    fn of(v: ?*const Value) R {
        if (v) |x| switch (x.*) {
            .object => |*o| return .{ .obj = o },
            else => {},
        };
        return .{ .obj = null };
    }

    fn get(r: R, k: []const u8) ?*const Value {
        const o = r.obj orelse return null;
        const v = o.getPtr(k) orelse return null;
        return if (v.* == .null) null else v;
    }

    fn has(r: R, k: []const u8) bool {
        const v = r.get(k) orelse return false;
        return v.* == .object;
    }

    fn sub(r: R, k: []const u8) R {
        return of(r.get(k));
    }

    fn text(r: R, a: Allocator, k: []const u8) OOM!?Text {
        const v = r.get(k) orelse return null;
        return scalarText(a, v);
    }

    fn time(r: R, a: Allocator, k: []const u8) OOM!?Text {
        const v = r.get(k) orelse return null;
        const inner: *const Value = switch (v.*) {
            .object => |*o| o.getPtr("value") orelse return null,
            else => v,
        };
        switch (inner.*) {
            .number_string, .integer, .float => {
                const ms = numberAsI64(inner) orelse return null;
                var buf: [40]u8 = undefined;
                return try a.dupe(u8, millisToDatetime(&buf, ms));
            },
            else => return scalarText(a, inner),
        }
    }

    fn digits(r: R, a: Allocator, k: []const u8, max: usize) OOM!?i64 {
        const t = (try r.text(a, k)) orelse return null;
        return xml_read.parseInteger(t, max);
    }

    fn i32Digits(r: R, a: Allocator, k: []const u8) OOM!?i32 {
        const v = (try r.digits(a, k, 9)) orelse return null;
        return std.math.cast(i32, v);
    }

    fn i64Signed(r: R, a: Allocator, k: []const u8) OOM!?i64 {
        const t = (try r.text(a, k)) orelse return null;
        return xml_read.parseSigned(t);
    }

    fn boolean(r: R, a: Allocator, k: []const u8) OOM!?bool {
        const v = r.get(k) orelse return null;
        if (v.* == .bool) return v.bool;
        const t = (try scalarText(a, v)) orelse return null;
        return xml_read.parseBool(t);
    }

    fn vocab(r: R, comptime V: type, a: Allocator, k: []const u8) OOM!?V {
        const t = (try r.text(a, k)) orelse return null;
        return V.parse(t);
    }

    /// The objects of an array (a single object counts as a one-element array).
    fn list(r: R, a: Allocator, k: []const u8) OOM![]const R {
        const v = r.get(k) orelse return &.{};
        switch (v.*) {
            .array => |arr| {
                var out: std.ArrayList(R) = .empty;
                for (arr.items) |*x| {
                    if (x.* == .object) try out.append(a, of(x));
                }
                return out.items;
            },
            .object => {
                const one = try a.alloc(R, 1);
                one[0] = of(v);
                return one;
            },
            else => return &.{},
        }
    }

    fn strings(r: R, a: Allocator, k: []const u8) OOM![]const Text {
        const v = r.get(k) orelse return &.{};
        var out: std.ArrayList(Text) = .empty;
        switch (v.*) {
            .array => |arr| for (arr.items) |*x| {
                if (try scalarText(a, x)) |t| try out.append(a, t);
            },
            else => if (try scalarText(a, v)) |t| try out.append(a, t),
        }
        return out.items;
    }
};

fn rMeta(a: Allocator, r: R) OOM!model.ItemMeta {
    const di = try r.text(a, "display-index");
    const display_index: ?i32 = if (di) |t| (if (xml_read.parseInteger(t, 9)) |v| std.math.cast(i32, v) else null) else null;
    var di_text: ?Text = null;
    if (di) |t| {
        var buf: [16]u8 = undefined;
        const same = if (display_index) |v| std.mem.eql(u8, std.fmt.bufPrint(&buf, "{d}", .{v}) catch "", t) else false;
        if (!same) di_text = t;
    }
    return .{
        .put_code = try r.digits(a, "put-code", 18),
        .visibility = try r.vocab(model.Visibility, a, "visibility"),
        .display_index = display_index,
        .display_index_text = di_text,
        .path = try r.text(a, "path"),
        .created_date = try r.time(a, "created-date"),
        .last_modified_date = try r.time(a, "last-modified-date"),
        .source = if (r.has("source")) try rSource(a, r.sub("source")) else null,
    };
}

fn rIdent(a: Allocator, r: R) OOM!model.OrcidIdentifier {
    return .{ .uri = try r.text(a, "uri"), .path = try r.text(a, "path"), .host = try r.text(a, "host") };
}

fn optIdent(a: Allocator, r: R, k: []const u8) OOM!?model.OrcidIdentifier {
    return if (r.has(k)) try rIdent(a, r.sub(k)) else null;
}

fn rSource(a: Allocator, r: R) OOM!model.Source {
    return .{
        .source_orcid = try optIdent(a, r, "source-orcid"),
        .source_client_id = try optIdent(a, r, "source-client-id"),
        .source_name = try r.text(a, "source-name"),
        .assertion_origin_orcid = try optIdent(a, r, "assertion-origin-orcid"),
        .assertion_origin_client_id = try optIdent(a, r, "assertion-origin-client-id"),
        .assertion_origin_name = try r.text(a, "assertion-origin-name"),
    };
}

fn rDate(a: Allocator, r: R, k: []const u8) OOM!?model.FuzzyDate {
    if (!r.has(k)) return null;
    const d = r.sub(k);
    return .{ .year = try d.i32Digits(a, "year"), .month = try d.i32Digits(a, "month"), .day = try d.i32Digits(a, "day") };
}

fn rOrg(a: Allocator, r: R) OOM!model.Organization {
    var o: model.Organization = .{ .name = try r.text(a, "name") };
    if (r.has("address")) {
        const ad = r.sub("address");
        o.address = .{ .city = try ad.text(a, "city"), .region = try ad.text(a, "region"), .country = try ad.text(a, "country") };
    }
    if (r.has("disambiguated-organization")) {
        const d = r.sub("disambiguated-organization");
        o.disambiguated_organization = .{
            .identifier = try d.text(a, "disambiguated-organization-identifier"),
            .source = try d.text(a, "disambiguation-source"),
        };
    }
    return o;
}

fn optOrg(a: Allocator, r: R, k: []const u8) OOM!?model.Organization {
    return if (r.has(k)) try rOrg(a, r.sub(k)) else null;
}

fn rExtId(a: Allocator, r: R) OOM!model.ExternalId {
    var x: model.ExternalId = .{
        .meta = try rMeta(a, r),
        .id_type = try r.text(a, "external-id-type"),
        .value = try r.text(a, "external-id-value"),
        .url = try r.text(a, "external-id-url"),
        .relationship = try r.vocab(model.Relationship, a, "external-id-relationship"),
    };
    if (r.get("external-id-normalized")) |v| {
        x.normalized = .{ .value = try scalarText(a, v), .transient = try R.of(v).boolean(a, "transient") };
    }
    if (r.has("external-id-normalized-error")) {
        const e = r.sub("external-id-normalized-error");
        x.normalized_error = .{
            .error_code = try e.text(a, "error-code"),
            .error_message = try e.text(a, "error-message"),
            .transient = try e.boolean(a, "transient"),
        };
    }
    return x;
}

/// `{"external-id": [...]}` under key `k`.
fn rExtIds(a: Allocator, r: R, k: []const u8) OOM![]const model.ExternalId {
    const items = try r.sub(k).list(a, "external-id");
    const out = try a.alloc(model.ExternalId, items.len);
    for (items, out) |x, *o| o.* = try rExtId(a, x);
    return out;
}

fn rTitle(a: Allocator, r: R, k: []const u8) OOM!?model.Title {
    if (!r.has(k)) return null;
    const t = r.sub(k);
    var out: model.Title = .{ .title = try t.text(a, "title"), .subtitle = try t.text(a, "subtitle") };
    if (t.get("translated-title")) |v| {
        out.translated_title = .{ .value = try scalarText(a, v), .language_code = try R.of(v).text(a, "language-code") };
    }
    return out;
}

fn rContributors(a: Allocator, r: R) OOM![]const model.Contributor {
    const items = try r.sub("contributors").list(a, "contributor");
    const out = try a.alloc(model.Contributor, items.len);
    for (items, out) |c, *o| {
        o.* = .{
            .contributor_orcid = try optIdent(a, c, "contributor-orcid"),
            .credit_name = try c.text(a, "credit-name"),
            .contributor_email = try c.text(a, "contributor-email"),
        };
        if (c.has("contributor-attributes")) {
            const at = c.sub("contributor-attributes");
            o.attributes = .{
                .sequence = try at.vocab(model.ContributorSequence, a, "contributor-sequence"),
                .role = try at.vocab(model.ContributorRole, a, "contributor-role"),
            };
        }
    }
    return out;
}

fn rWork(a: Allocator, r: R) OOM!model.Work {
    var w: model.Work = .{
        .meta = try rMeta(a, r),
        .title = try rTitle(a, r, "title"),
        .journal_title = try r.text(a, "journal-title"),
        .short_description = try r.text(a, "short-description"),
        .work_type = try r.vocab(model.WorkType, a, "type"),
        .publication_date = try rDate(a, r, "publication-date"),
        .external_ids = try rExtIds(a, r, "external-ids"),
        .url = try r.text(a, "url"),
        .contributors = try rContributors(a, r),
        .language_code = try r.text(a, "language-code"),
    };
    if (r.has("citation")) {
        const c = r.sub("citation");
        w.citation = .{
            .citation_type = try c.vocab(model.CitationType, a, "citation-type"),
            .citation_value = try c.text(a, "citation-value"),
        };
    }
    if (r.get("country")) |v| {
        w.country = .{ .value = try scalarText(a, v), .visibility = try R.of(v).vocab(model.Visibility, a, "visibility") };
    }
    return w;
}

fn rWorkSummary(a: Allocator, r: R) OOM!model.WorkSummary {
    return .{
        .meta = try rMeta(a, r),
        .title = try rTitle(a, r, "title"),
        .external_ids = try rExtIds(a, r, "external-ids"),
        .url = try r.text(a, "url"),
        .work_type = try r.vocab(model.WorkType, a, "type"),
        .publication_date = try rDate(a, r, "publication-date"),
        .journal_title = try r.text(a, "journal-title"),
    };
}

fn mapList(comptime T: type, a: Allocator, items: []const R, comptime f: fn (Allocator, R) OOM!T) OOM![]const T {
    const out = try a.alloc(T, items.len);
    for (items, out) |x, *o| o.* = try f(a, x);
    return out;
}

fn rWorkGroup(a: Allocator, g: R) OOM!model.WorkGroup {
    return .{
        .last_modified_date = try g.time(a, "last-modified-date"),
        .external_ids = try rExtIds(a, g, "external-ids"),
        .work_summaries = try mapList(model.WorkSummary, a, try g.list(a, "work-summary"), rWorkSummary),
    };
}

fn rWorks(a: Allocator, r: R) OOM!model.Works {
    return .{
        .path = try r.text(a, "path"),
        .last_modified_date = try r.time(a, "last-modified-date"),
        .groups = try mapList(model.WorkGroup, a, try r.list(a, "group"), rWorkGroup),
    };
}

fn rAmount(a: Allocator, r: R) OOM!?model.Amount {
    const v = r.get("amount") orelse return null;
    return .{ .value = try scalarText(a, v), .currency_code = try R.of(v).text(a, "currency-code") };
}

fn rFunding(a: Allocator, r: R) OOM!model.Funding {
    return .{
        .meta = try rMeta(a, r),
        .funding_type = try r.vocab(model.FundingType, a, "type"),
        .organization_defined_type = try r.text(a, "organization-defined-type"),
        .title = try rTitle(a, r, "title"),
        .short_description = try r.text(a, "short-description"),
        .amount = try rAmount(a, r),
        .url = try r.text(a, "url"),
        .start_date = try rDate(a, r, "start-date"),
        .end_date = try rDate(a, r, "end-date"),
        .external_ids = try rExtIds(a, r, "external-ids"),
        .contributors = try rContributors(a, r),
        .organization = try optOrg(a, r, "organization"),
    };
}

fn rFundingSummary(a: Allocator, r: R) OOM!model.FundingSummary {
    return .{
        .meta = try rMeta(a, r),
        .title = try rTitle(a, r, "title"),
        .external_ids = try rExtIds(a, r, "external-ids"),
        .url = try r.text(a, "url"),
        .funding_type = try r.vocab(model.FundingType, a, "type"),
        .start_date = try rDate(a, r, "start-date"),
        .end_date = try rDate(a, r, "end-date"),
        .organization = try optOrg(a, r, "organization"),
    };
}

fn rFundingGroup(a: Allocator, g: R) OOM!model.FundingGroup {
    return .{
        .last_modified_date = try g.time(a, "last-modified-date"),
        .external_ids = try rExtIds(a, g, "external-ids"),
        .funding_summaries = try mapList(model.FundingSummary, a, try g.list(a, "funding-summary"), rFundingSummary),
    };
}

fn rFundings(a: Allocator, r: R) OOM!model.Fundings {
    return .{
        .path = try r.text(a, "path"),
        .last_modified_date = try r.time(a, "last-modified-date"),
        .groups = try mapList(model.FundingGroup, a, try r.list(a, "group"), rFundingGroup),
    };
}

fn rAffiliation(a: Allocator, kind: model.AffiliationKind, r: R) OOM!model.Affiliation {
    return .{
        .kind = kind,
        .meta = try rMeta(a, r),
        .department_name = try r.text(a, "department-name"),
        .role_title = try r.text(a, "role-title"),
        .start_date = try rDate(a, r, "start-date"),
        .end_date = try rDate(a, r, "end-date"),
        .organization = try optOrg(a, r, "organization"),
        .url = try r.text(a, "url"),
        .external_ids = try rExtIds(a, r, "external-ids"),
    };
}

fn rAffiliations(a: Allocator, kind: model.AffiliationKind, r: R) OOM!model.Affiliations {
    const groups = try r.list(a, "affiliation-group");
    const out = try a.alloc(model.AffiliationGroup, groups.len);
    for (groups, out) |g, *o| {
        var summaries: std.ArrayList(model.Affiliation) = .empty;
        for (try g.list(a, "summaries")) |wrapper| {
            for (model.AffiliationKind.all) |k| {
                for (try wrapper.list(a, k.summaryElement())) |s| try summaries.append(a, try rAffiliation(a, k, s));
            }
        }
        o.* = .{
            .last_modified_date = try g.time(a, "last-modified-date"),
            .external_ids = try rExtIds(a, g, "external-ids"),
            .summaries = summaries.items,
        };
    }
    return .{
        .kind = kind,
        .path = try r.text(a, "path"),
        .last_modified_date = try r.time(a, "last-modified-date"),
        .groups = out,
    };
}

fn rPeerReviewSummary(a: Allocator, r: R) OOM!model.PeerReviewSummary {
    return .{
        .meta = try rMeta(a, r),
        .reviewer_role = try r.vocab(model.PeerReviewRole, a, "reviewer-role"),
        .external_ids = try rExtIds(a, r, "external-ids"),
        .review_url = try r.text(a, "review-url"),
        .review_type = try r.vocab(model.PeerReviewType, a, "review-type"),
        .completion_date = try rDate(a, r, "completion-date"),
        .review_group_id = try r.text(a, "review-group-id"),
        .convening_organization = try optOrg(a, r, "convening-organization"),
    };
}

fn rPeerReview(a: Allocator, r: R) OOM!model.PeerReview {
    return .{
        .meta = try rMeta(a, r),
        .reviewer_role = try r.vocab(model.PeerReviewRole, a, "reviewer-role"),
        .review_identifiers = try rExtIds(a, r, "review-identifiers"),
        .review_url = try r.text(a, "review-url"),
        .review_type = try r.vocab(model.PeerReviewType, a, "review-type"),
        .review_completion_date = try rDate(a, r, "review-completion-date"),
        .review_group_id = try r.text(a, "review-group-id"),
        .subject_external_identifier = if (r.has("subject-external-identifier")) try rExtId(a, r.sub("subject-external-identifier")) else null,
        .subject_container_name = try r.text(a, "subject-container-name"),
        .subject_type = try r.text(a, "subject-type"),
        .subject_name = try rTitle(a, r, "subject-name"),
        .subject_url = try r.text(a, "subject-url"),
        .convening_organization = try optOrg(a, r, "convening-organization"),
    };
}

fn rPeerReviewDuplicates(a: Allocator, d: R) OOM!model.PeerReviewDuplicates {
    return .{
        .last_modified_date = try d.time(a, "last-modified-date"),
        .external_ids = try rExtIds(a, d, "external-ids"),
        .summaries = try mapList(model.PeerReviewSummary, a, try d.list(a, "peer-review-summary"), rPeerReviewSummary),
    };
}

fn rPeerReviewGroup(a: Allocator, g: R) OOM!model.PeerReviewGroup {
    return .{
        .last_modified_date = try g.time(a, "last-modified-date"),
        .external_ids = try rExtIds(a, g, "external-ids"),
        .duplicates = try mapList(model.PeerReviewDuplicates, a, try g.list(a, "peer-review-group"), rPeerReviewDuplicates),
    };
}

fn rPeerReviews(a: Allocator, r: R) OOM!model.PeerReviews {
    return .{
        .path = try r.text(a, "path"),
        .last_modified_date = try r.time(a, "last-modified-date"),
        .groups = try mapList(model.PeerReviewGroup, a, try r.list(a, "group"), rPeerReviewGroup),
    };
}

fn rHosts(a: Allocator, r: R) OOM![]const model.Organization {
    return mapList(model.Organization, a, try r.sub("hosts").list(a, "organization"), rOrg);
}

fn rProposal(a: Allocator, r: R) OOM!?model.Proposal {
    if (!r.has("proposal")) return null;
    const p = r.sub("proposal");
    return .{
        .title = try rTitle(a, p, "title"),
        .hosts = try rHosts(a, p),
        .external_ids = try rExtIds(a, p, "external-ids"),
        .start_date = try rDate(a, p, "start-date"),
        .end_date = try rDate(a, p, "end-date"),
        .url = try p.text(a, "url"),
    };
}

fn rResourceItem(a: Allocator, i: R) OOM!model.ResourceItem {
    return .{
        .resource_name = try i.text(a, "resource-name"),
        .resource_type = try i.vocab(model.ResourceType, a, "resource-type"),
        .hosts = try rHosts(a, i),
        .external_ids = try rExtIds(a, i, "external-ids"),
        .url = try i.text(a, "url"),
    };
}

fn rResearchResource(a: Allocator, r: R) OOM!model.ResearchResource {
    // `resource-item` directly (the samples), or wrapped in `resource-items`.
    var items: std.ArrayList(R) = .empty;
    try items.appendSlice(a, try r.list(a, "resource-item"));
    try items.appendSlice(a, try r.sub("resource-items").list(a, "resource-item"));
    return .{
        .meta = try rMeta(a, r),
        .proposal = try rProposal(a, r),
        .resource_items = try mapList(model.ResourceItem, a, items.items, rResourceItem),
    };
}

fn rResearchResourceSummary(a: Allocator, r: R) OOM!model.ResearchResourceSummary {
    return .{ .meta = try rMeta(a, r), .proposal = try rProposal(a, r) };
}

fn rResearchResourceGroup(a: Allocator, g: R) OOM!model.ResearchResourceGroup {
    return .{
        .last_modified_date = try g.time(a, "last-modified-date"),
        .external_ids = try rExtIds(a, g, "external-ids"),
        .summaries = try mapList(model.ResearchResourceSummary, a, try g.list(a, "research-resource-summary"), rResearchResourceSummary),
    };
}

fn rResearchResources(a: Allocator, r: R) OOM!model.ResearchResources {
    return .{
        .path = try r.text(a, "path"),
        .last_modified_date = try r.time(a, "last-modified-date"),
        .groups = try mapList(model.ResearchResourceGroup, a, try r.list(a, "group"), rResearchResourceGroup),
    };
}

fn rActivities(a: Allocator, r: R) OOM!model.ActivitiesSummary {
    var s: model.ActivitiesSummary = .{
        .path = try r.text(a, "path"),
        .last_modified_date = try r.time(a, "last-modified-date"),
        .fundings = if (r.has("fundings")) try rFundings(a, r.sub("fundings")) else null,
        .peer_reviews = if (r.has("peer-reviews")) try rPeerReviews(a, r.sub("peer-reviews")) else null,
        .research_resources = if (r.has("research-resources")) try rResearchResources(a, r.sub("research-resources")) else null,
        .works = if (r.has("works")) try rWorks(a, r.sub("works")) else null,
    };
    for (model.AffiliationKind.all) |k| {
        const key = k.containerElement();
        if (r.has(key)) s.affiliationsSlot(k).* = try rAffiliations(a, k, r.sub(key));
    }
    return s;
}

fn rName(a: Allocator, r: R) OOM!model.Name {
    return .{
        .visibility = try r.vocab(model.Visibility, a, "visibility"),
        .path = try r.text(a, "path"),
        .created_date = try r.time(a, "created-date"),
        .last_modified_date = try r.time(a, "last-modified-date"),
        .given_names = try r.text(a, "given-names"),
        .family_name = try r.text(a, "family-name"),
        .credit_name = try r.text(a, "credit-name"),
    };
}

fn rBiography(a: Allocator, r: R) OOM!model.Biography {
    return .{
        .visibility = try r.vocab(model.Visibility, a, "visibility"),
        .path = try r.text(a, "path"),
        .created_date = try r.time(a, "created-date"),
        .last_modified_date = try r.time(a, "last-modified-date"),
        .content = try r.text(a, "content"),
    };
}

fn rOtherName(a: Allocator, r: R) OOM!model.OtherName {
    return .{ .meta = try rMeta(a, r), .content = try r.text(a, "content") };
}

fn rResearcherUrl(a: Allocator, r: R) OOM!model.ResearcherUrl {
    return .{ .meta = try rMeta(a, r), .url_name = try r.text(a, "url-name"), .url = try r.text(a, "url") };
}

fn rEmail(a: Allocator, r: R) OOM!model.Email {
    return .{
        .meta = try rMeta(a, r),
        .email = try r.text(a, "email"),
        .verified = try r.boolean(a, "verified"),
        .primary = try r.boolean(a, "primary"),
    };
}

fn rAddress(a: Allocator, r: R) OOM!model.Address {
    return .{ .meta = try rMeta(a, r), .country = try r.text(a, "country") };
}

fn rKeyword(a: Allocator, r: R) OOM!model.Keyword {
    return .{ .meta = try rMeta(a, r), .content = try r.text(a, "content") };
}

fn rList(comptime T: type, a: Allocator, r: R, item: []const u8, comptime f: fn (Allocator, R) OOM!T) OOM!model.ItemList(T) {
    return .{
        .path = try r.text(a, "path"),
        .last_modified_date = try r.time(a, "last-modified-date"),
        .items = try mapList(T, a, try r.list(a, item), f),
    };
}

fn optList(comptime T: type, a: Allocator, r: R, key: []const u8, item: []const u8, comptime f: fn (Allocator, R) OOM!T) OOM!?model.ItemList(T) {
    return if (r.has(key)) try rList(T, a, r.sub(key), item, f) else null;
}

fn rPerson(a: Allocator, r: R) OOM!model.Person {
    return .{
        .path = try r.text(a, "path"),
        .last_modified_date = try r.time(a, "last-modified-date"),
        .name = if (r.has("name")) try rName(a, r.sub("name")) else null,
        .other_names = try optList(model.OtherName, a, r, "other-names", "other-name", rOtherName),
        .biography = if (r.has("biography")) try rBiography(a, r.sub("biography")) else null,
        .researcher_urls = try optList(model.ResearcherUrl, a, r, "researcher-urls", "researcher-url", rResearcherUrl),
        .emails = try optList(model.Email, a, r, "emails", "email", rEmail),
        .addresses = try optList(model.Address, a, r, "addresses", "address", rAddress),
        .keywords = try optList(model.Keyword, a, r, "keywords", "keyword", rKeyword),
        .external_identifiers = try optList(model.ExternalId, a, r, "external-identifiers", "external-identifier", rExtId),
    };
}

fn rPersonalDetails(a: Allocator, r: R) OOM!model.PersonalDetails {
    return .{
        .path = try r.text(a, "path"),
        .last_modified_date = try r.time(a, "last-modified-date"),
        .name = if (r.has("name")) try rName(a, r.sub("name")) else null,
        .other_names = try optList(model.OtherName, a, r, "other-names", "other-name", rOtherName),
        .biography = if (r.has("biography")) try rBiography(a, r.sub("biography")) else null,
    };
}

const java_creation_methods = [_]struct { []const u8, model.CreationMethod.Known }{
    .{ "API", .API },
    .{ "DIRECT", .Direct },
    .{ "MEMBER_REFERRED", .@"Member-referred" },
    .{ "WEBSITE", .website },
};

fn creationMethodFromJson(s: Text) model.CreationMethod {
    for (java_creation_methods) |m| {
        if (std.mem.eql(u8, s, m[0])) return .{ .known = m[1] };
    }
    return model.CreationMethod.parse(s);
}

fn rHistory(a: Allocator, r: R) OOM!model.History {
    return .{
        .visibility = try r.vocab(model.Visibility, a, "visibility"),
        .creation_method = if (try r.text(a, "creation-method")) |t| creationMethodFromJson(t) else null,
        .completion_date = try r.time(a, "completion-date"),
        .submission_date = try r.time(a, "submission-date"),
        .last_modified_date = try r.time(a, "last-modified-date"),
        .claimed = try r.boolean(a, "claimed"),
        .source = if (r.has("source")) try rSource(a, r.sub("source")) else null,
        .deactivation_date = try r.time(a, "deactivation-date"),
        .verified_email = try r.boolean(a, "verified-email"),
        .verified_primary_email = try r.boolean(a, "verified-primary-email"),
    };
}

fn rRecord(a: Allocator, r: R) OOM!model.Record {
    return .{
        .path = try r.text(a, "path"),
        .orcid_identifier = try optIdent(a, r, "orcid-identifier"),
        .preferences = if (r.has("preferences")) .{ .locale = try r.sub("preferences").text(a, "locale") } else null,
        .history = if (r.has("history")) try rHistory(a, r.sub("history")) else null,
        .person = if (r.has("person")) try rPerson(a, r.sub("person")) else null,
        .activities_summary = if (r.has("activities-summary")) try rActivities(a, r.sub("activities-summary")) else null,
    };
}

fn rError(a: Allocator, r: R) OOM!model.OrcidError {
    return .{
        .response_code = try r.i64Signed(a, "response-code"),
        .developer_message = try r.text(a, "developer-message"),
        .user_message = try r.text(a, "user-message"),
        .error_code = try r.i64Signed(a, "error-code"),
        .more_info = try r.text(a, "more-info"),
    };
}

fn rBulk(a: Allocator, r: R) OOM!model.Bulk {
    var items: std.ArrayList(model.BulkItem) = .empty;
    for (try r.list(a, "bulk")) |e| {
        if (e.has("work")) {
            try items.append(a, .{ .work = try rWork(a, e.sub("work")) });
        } else if (e.has("error")) {
            try items.append(a, .{ .@"error" = try rError(a, e.sub("error")) });
        }
    }
    return .{ .items = items.items };
}

fn rSearch(a: Allocator, r: R) OOM!model.Search {
    var results: std.ArrayList(model.OrcidIdentifier) = .empty;
    for (try r.list(a, "result")) |x| {
        if (x.has("orcid-identifier")) try results.append(a, try rIdent(a, x.sub("orcid-identifier")));
    }
    return .{ .num_found = try r.i64Signed(a, "num-found"), .results = results.items };
}

fn rExpandedResult(a: Allocator, x: R) OOM!model.ExpandedResult {
    return .{
        .orcid_id = try x.text(a, "orcid-id"),
        .given_names = try x.text(a, "given-names"),
        .family_names = try x.text(a, "family-names"),
        .credit_name = try x.text(a, "credit-name"),
        .other_names = try x.strings(a, "other-name"),
        .emails = try x.strings(a, "email"),
        .institution_names = try x.strings(a, "institution-name"),
    };
}

fn rExpandedSearch(a: Allocator, r: R) OOM!model.ExpandedSearch {
    return .{
        .num_found = try r.i64Signed(a, "num-found"),
        .results = try mapList(model.ExpandedResult, a, try r.list(a, "expanded-result"), rExpandedResult),
    };
}

/// `group-id-record` (added with the group-id records; the same rules as
/// json.zig's streaming reader and yorc-rs's `r_group_id_record`).
fn rGroupIdRecord(a: Allocator, r: R) OOM!model.GroupIdRecord {
    var source: ?model.Source = if (r.has("source")) try rSource(a, r.sub("source")) else null;
    const inline_orcid = try optIdent(a, r, "source-orcid");
    const inline_client = try optIdent(a, r, "source-client-id");
    const inline_name = try r.text(a, "source-name");
    if (inline_orcid != null or inline_client != null or inline_name != null) {
        if (source == null) source = .{};
        const src = &source.?;
        if (src.source_orcid == null) src.source_orcid = inline_orcid;
        if (src.source_client_id == null) src.source_client_id = inline_client;
        if (src.source_name == null) src.source_name = inline_name;
    }
    return .{
        .put_code = try r.digits(a, "put-code", 18),
        .created_date = try r.time(a, "created-date"),
        .last_modified_date = try r.time(a, "last-modified-date"),
        .name = try r.text(a, "name"),
        .group_id = try r.text(a, "group-id"),
        .description = try r.text(a, "description"),
        .group_type = try r.vocab(model.GroupType, a, "type"),
        .source = source,
    };
}

fn rGroupIdRecords(a: Allocator, r: R) OOM!model.GroupIdRecords {
    return .{
        .last_modified_date = try r.time(a, "last-modified-date"),
        .total = try r.digits(a, "total", 9),
        .page = try r.digits(a, "page", 9),
        .page_size = try r.digits(a, "page-size", 9),
        .records = try mapList(model.GroupIdRecord, a, try r.list(a, "group-id-record"), rGroupIdRecord),
    };
}

fn rootOf(a: Allocator, kind: []const u8, r: R, whole: *const Value) OOM!?model.Root {
    const eq = struct {
        fn f(x: []const u8, y: []const u8) bool {
            return std.mem.eql(u8, x, y);
        }
    }.f;
    if (eq(kind, "record")) return .{ .record = try rRecord(a, r) };
    if (eq(kind, "activities-summary")) return .{ .activities_summary = try rActivities(a, r) };
    if (eq(kind, "works")) return .{ .works = try rWorks(a, r) };
    if (eq(kind, "work")) return .{ .work = try rWork(a, r) };
    if (eq(kind, "work-summary")) return .{ .work_summary = try rWorkSummary(a, r) };
    if (eq(kind, "fundings")) return .{ .fundings = try rFundings(a, r) };
    if (eq(kind, "funding")) return .{ .funding = try rFunding(a, r) };
    if (eq(kind, "funding-summary")) return .{ .funding_summary = try rFundingSummary(a, r) };
    if (eq(kind, "peer-reviews")) return .{ .peer_reviews = try rPeerReviews(a, r) };
    if (eq(kind, "peer-review")) return .{ .peer_review = try rPeerReview(a, r) };
    if (eq(kind, "peer-review-summary")) return .{ .peer_review_summary = try rPeerReviewSummary(a, r) };
    if (eq(kind, "research-resources")) return .{ .research_resources = try rResearchResources(a, r) };
    if (eq(kind, "research-resource")) return .{ .research_resource = try rResearchResource(a, r) };
    if (eq(kind, "research-resource-summary")) return .{ .research_resource_summary = try rResearchResourceSummary(a, r) };
    if (eq(kind, "person")) return .{ .person = try rPerson(a, r) };
    if (eq(kind, "personal-details")) return .{ .personal_details = try rPersonalDetails(a, r) };
    if (eq(kind, "name")) return .{ .name = try rName(a, r) };
    if (eq(kind, "biography")) return .{ .biography = try rBiography(a, r) };
    if (eq(kind, "credit-name")) return .{ .credit_name = try scalarText(a, whole) };
    if (eq(kind, "other-names")) return .{ .other_names = try rList(model.OtherName, a, r, "other-name", rOtherName) };
    if (eq(kind, "other-name")) return .{ .other_name = try rOtherName(a, r) };
    if (eq(kind, "researcher-urls")) return .{ .researcher_urls = try rList(model.ResearcherUrl, a, r, "researcher-url", rResearcherUrl) };
    if (eq(kind, "researcher-url")) return .{ .researcher_url = try rResearcherUrl(a, r) };
    if (eq(kind, "emails")) return .{ .emails = try rList(model.Email, a, r, "email", rEmail) };
    if (eq(kind, "email")) return .{ .email = try rEmail(a, r) };
    if (eq(kind, "addresses")) return .{ .addresses = try rList(model.Address, a, r, "address", rAddress) };
    if (eq(kind, "address")) return .{ .address = try rAddress(a, r) };
    if (eq(kind, "keywords")) return .{ .keywords = try rList(model.Keyword, a, r, "keyword", rKeyword) };
    if (eq(kind, "keyword")) return .{ .keyword = try rKeyword(a, r) };
    if (eq(kind, "external-identifiers")) return .{ .external_identifiers = try rList(model.ExternalId, a, r, "external-identifier", rExtId) };
    if (eq(kind, "external-identifier")) return .{ .external_identifier = try rExtId(a, r) };
    if (eq(kind, "history")) return .{ .history = try rHistory(a, r) };
    if (eq(kind, "preferences")) return .{ .preferences = .{ .locale = try r.text(a, "locale") } };
    if (eq(kind, "bulk")) return .{ .bulk = try rBulk(a, r) };
    if (eq(kind, "error")) return .{ .@"error" = try rError(a, r) };
    if (eq(kind, "search")) return .{ .search = try rSearch(a, r) };
    if (eq(kind, "expanded-search")) return .{ .expanded_search = try rExpandedSearch(a, r) };
    if (eq(kind, "group-id-record")) return .{ .group_id_record = try rGroupIdRecord(a, r) };
    if (eq(kind, "group-id-records")) return .{ .group_id_records = try rGroupIdRecords(a, r) };
    if (model.AffiliationKind.fromContainerElement(kind)) |k| return .{ .affiliations = try rAffiliations(a, k, r) };
    if (model.AffiliationKind.fromElement(kind)) |k| return .{ .affiliation = try rAffiliation(a, k, r) };
    if (model.AffiliationKind.fromSummaryElement(kind)) |k| return .{ .affiliation_summary = try rAffiliation(a, k, r) };
    return null;
}

// ================================================= differential checks

pub fn compareReads(
    got: yorc.json.ParseError!yorc.Document,
    want: ParseError!yorc.Document,
    d_new: *const yorc.Diagnostic,
    d_old: *const yorc.Diagnostic,
    kind: []const u8,
    label: []const u8,
) !void {
    if (want) |want_doc| {
        var w = want_doc;
        defer w.deinit();
        var g = got catch |err| {
            std.debug.print("{s} as {s}: read before, now {s} ({s})\n", .{ label, kind, @errorName(err), d_new.message });
            return error.TestReadDiffers;
        };
        defer g.deinit();
        try support.expectSameDocument(testing_gpa, w, g, label);
    } else |want_err| {
        if (got) |got_doc| {
            var g = got_doc;
            g.deinit();
            std.debug.print("{s} as {s}: {s} before, now read\n", .{ label, kind, @errorName(want_err) });
            return error.TestReadDiffers;
        } else |got_err| {
            const same_error = std.mem.eql(u8, @errorName(want_err), @errorName(got_err));
            const same_diag = std.mem.eql(u8, d_old.message, d_new.message) and d_old.position == d_new.position;
            if (!same_error or !same_diag) {
                std.debug.print("{s} as {s}: {s} \"{s}\" at {d} before\n", .{ label, kind, @errorName(want_err), d_old.message, d_old.position });
                std.debug.print("{s} as {s}: {s} \"{s}\" at {d} now\n", .{ label, kind, @errorName(got_err), d_new.message, d_new.position });
                return error.TestReadDiffers;
            }
        }
    }
}

/// `json.parse` against the old reader.
pub fn expectSameRead(kind: []const u8, input: []const u8, label: []const u8) !void {
    var d_new: yorc.Diagnostic = .{};
    var d_old: yorc.Diagnostic = .{};
    const got = yorc.json.parse(testing_gpa, kind, input, &d_new);
    const want = parse(testing_gpa, kind, input, &d_old);
    try compareReads(got, want, &d_new, &d_old, kind, label);
}

/// `json.fromValue` against the old reader, on `input` parsed by std.json
/// (nothing to compare if it is not JSON).
pub fn expectSameFromValue(kind: []const u8, input: []const u8, parse_numbers: bool, label: []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(testing_gpa);
    defer arena.deinit();
    const v = std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), input, .{
        .parse_numbers = parse_numbers,
        .duplicate_field_behavior = .use_last,
    }) catch return;
    try expectSameValue(kind, &v, label);
}

pub fn expectSameValue(kind: []const u8, v: *const std.json.Value, label: []const u8) !void {
    var d_new: yorc.Diagnostic = .{};
    var d_old: yorc.Diagnostic = .{};
    const got = yorc.json.fromValue(testing_gpa, kind, v, &d_new);
    const want = fromValue(testing_gpa, kind, v, &d_old);
    try compareReads(got, want, &d_new, &d_old, kind, label);
}

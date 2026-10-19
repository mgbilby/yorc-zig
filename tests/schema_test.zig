//! Schema walk: every element and attribute declared by the v3.0 record XSDs
//! and common-3.0.xsd must have a model counterpart. A fully populated model
//! of every root kind is written, and the qualified element names and
//! attribute names it emits are compared with the names the XSDs declare:
//! * declared but never emitted → must be listed in testdata/xsd_uncovered.txt;
//! * listed but emitted → the list is stale: fail;
//! * emitted but not declared → the writer invents names: fail.
//! yorc-rs's tests/schema_coverage.rs.
const std = @import("std");
const yorc = @import("yorc");
const fixtures = @import("fixtures");
const support = @import("support.zig");

const testing = std.testing;
const gpa = testing.allocator;
const model = yorc.model;
const scan = yorc.xml.scan;

const Set = std.StringArrayHashMapUnmanaged(void);

fn attrValue(st: scan.Start, key: []const u8) !?[]const u8 {
    var it = st.attributes();
    while (try it.next()) |at| {
        if (std.mem.eql(u8, at.name, key)) return at.raw_value;
    }
    return null;
}

/// `prefix:name` of every declared element and `@name` of every declared
/// attribute.
fn declared(a: std.mem.Allocator, elements: *Set, attributes: *Set) !void {
    for (fixtures.xsds) |f| {
        var sc: scan.Scanner = .init(f.data);
        var prefix: []const u8 = "";
        while (true) {
            const tok = try sc.next();
            const st = switch (tok) {
                .eof => break,
                .start => |s| s,
                else => continue,
            };
            if (std.mem.eql(u8, st.name, "xs:schema")) {
                const tns = (try attrValue(st, "targetNamespace")) orelse return error.NoTargetNamespace;
                prefix = tns[std.mem.lastIndexOfScalar(u8, tns, '/').? + 1 ..];
            } else if (std.mem.eql(u8, st.name, "xs:element")) {
                if (try attrValue(st, "name")) |n| try elements.put(a, try std.fmt.allocPrint(a, "{s}:{s}", .{ prefix, n }), {});
            } else if (std.mem.eql(u8, st.name, "xs:attribute")) {
                if (try attrValue(st, "name")) |n| try attributes.put(a, try std.fmt.allocPrint(a, "@{s}", .{n}), {});
            }
        }
    }
}

/// Qualified element names and `@attribute` names in a written document.
fn emitted(a: std.mem.Allocator, xml: []const u8, elements: *Set, attributes: *Set) !void {
    var sc: scan.Scanner = .init(xml);
    while (true) {
        switch (try sc.next()) {
            .eof => break,
            .start => |st| {
                try elements.put(a, st.name, {});
                var it = st.attributes();
                while (try it.next()) |at| {
                    if (!std.mem.startsWith(u8, at.name, "xmlns")) try attributes.put(a, try std.fmt.allocPrint(a, "@{s}", .{at.name}), {});
                }
            },
            else => {},
        }
    }
}

fn allowList(a: std.mem.Allocator, out: *Set) !void {
    var lines = std.mem.splitScalar(u8, fixtures.xsd_uncovered, '\n');
    while (lines.next()) |line| {
        const before = if (std.mem.indexOfScalar(u8, line, '#')) |i| line[0..i] else line;
        const entry = std.mem.trim(u8, before, " \t\r");
        if (entry.len > 0) try out.put(a, entry, {});
    }
}

// ------------------------------------------------ a fully populated model

const ts = "2001-12-31T12:00:00";

const ident: model.OrcidIdentifier = .{
    .uri = "https://orcid.org/0000-0002-1825-0097",
    .path = "0000-0002-1825-0097",
    .host = "orcid.org",
};

const source: model.Source = .{
    .source_orcid = ident,
    .source_client_id = ident,
    .source_name = "n",
    .assertion_origin_orcid = ident,
    .assertion_origin_client_id = ident,
    .assertion_origin_name = "n",
};

const meta: model.ItemMeta = .{
    .put_code = 1,
    .visibility = .{ .known = .public },
    .display_index = 1,
    .path = "/0000-0002-1825-0097/x/1",
    .created_date = ts,
    .last_modified_date = ts,
    .source = source,
};

const date: model.FuzzyDate = .{ .year = 2001, .month = 2, .day = 3 };

const org: model.Organization = .{
    .name = "o",
    .address = .{ .city = "c", .region = "r", .country = "US" },
    .disambiguated_organization = .{ .identifier = "1", .source = "ROR" },
};

const ext_id: model.ExternalId = .{
    .meta = meta,
    .id_type = "doi",
    .value = "10.1/x",
    .normalized = .{ .value = "10.1/x", .transient = true },
    .normalized_error = .{ .error_code = "8001", .error_message = "m", .transient = true },
    .url = "https://doi.org/10.1/x",
    .relationship = .{ .known = .self },
};

const ext_ids = [_]model.ExternalId{ext_id};

const title: model.Title = .{
    .title = "t",
    .subtitle = "s",
    .translated_title = .{ .value = "tt", .language_code = "en" },
};

const contributor: model.Contributor = .{
    .contributor_orcid = ident,
    .credit_name = "c",
    .contributor_email = "a@b.c",
    .attributes = .{ .sequence = .{ .known = .first }, .role = .{ .known = .author } },
};

const work: model.Work = .{
    .meta = meta,
    .title = title,
    .journal_title = "j",
    .short_description = "d",
    .citation = .{ .citation_type = .{ .known = .bibtex }, .citation_value = "@x{}" },
    .work_type = .{ .known = .book },
    .publication_date = date,
    .external_ids = &ext_ids,
    .url = "https://x",
    .contributors = &.{contributor},
    .language_code = "en",
    .country = .{ .value = "US", .visibility = .{ .known = .public } },
};

const work_summary: model.WorkSummary = .{
    .meta = meta,
    .title = title,
    .external_ids = &ext_ids,
    .url = "https://x",
    .work_type = .{ .known = .book },
    .publication_date = date,
    .journal_title = "j",
};

const funding: model.Funding = .{
    .meta = meta,
    .funding_type = .{ .known = .grant },
    .organization_defined_type = "t",
    .title = title,
    .short_description = "d",
    .amount = .{ .value = "1", .currency_code = "USD" },
    .url = "https://x",
    .start_date = date,
    .end_date = date,
    .external_ids = &ext_ids,
    // no contributor-sequence: not in funding-3.0.xsd
    .contributors = &.{.{
        .contributor_orcid = ident,
        .credit_name = "c",
        .contributor_email = "a@b.c",
        .attributes = .{ .role = .{ .known = .lead } },
    }},
    .organization = org,
};

const funding_summary: model.FundingSummary = .{
    .meta = meta,
    .title = title,
    .external_ids = &ext_ids,
    .url = "https://x",
    .funding_type = .{ .known = .grant },
    .start_date = date,
    .end_date = date,
    .organization = org,
};

fn affiliation(kind: model.AffiliationKind) model.Affiliation {
    return .{
        .kind = kind,
        .meta = meta,
        .department_name = "d",
        .role_title = "r",
        .start_date = date,
        .end_date = date,
        .organization = org,
        .url = "https://x",
        .external_ids = &ext_ids,
    };
}

fn affiliations(comptime kind: model.AffiliationKind) model.Affiliations {
    const S = struct {
        const summaries = [_]model.Affiliation{affiliation(kind)};
        const groups = [_]model.AffiliationGroup{.{ .last_modified_date = ts, .external_ids = &ext_ids, .summaries = &summaries }};
    };
    return .{ .kind = kind, .path = "/p", .last_modified_date = ts, .groups = &S.groups };
}

const peer_review_summary: model.PeerReviewSummary = .{
    .meta = meta,
    .reviewer_role = .{ .known = .reviewer },
    .external_ids = &ext_ids,
    .review_url = "https://x",
    .review_type = .{ .known = .review },
    .completion_date = date,
    .review_group_id = "issn:1234-5678",
    .convening_organization = org,
};

const peer_review: model.PeerReview = .{
    .meta = meta,
    .reviewer_role = .{ .known = .reviewer },
    .review_identifiers = &ext_ids,
    .review_url = "https://x",
    .review_type = .{ .known = .review },
    .review_completion_date = date,
    .review_group_id = "issn:1234-5678",
    .subject_external_identifier = ext_id,
    .subject_container_name = "c",
    .subject_type = "journal-article",
    .subject_name = title,
    .subject_url = "https://x",
    .convening_organization = org,
};

const proposal: model.Proposal = .{
    .title = title,
    .hosts = &.{org},
    .external_ids = &ext_ids,
    .start_date = date,
    .end_date = date,
    .url = "https://x",
};

const research_resource: model.ResearchResource = .{
    .meta = meta,
    .proposal = proposal,
    .resource_items = &.{.{
        .resource_name = "n",
        .resource_type = .{ .known = .equipment },
        .hosts = &.{org},
        .external_ids = &ext_ids,
        .url = "https://x",
    }},
};

const activities: model.ActivitiesSummary = .{
    .path = "/p",
    .last_modified_date = ts,
    .distinctions = affiliations(.distinction),
    .educations = affiliations(.education),
    .employments = affiliations(.employment),
    .fundings = .{ .path = "/p", .last_modified_date = ts, .groups = &.{.{
        .last_modified_date = ts,
        .external_ids = &ext_ids,
        .funding_summaries = &.{funding_summary},
    }} },
    .invited_positions = affiliations(.invited_position),
    .memberships = affiliations(.membership),
    .peer_reviews = .{ .path = "/p", .last_modified_date = ts, .groups = &.{.{
        .last_modified_date = ts,
        .external_ids = &ext_ids,
        .duplicates = &.{.{
            .last_modified_date = ts,
            .external_ids = &ext_ids,
            .summaries = &.{peer_review_summary},
        }},
    }} },
    .qualifications = affiliations(.qualification),
    .research_resources = .{ .path = "/p", .last_modified_date = ts, .groups = &.{.{
        .last_modified_date = ts,
        .external_ids = &ext_ids,
        .summaries = &.{.{ .meta = meta, .proposal = proposal }},
    }} },
    .services = affiliations(.service),
    .works = .{ .path = "/p", .last_modified_date = ts, .groups = &.{.{
        .last_modified_date = ts,
        .external_ids = &ext_ids,
        .work_summaries = &.{work_summary},
    }} },
};

const name: model.Name = .{
    .visibility = .{ .known = .public },
    .path = "/p",
    .created_date = ts,
    .last_modified_date = ts,
    .given_names = "g",
    .family_name = "f",
    .credit_name = "c",
};

const biography: model.Biography = .{
    .visibility = .{ .known = .public },
    .path = "/p",
    .created_date = ts,
    .last_modified_date = ts,
    .content = "b",
};

const other_names: model.OtherNames = .{ .path = "/p", .last_modified_date = ts, .items = &.{.{ .meta = meta, .content = "o" }} };

const person: model.Person = .{
    .path = "/p",
    .last_modified_date = ts,
    .name = name,
    .other_names = other_names,
    .biography = biography,
    .researcher_urls = .{ .path = "/p", .last_modified_date = ts, .items = &.{.{ .meta = meta, .url_name = "n", .url = "https://x" }} },
    .emails = .{ .path = "/p", .last_modified_date = ts, .items = &.{.{ .meta = meta, .email = "a@b.c", .verified = true, .primary = true }} },
    .addresses = .{ .path = "/p", .last_modified_date = ts, .items = &.{.{ .meta = meta, .country = "US" }} },
    .keywords = .{ .path = "/p", .last_modified_date = ts, .items = &.{.{ .meta = meta, .content = "k" }} },
    .external_identifiers = .{ .path = "/p", .last_modified_date = ts, .items = &ext_ids },
};

const record: model.Record = .{
    .path = "/0000-0002-1825-0097",
    .orcid_identifier = ident,
    .preferences = .{ .locale = "en" },
    .history = .{
        .visibility = .{ .known = .private },
        .creation_method = .{ .known = .API },
        .completion_date = ts,
        .submission_date = ts,
        .last_modified_date = ts,
        .claimed = true,
        .source = source,
        .deactivation_date = ts,
        .verified_email = true,
        .verified_primary_email = true,
    },
    .person = person,
    .activities_summary = activities,
};

const every_root = [_]model.Root{
    .{ .record = record },
    .{ .work = work },
    .{ .funding = funding },
    .{ .peer_review = peer_review },
    .{ .research_resource = research_resource },
    .{ .personal_details = .{ .path = "/p", .last_modified_date = ts, .name = name, .other_names = other_names, .biography = biography } },
    .{ .name = name },
    .{ .biography = biography },
    .{ .credit_name = "c" },
    .{ .bulk = .{ .items = &.{
        .{ .work = work },
        .{ .@"error" = .{ .response_code = 409, .developer_message = "d", .user_message = "u", .error_code = 9021, .more_info = "https://x" } },
    } } },
    .{ .search = .{ .num_found = 1, .results = &.{ident} } },
    .{ .expanded_search = .{ .num_found = 1, .results = &.{.{
        .orcid_id = "0000-0002-1825-0097",
        .given_names = "g",
        .family_names = "f",
        .credit_name = "c",
        .other_names = &.{"o"},
        .emails = &.{"a@b.c"},
        .institution_names = &.{"i"},
    }} } },
    .{ .affiliation = affiliation(.distinction) },
    .{ .affiliation = affiliation(.education) },
    .{ .affiliation = affiliation(.employment) },
    .{ .affiliation = affiliation(.invited_position) },
    .{ .affiliation = affiliation(.membership) },
    .{ .affiliation = affiliation(.qualification) },
    .{ .affiliation = affiliation(.service) },
};

test "every XSD element and attribute has a model counterpart" {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var decl_el: Set = .empty;
    var decl_at: Set = .empty;
    try declared(a, &decl_el, &decl_at);
    var el: Set = .empty;
    var at: Set = .empty;
    for (every_root) |root| {
        const text = try yorc.xml.toOwned(a, &root, null);
        // the kitchen-sink model must also survive a round trip
        var back = try yorc.xml.parse(gpa, text, .{}, null);
        defer back.deinit();
        try support.expectSameModel(gpa, root, back.root, "kitchen sink");
        try emitted(a, text, &el, &at);
    }
    var allowed: Set = .empty;
    try allowList(a, &allowed);

    var bad: usize = 0;
    // emitted but not declared
    for ([_]*Set{ &el, &at }) |set| {
        for (set.keys()) |k| {
            if (!decl_el.contains(k) and !decl_at.contains(k)) {
                std.debug.print("written but not declared by any XSD: {s}\n", .{k});
                bad += 1;
            }
        }
    }
    // declared but not emitted, and not listed
    for ([_]*Set{ &decl_el, &decl_at }) |set| {
        for (set.keys()) |k| {
            const covered = el.contains(k) or at.contains(k);
            if (!covered and !allowed.contains(k)) {
                std.debug.print("declared by the XSDs but without a model counterpart: {s}\n", .{k});
                bad += 1;
            }
            if (covered and allowed.contains(k)) {
                std.debug.print("listed in xsd_uncovered.txt but covered (remove): {s}\n", .{k});
                bad += 1;
            }
        }
    }
    // listed but not declared at all (stale)
    for (allowed.keys()) |k| {
        if (!decl_el.contains(k) and !decl_at.contains(k)) {
            std.debug.print("listed in xsd_uncovered.txt but not declared: {s}\n", .{k});
            bad += 1;
        }
    }
    try testing.expectEqual(@as(usize, 0), bad);
    try testing.expectEqual(@as(usize, 11), allowed.count());
}

test "the kitchen sink also survives JSON" {
    for (every_root) |root| {
        const j = try yorc.json.toOwned(gpa, &root, null);
        defer gpa.free(j);
        var back = try yorc.json.parse(gpa, root.kind().?, j, null);
        defer back.deinit();
        const j2 = try yorc.json.toOwned(gpa, &back.root, null);
        defer gpa.free(j2);
        try testing.expectEqualStrings(j, j2);
    }
}

test "namespaces match the XSDs" {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var tns: Set = .empty;
    for (fixtures.xsds) |f| {
        const key = "targetNamespace=\"";
        const i = (std.mem.indexOf(u8, f.data, key) orelse return error.NoTargetNamespace) + key.len;
        const j = std.mem.indexOfScalarPos(u8, f.data, i, '"').?;
        try tns.put(a, f.data[i..j], {});
    }
    var ours: Set = .empty;
    for (0..yorc.xml.Ns.count) |i| {
        const ns: yorc.xml.Ns = @fromBackingInt(@intCast(i));
        try ours.put(a, try std.fmt.allocPrint(a, "{s}{s}", .{ yorc.xml.Ns.uri_base, ns.prefix() }), {});
    }
    try testing.expectEqual(tns.count(), ours.count());
    for (ours.keys()) |k| try testing.expect(tns.contains(k));
}

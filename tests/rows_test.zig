//! Section rows of every read sample and the real record, against the
//! expectations yorc-rs's tests/samples.rs checks (which come from
//! yorc-duckdb's test/sql/orcid_sections.test, orcid_works.test,
//! orcid_works_xml.test, orcid_api_messages.test,
//! orcid_locked_deprecated.test and test/cpp/core_test.cpp, and from grep
//! counts).
const std = @import("std");
const yorc = @import("yorc");
const fixtures = @import("fixtures");
const support = @import("support.zig");

const testing = std.testing;
const gpa = testing.allocator;
const rows = yorc.rows;
const Section = rows.Section;
const Tables = rows.Tables;

fn tables(xml: []const u8) !Tables {
    return Tables.fromXml(gpa, xml);
}

/// Cell as text: VARCHAR as is, integers and booleans formatted, NULL as
/// `<null>` (the convention of yorc-duckdb's core_test.cpp). `buf` holds
/// the text.
fn get(buf: []u8, t: *const Tables, s: Section, row: usize, column: []const u8) []const u8 {
    const c = t.cell(s, row, column) orelse return "<no cell>";
    return std.fmt.bufPrint(buf, "{f}", .{c}) catch "<too long>";
}

fn expectCell(want: []const u8, t: *const Tables, s: Section, row: usize, column: []const u8) !void {
    var buf: [512]u8 = undefined;
    const got = get(&buf, t, s, row, column);
    if (!std.mem.eql(u8, want, got)) {
        std.debug.print("{s}[{d}].{s}: expected \"{s}\", got \"{s}\"\n", .{ s.name(), row, column, want, got });
        return error.TestUnexpectedCell;
    }
}

fn findRow(t: *const Tables, s: Section, column: []const u8, value: []const u8) ?usize {
    var buf: [512]u8 = undefined;
    for (0..t.count(s)) |r| {
        if (std.mem.eql(u8, get(&buf, t, s, r, column), value)) return r;
    }
    return null;
}

fn counts(t: *const Tables) [Section.all.len]usize {
    var out: [Section.all.len]usize = undefined;
    for (Section.all, &out) |s, *o| o.* = t.count(s);
    return out;
}

test "every read sample parses into rows of the right width" {
    var n: usize = 0;
    for (fixtures.read_samples) |f| {
        if (!support.isXml(f)) continue;
        var doc = try yorc.xml.parse(gpa, f.data, .{}, null);
        defer doc.deinit();
        try testing.expect(doc.root != .unknown);
        var t = try Tables.fromDocument(gpa, &doc, "h");
        defer t.deinit();
        for (Section.all) |s| {
            for (t.get(s)) |row| try testing.expectEqual(s.columns().len, row.len);
        }
        n += 1;
    }
    try testing.expectEqual(@as(usize, 53), n);
}

// ------------------------------------------------------------ record-3.0.xml

test "record sample counts" {
    var t = try tables(fixtures.readSample("record-3.0.xml"));
    defer t.deinit();
    // orcid_sections.test: 1 1 7 1 1 0 0 16 1 6 1; orcid_api_messages.test:
    // no search_results or errors rows; one host in the
    // research-resource-summary's proposal (record-3.0.xml:639-652)
    try testing.expectEqualSlices(usize, &.{ 1, 1, 7, 1, 1, 0, 0, 16, 1, 6, 1, 0, 0, 1 }, &counts(&t));
}

test "record sample values" {
    const xml = fixtures.readSample("record-3.0.xml");
    var t = try tables(xml);
    defer t.deinit();
    var buf: [512]u8 = undefined;

    const kinds = [_][]const u8{ "distinction", "education", "employment", "invited-position", "membership", "qualification", "service" };
    for (kinds) |k| try testing.expect(findRow(&t, .affiliations, "affiliation_type", k) != null);
    try testing.expectEqual(@as(usize, 7), t.count(.affiliations));
    for (0..t.count(.affiliations)) |r| try expectCell("8888-8888-8888-8880", &t, .affiliations, r, "orcid");

    try expectCell("give-names", &t, .person, 0, "given_names");
    try expectCell("family-name", &t, .person, 0, "family_name");
    try expectCell("credit-name", &t, .person, 0, "credit_name");
    try expectCell("biography", &t, .person, 0, "biography");
    try expectCell("public", &t, .person, 0, "name_visibility");

    const items = [_][2][]const u8{
        .{ "address", "US" },
        .{ "email", "user1@email.com" },
        .{ "external-identifier", "value-1" },
        .{ "keyword", "keyword1" },
        .{ "other-name", "other-name-1" },
        .{ "researcher-url", "url-name-1" },
    };
    try testing.expectEqual(@as(usize, 6), t.count(.person_items));
    for (items) |it| {
        const r = findRow(&t, .person_items, "kind", it[0]) orelse return error.TestMissingItem;
        try expectCell(it[1], &t, .person_items, r, "value");
    }
    const ext = findRow(&t, .person_items, "kind", "external-identifier").?;
    try expectCell("http://url.com/1", &t, .person_items, ext, "url");
    try expectCell("type-1", &t, .person_items, ext, "type");

    try expectCell("API", &t, .history, 0, "creation_method");
    try expectCell("true", &t, .history, 0, "claimed");
    try expectCell("private", &t, .history, 0, "visibility");

    // record-3.0.xml:20-24, common:orcid-identifier of the record
    try expectCell("https://orcid.org/8888-8888-8888-8880", &t, .person, 0, "orcid_uri");
    try expectCell("orcid.org", &t, .person, 0, "orcid_host");
    // no assertion origin anywhere in record-3.0.xml (grep -c assertion-origin: 0)
    for ([_]Section{ .affiliations, .person_items, .history }) |s| {
        for (0..t.count(s)) |r| {
            try expectCell("<null>", &t, s, r, "assertion_origin_name");
            try expectCell("<null>", &t, s, r, "assertion_origin_orcid");
        }
    }

    // the research resource summary (timeline expectation in core_test.cpp)
    try expectCell("2017-09-08T13:31:19.987Z", &t, .research_resources, 0, "last_modified");
    try expectCell("2015-06-25T16:01:12.718Z", &t, .research_resources, 0, "created");
    try expectCell("Giant Laser Award", &t, .research_resources, 0, "title");
    try expectCell("8888-8888-8888-8880", &t, .research_resources, 0, "orcid");
    try expectCell("research-resource-summary", &t, .research_resources, 0, "item");

    const emp = findRow(&t, .affiliations, "affiliation_type", "employment").?;
    try expectCell("employment:role-title", &t, .affiliations, emp, "role_title");
    try expectCell("2025", &t, .affiliations, emp, "end_year");
    try expectCell("<null>", &t, .affiliations, emp, "end_month");
    _ = &buf;

    // the one host of the research-resource-summary (record-3.0.xml:639-652)
    try testing.expectEqual(@as(usize, 1), t.count(.research_resource_hosts));
    try expectRow(&t, .research_resource_hosts, 0, &host_cols_all, &.{
        "8888-8888-8888-8880", "1234", "1",    "XSEDE",    "city",   "region",
        "US",                  "XX",   "grid", "proposal", "<null>",
    });

    // the same facts through the typed model
    var doc = try yorc.xml.parse(gpa, xml, .{}, null);
    defer doc.deinit();
    try testing.expectEqualStrings("8888-8888-8888-8880", doc.orcid().?);
    const record = doc.record().?;
    const rr = record.activities_summary.?.research_resources.?.groups[0].summaries[0];
    try testing.expectEqualStrings("2017-09-08T13:31:19.987Z", rr.meta.last_modified_date.?);
    try testing.expectEqual(@as(?i64, 1234), rr.meta.put_code);
    const acts = doc.activitiesSummary().?;
    for (yorc.model.AffiliationKind.all) |k| {
        const list = acts.affiliations(k).?;
        try testing.expectEqual(@as(usize, 1), list.groups.len);
        try testing.expectEqual(k, list.groups[0].summaries[0].kind);
    }
    try testing.expectEqualStrings("zh_CN", record.preferences.?.locale.?);
}

// ------------------------------------------------------------ other samples

test "work-full sample" {
    var t = try tables(fixtures.readSample("work-full-3.0.xml"));
    defer t.deinit();
    const w = Section.works;
    try testing.expectEqual(@as(usize, 1), t.count(w));
    try expectCell("work", &t, w, 0, "item");
    try expectCell("123", &t, w, 0, "put_code");
    try expectCell("<null>", &t, w, 0, "orcid");
    try expectCell("<null>", &t, w, 0, "group_index");
    try expectCell("common:translated-title", &t, w, 0, "translated_title");
    try expectCell("en", &t, w, 0, "translated_title_language");
    try expectCell("formatted-unspecified", &t, w, 0, "citation_type");
    try expectCell("work:citation", &t, w, 0, "citation_value");
    try expectCell("work:short-description", &t, w, 0, "short_description");
    try expectCell("en", &t, w, 0, "language_code");
    try expectCell("AF", &t, w, 0, "country");
    try expectCell("work:doi", &t, w, 0, "doi");
    try expectCell("1948", &t, w, 0, "pub_year");
    try expectCell("2", &t, w, 0, "pub_month");
    try expectCell("<null>", &t, w, 0, "source_name");

    const c = Section.contributors;
    try testing.expectEqual(@as(usize, 1), t.count(c));
    try expectCell("work", &t, c, 0, "owner");
    try expectCell("123", &t, c, 0, "owner_put_code");
    try expectCell("1", &t, c, 0, "ordinal");
    try expectCell("8888-8888-8888-8880", &t, c, 0, "contributor_orcid");
    try expectCell("work:credit-name", &t, c, 0, "credit_name");
    try expectCell("work@contributor.email", &t, c, 0, "email");
    try expectCell("first", &t, c, 0, "sequence");
    try expectCell("author", &t, c, 0, "role");

    const e = Section.external_ids;
    try testing.expectEqual(@as(usize, 2), t.count(e));
    try expectCell("agr", &t, e, 0, "type");
    try expectCell("work:external-identifier-id", &t, e, 0, "value");
    try expectCell("version-of", &t, e, 0, "relationship");
    try expectCell("doi", &t, e, 1, "type");
    try expectCell("work:doi", &t, e, 1, "value");
    try expectCell("self", &t, e, 1, "relationship");
    try expectCell("work", &t, e, 1, "owner");
    try expectCell("external-ids", &t, e, 1, "container");
}

test "research-resource sample" {
    var t = try tables(fixtures.readSample("research-resource-3.0.xml"));
    defer t.deinit();
    const r = Section.research_resources;
    try testing.expectEqual(@as(usize, 1), t.count(r));
    try expectCell("0000-0003-0902-4386", &t, r, 0, "orcid");
    try expectCell("Giant Laser Award", &t, r, 0, "title");
    try expectCell("de", &t, r, 0, "translated_title_language");
    try expectCell("XSEDE", &t, r, 0, "host_name"); // first host wins
    try expectCell("1999", &t, r, 0, "start_year");
    try expectCell("2012", &t, r, 0, "end_year");
    try expectCell("http://xsede.org/GiantLaserAward", &t, r, 0, "url");

    const i = Section.research_resource_items;
    try testing.expectEqual(@as(usize, 2), t.count(i));
    try expectCell("1234", &t, i, 0, "owner_put_code");
    try expectCell("1", &t, i, 0, "ordinal");
    try expectCell("Giant Laser 1", &t, i, 0, "resource_name");
    try expectCell("infrastructures", &t, i, 0, "resource_type");
    try expectCell("Lasers-R-US", &t, i, 0, "host_name");
    try expectCell("http://blah.com", &t, i, 0, "url");
    try expectCell("2", &t, i, 1, "ordinal");
    try expectCell("Moon Targets", &t, i, 1, "resource_name");
    try expectCell("Moon Holdings Ltd", &t, i, 1, "host_name");
    try expectCell("http://blah2.com", &t, i, 1, "url");

    try testing.expectEqual(@as(usize, 5), t.count(.external_ids));

    // Every host (CROSSCHECK #9): research-resource-3.0.xml has two proposal
    // hosts (lines 24-49) and one per resource item (lines 82-95, 114-127);
    // the first-host columns above keep XSEDE and Lasers-R-US.
    const h = Section.research_resource_hosts;
    const id = "0000-0003-0902-4386";
    try testing.expectEqual(@as(usize, 4), t.count(h));
    try expectRow(&t, h, 0, &host_cols, &.{ id, "1234", "1", "XSEDE", "grid", "proposal", "<null>" });
    try expectRow(&t, h, 1, &host_cols, &.{ id, "1234", "2", "Lasers-R-Us", "lei", "proposal", "<null>" });
    try expectRow(&t, h, 2, &host_cols, &.{ id, "1234", "1", "Lasers-R-US", "grid", "resource-item", "1" });
    try expectRow(&t, h, 3, &host_cols, &.{ id, "1234", "1", "Moon Holdings Ltd", "lei", "resource-item", "2" });
    for (0..4) |row| {
        try expectCell("city", &t, h, row, "host_city");
        try expectCell("region", &t, h, row, "host_region");
        try expectCell("US", &t, h, row, "host_country");
        try expectCell("XX", &t, h, row, "host_disambiguated_id");
    }

    // The summaries of research-resources-3.0.xml: 1234 has two hosts, 1235
    // one (lines 41-68 and 116-130); the iD is the root path's
    // (/8888-8888-8888-8880/research-resources); trailing whitespace of
    // "XX\n\t..." is trimmed.
    var ts = try tables(fixtures.readSample("research-resources-3.0.xml"));
    defer ts.deinit();
    const sid = "8888-8888-8888-8880";
    try testing.expectEqual(@as(usize, 3), ts.count(h));
    try expectRow(&ts, h, 0, &host_cols, &.{ sid, "1234", "1", "XSEDE", "grid", "proposal", "<null>" });
    try expectRow(&ts, h, 1, &host_cols, &.{ sid, "1234", "2", "Lasers-R-Us", "lei", "proposal", "<null>" });
    try expectRow(&ts, h, 2, &host_cols, &.{ sid, "1235", "1", "XSEDE", "grid", "proposal", "<null>" });
    try expectCell("XX", &ts, h, 0, "host_disambiguated_id");
    try testing.expectEqual(@as(usize, 0), ts.count(.research_resource_items));
}

const host_cols = [_][]const u8{
    "orcid", "owner_put_code", "ordinal", "host_name", "host_disambiguation_source", "container", "item_ordinal",
};

/// Every `research_resource_hosts` column but `source_hash`.
const host_cols_all = [_][]const u8{
    "orcid",                      "owner_put_code", "ordinal",      "host_name",
    "host_city",                  "host_region",    "host_country", "host_disambiguated_id",
    "host_disambiguation_source", "container",      "item_ordinal",
};

test "research-resource JSON write sample: every host" {
    var t = try jsonTables("research-resource", fixtures.writeSample("research-resource-3.0.json"));
    defer t.deinit();
    const h = Section.research_resource_hosts;
    const cols = [_][]const u8{
        "orcid",     "owner_put_code", "container",   "item_ordinal",          "ordinal",
        "host_name", "host_city",      "host_region", "host_disambiguated_id", "host_disambiguation_source",
    };
    const n = "<null>";
    const grid = [2][]const u8{ "grid.455335.1", "GRID" };
    const ror = [2][]const u8{ "https://ror.org/027ka1x80", "ROR" };
    const Want = struct { []const u8, []const u8, []const u8, []const u8, []const u8, []const u8, [2][]const u8 };
    const want = [_]Want{
        .{ "proposal", n, "1", "ORCID", "Bethesda", "Maryland", grid },
        .{ "proposal", n, "2", "NASA", "Washington", "D.C", ror },
        .{ "resource-item", "1", "1", "Lasers-R-US", "Bethesda", "Maryland", grid },
        .{ "resource-item", "2", "1", "Moon Holdings Ltd", "Bethesda", "Maryland", grid },
        .{ "resource-item", "3", "1", "Moon Holdings Ltd", "Bethesda", "Maryland", grid },
        .{ "resource-item", "4", "1", "Moon Holdings Ltd", "Bethesda", "Maryland", grid },
        .{ "resource-item", "5", "1", "Moon Holdings Ltd", "Bethesda", "Maryland", grid },
    };
    try testing.expectEqual(want.len, t.count(h));
    for (want, 0..) |wr, r| {
        try expectRow(&t, h, r, &cols, &.{ n, n, wr[0], wr[1], wr[2], wr[3], wr[4], wr[5], wr[6][0], wr[6][1] });
    }
    // the first-host column keeps ORCID (orcid_json.test)
    try expectCell("ORCID", &t, .research_resources, 0, "host_name");
}

test "peer-review-full sample" {
    var t = try tables(fixtures.readSample("peer-review-full-3.0.xml"));
    defer t.deinit();
    const p = Section.peer_reviews;
    try testing.expectEqual(@as(usize, 1), t.count(p));
    try expectCell("12345", &t, p, 0, "put_code");
    try expectCell("1948", &t, p, 0, "completion_year");
    try expectCell("orcid-generated:12345", &t, p, 0, "review_group_id");
    try expectCell("peer-review:subject-translated-name", &t, p, 0, "subject_translated_name");
    // read_samples/peer-review-full-3.0.xml:44 language-code="en"
    try expectCell("en", &t, p, 0, "subject_translated_name_language");
    try expectCell("doi", &t, p, 0, "subject_id_type");
    try expectCell("FUNDREF", &t, p, 0, "convening_org_disambiguation_source");

    const e = Section.external_ids;
    try testing.expectEqual(@as(usize, 2), t.count(e));
    try expectCell("review-identifiers", &t, e, 0, "container");
    try expectCell("source-work-id", &t, e, 0, "type");
    try expectCell("peer-review", &t, e, 1, "container");
    try expectCell("doi", &t, e, 1, "type");
}

test "collections and single documents" {
    {
        var t = try tables(fixtures.readSample("works-3.0.xml"));
        defer t.deinit();
        try testing.expectEqual(@as(usize, 3), t.count(.works));
    }
    {
        var t = try tables(fixtures.readSample("employments-3.0.xml"));
        defer t.deinit();
        try testing.expectEqual(@as(usize, 2), t.count(.affiliations));
        try expectCell("2", &t, .affiliations, 1, "group_index");
    }
    {
        var t = try tables(fixtures.readSample("person-3.0.xml"));
        defer t.deinit();
        try testing.expectEqual(@as(usize, 6), t.count(.person_items));
    }
    {
        var t = try tables(fixtures.readSample("bulk-work-err.xml"));
        defer t.deinit();
        try testing.expectEqual(@as(usize, 1), t.count(.works));
    }
    {
        var t = try tables(fixtures.readSample("history-3.0.xml"));
        defer t.deinit();
        try testing.expectEqual(@as(usize, 1), t.count(.history));
        try expectCell("API", &t, .history, 0, "creation_method");
        try expectCell("true", &t, .history, 0, "claimed");
        try expectCell("true", &t, .history, 0, "verified_email");
        try expectCell("private", &t, .history, 0, "visibility");
    }
    var doc = try yorc.xml.parse(gpa, fixtures.readSample("bulk-work-err.xml"), .{}, null);
    defer doc.deinit();
    const items = doc.root.bulk.items;
    try testing.expectEqual(@as(usize, 2), items.len);
    try testing.expectEqual(@as(?i64, 400), items[1].@"error".response_code);
    try testing.expectEqual(@as(?i64, 9037), items[1].@"error".error_code);
}

// The literal of yorc-duckdb/test/sql/orcid_works_xml.test: entities,
// numeric references, CDATA, self-closing elements, orcid-identifier fallback.
test "works xml edge literal" {
    const xml =
        \\<?xml version="1.0"?>
        \\<!-- comment -->
        \\<record:record xmlns:record="r" xmlns:common="c" xmlns:activities="a" xmlns:work="w">
        \\  <common:orcid-identifier><common:path>0000-0002-1825-0097</common:path></common:orcid-identifier>
        \\  <activities:activities-summary>
        \\    <activities:works>
        \\      <activities:group>
        \\        <work:work-summary put-code="7" visibility="public">
        \\          <work:title><common:title>Fish &amp; Chips &#x2014; &#233;t&#xE9; &lt;3</common:title></work:title>
        \\          <common:external-ids>
        \\            <common:external-id>
        \\              <common:external-id-type>doi</common:external-id-type>
        \\              <common:external-id-value>10.1000/ABC</common:external-id-value>
        \\              <common:external-id-relationship>part-of</common:external-id-relationship>
        \\            </common:external-id>
        \\            <common:external-id>
        \\              <common:external-id-type>doi</common:external-id-type>
        \\              <common:external-id-value>10.1000/XYZ</common:external-id-value>
        \\              <common:external-id-relationship>self</common:external-id-relationship>
        \\            </common:external-id>
        \\          </common:external-ids>
        \\          <common:url/>
        \\          <work:type>book</work:type>
        \\          <common:publication-date><common:year>1999</common:year><common:month>xx</common:month></common:publication-date>
        \\          <work:journal-title><![CDATA[A <raw> & journal]]></work:journal-title>
        \\        </work:work-summary>
        \\      </activities:group>
        \\    </activities:works>
        \\  </activities:activities-summary>
        \\</record:record>
    ;
    var t = try tables(xml);
    defer t.deinit();
    const w = Section.works;
    try testing.expectEqual(@as(usize, 1), t.count(w));
    try expectCell("0000-0002-1825-0097", &t, w, 0, "orcid");
    try expectCell("7", &t, w, 0, "put_code");
    try expectCell("1", &t, w, 0, "group_index");
    try expectCell("Fish & Chips \u{2014} \u{e9}t\u{e9} <3", &t, w, 0, "title");
    try expectCell("A <raw> & journal", &t, w, 0, "journal");
    try expectCell("10.1000/xyz", &t, w, 0, "doi");
    try expectCell("1999", &t, w, 0, "pub_year");
    try expectCell("<null>", &t, w, 0, "pub_month");
    try expectCell("<null>", &t, w, 0, "url");

    // records without works yield no rows; malformed XML is an error
    var empty = try tables("<record:record path=\"/0000-0002-1825-0097\"/>");
    defer empty.deinit();
    try testing.expectEqual(@as(usize, 0), empty.count(w));
    try testing.expectError(error.MalformedXml, Tables.fromXml(gpa, "<a><b></a>"));
}

// ------------------------------------------------- 0000-0003-0100-6634.xml

const fixture_hash = "494662244addfd21664a3a56f222a88614b83f61084888ac6162eeb970324801";

test "real record: work summaries (orcid_works.test)" {
    var doc = try yorc.xml.parse(gpa, fixtures.real_record, .{}, null);
    defer doc.deinit();
    try testing.expectEqualStrings("0000-0003-0100-6634", doc.orcid().?);
    try testing.expectEqual(@as(usize, 382), doc.activitiesSummary().?.workSummaryCount());

    var t = try Tables.fromDocument(gpa, &doc, fixture_hash);
    defer t.deinit();
    const w = Section.works;
    try testing.expectEqual(@as(usize, 382), t.count(w));

    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const Stats = struct { distinct: usize, non_null: usize };
    const stats = struct {
        fn f(al: std.mem.Allocator, tb: *const Tables, column: []const u8) !Stats {
            var seen: std.StringHashMapUnmanaged(void) = .empty;
            var non_null: usize = 0;
            for (0..tb.count(.works)) |r| {
                const c = tb.cell(.works, r, column).?;
                if (c.isNull()) continue;
                non_null += 1;
                var buf: [512]u8 = undefined;
                const s = try al.dupe(u8, try std.fmt.bufPrint(&buf, "{f}", .{c}));
                try seen.put(al, s, {});
            }
            return .{ .distinct = seen.count(), .non_null = non_null };
        }
    }.f;
    try testing.expectEqual(@as(usize, 155), (try stats(a, &t, "group_index")).distinct);
    try testing.expectEqual(@as(usize, 1), (try stats(a, &t, "orcid")).distinct);
    var put_code_sum: i64 = 0;
    for (0..382) |r| put_code_sum += t.cell(w, r, "put_code").?.asInt().?;
    try testing.expectEqual(@as(i64, 36_003_218_443), put_code_sum);
    try testing.expectEqual(@as(usize, 0), (try stats(a, &t, "subtitle")).non_null);
    try testing.expectEqual(@as(usize, 371), (try stats(a, &t, "journal")).non_null);
    try testing.expectEqual(@as(usize, 334), (try stats(a, &t, "pub_month")).non_null);
    try testing.expectEqual(@as(usize, 298), (try stats(a, &t, "pub_day")).non_null);
    try testing.expectEqual(@as(usize, 311), (try stats(a, &t, "doi")).non_null);
    try testing.expectEqual(@as(usize, 226), (try stats(a, &t, "doi")).distinct);
    try testing.expectEqual(@as(usize, 84), (try stats(a, &t, "url")).non_null);
    var min_year: i64 = std.math.maxInt(i64);
    var max_year: i64 = std.math.minInt(i64);
    for (0..382) |r| {
        if (t.cell(w, r, "pub_year").?.asInt()) |y| {
            min_year = @min(min_year, y);
            max_year = @max(max_year, y);
        }
        try expectCell("work-summary", &t, w, r, "item");
    }
    try testing.expectEqual(@as(i64, 2002), min_year);
    try testing.expectEqual(@as(i64, 2025), max_year);

    const row = findRow(&t, w, "put_code", "182082411").?;
    const expect = [_][2][]const u8{
        .{ "orcid", "0000-0003-0100-6634" },
        .{ "group_index", "1" },
        .{ "display_index", "1" },
        .{ "title", "mgbilby/oga_src: initial oga_src release" },
        .{ "subtitle", "<null>" },
        .{ "journal", "Zenodo" },
        .{ "type", "software" },
        .{ "pub_year", "2025" },
        .{ "pub_month", "4" },
        .{ "pub_day", "11" },
        .{ "doi", "10.5281/zenodo.15199545" },
        .{ "url", "<null>" },
        .{ "source_name", "DataCite" },
        .{ "visibility", "public" },
        .{ "created", "2025-04-11T18:39:27.813Z" },
        .{ "last_modified", "2025-04-11T18:39:27.813Z" },
        .{ "source_hash", fixture_hash },
        .{ "translated_title", "<null>" },
        .{ "citation_type", "<null>" },
        .{ "source_client_id", "0000-0001-8099-6984" },
        .{ "item", "work-summary" },
        .{ "path", "/0000-0003-0100-6634/work/182082411" },
    };
    for (expect) |e| try expectCell(e[1], &t, w, row, e[0]);
    // core_test.cpp: the first row's title and source client
    try expectCell("mgbilby/oga_src: initial oga_src release", &t, w, 0, "title");
    try expectCell("0000-0001-8099-6984", &t, w, 0, "source_client_id");

    const old = findRow(&t, w, "put_code", "72106251").?;
    try expectCell("155", &t, w, old, "group_index");
    try expectCell("0", &t, w, old, "display_index");
    try expectCell("dissertation-thesis", &t, w, old, "type");
    try expectCell("2002", &t, w, old, "pub_year");
    try expectCell("10.5281/zenodo.3752256", &t, w, old, "doi");

    var n_other: usize = 0;
    var n_book: usize = 0;
    var n_article: usize = 0;
    var n_title: usize = 0;
    var buf: [512]u8 = undefined;
    for (0..382) |r| {
        const ty = get(&buf, &t, w, r, "type");
        if (std.mem.eql(u8, ty, "other")) n_other += 1;
        if (std.mem.eql(u8, ty, "book")) n_book += 1;
        if (std.mem.eql(u8, ty, "journal-article")) n_article += 1;
        if (std.mem.eql(u8, get(&buf, &t, w, r, "title"), "BeDuhn\u{2019}s Greek Reconstruction of Marcion\u{2019}s Gospel")) n_title += 1;
    }
    try testing.expectEqual(@as(usize, 94), n_other);
    try testing.expectEqual(@as(usize, 85), n_book);
    try testing.expectEqual(@as(usize, 48), n_article);
    try testing.expectEqual(@as(usize, 3), n_title);
}

test "real record: source hash and the other sections" {
    var t = try tables(fixtures.real_record);
    defer t.deinit();
    // orcid_works_xml.test: min(source_hash) over the file's rows
    try expectCell(fixture_hash, &t, .works, 0, "source_hash");
    // orcid_sections.test plus grep counts in the file (see yorc-rs)
    try testing.expectEqualSlices(usize, &.{ 382, 7, 79, 2, 0, 0, 0, 864, 1, 49, 1, 0, 0, 0 }, &counts(&t));
    for (Section.all) |s| {
        for (0..t.count(s)) |r| try expectCell("0000-0003-0100-6634", &t, s, r, "orcid");
    }
}

// ------------------------------------------- search_results and errors

/// The cells of `columns` in row `r`, against `want` (same order).
fn expectRow(t: *const Tables, s: Section, r: usize, columns: []const []const u8, want: []const []const u8) !void {
    try testing.expectEqual(columns.len, want.len);
    for (columns, want) |c, v| try expectCell(v, t, s, r, c);
}

test "search sample" {
    // orcid_api_messages.test, orcid_recipes.test
    var t = try tables(fixtures.readSample("search-3.0.xml"));
    defer t.deinit();
    try testing.expectEqual(@as(usize, 1), t.count(.search_results));
    try expectRow(&t, .search_results, 0, &.{
        "num_found", "ordinal", "orcid", "orcid_uri", "orcid_host", "given_names", "item",
    }, &.{
        "1", "1", "8888-8888-8888-8880", "https://orcid.org/8888-8888-8888-8880", "orcid.org", "<null>", "result",
    });
    try testing.expectEqual(@as(usize, 0), t.count(.errors));
}

test "expanded search literal" {
    // orcid_api_messages.test (no expanded-search sample is vendored)
    const xml =
        \\<es:expanded-search num-found="7" xmlns:es="http://www.orcid.org/ns/expanded-search"><es:expanded-result><es:orcid-id>0000-0002-1825-0097</es:orcid-id><es:given-names>Given</es:given-names><es:family-names>Family</es:family-names><es:credit-name>G. Family</es:credit-name><es:other-name>Other A</es:other-name><es:other-name>Other B</es:other-name><es:email>a@example.org</es:email><es:institution-name>Inst A</es:institution-name><es:institution-name>Inst B</es:institution-name></es:expanded-result><es:expanded-result><es:orcid-id>0000-0003-0100-6634</es:orcid-id></es:expanded-result></es:expanded-search>
    ;
    var t = try tables(xml);
    defer t.deinit();
    const cols = [_][]const u8{
        "num_found",   "ordinal",     "orcid",  "orcid_uri",         "given_names", "family_names",
        "credit_name", "other_names", "emails", "institution_names", "item",
    };
    try testing.expectEqual(@as(usize, 2), t.count(.search_results));
    try expectRow(&t, .search_results, 0, &cols, &.{
        "7",         "1",                "0000-0002-1825-0097", "<null>",         "Given",           "Family",
        "G. Family", "Other A; Other B", "a@example.org",       "Inst A; Inst B", "expanded-result",
    });
    try expectRow(&t, .search_results, 1, &cols, &.{
        "7",      "2",      "0000-0003-0100-6634", "<null>", "<null>",          "<null>",
        "<null>", "<null>", "<null>",              "<null>", "expanded-result",
    });
}

const error_cols = [_][]const u8{
    "orcid",     "response_code", "developer_message", "user_message",  "error_code",
    "more_info", "container",     "position",          "primary_orcid",
};

test "error sample" {
    // orcid_api_messages.test
    var t = try tables(fixtures.readSample("error-3.0.xml"));
    defer t.deinit();
    try testing.expectEqual(@as(usize, 1), t.count(.errors));
    try expectRow(&t, .errors, 0, &error_cols, &.{
        "<null>",             "0",      "error:developer-message", "error:user-message", "0",
        "http://tempuri.org", "<null>", "1",                       "<null>",
    });
    var buf: [512]u8 = undefined;
    try testing.expectEqual(@as(usize, 64), get(&buf, &t, .errors, 0, "source_hash").len);
}

test "bulk error sample" {
    // orcid_api_messages.test, orcid_recipes.test, orcid_locked_deprecated.test
    var t = try tables(fixtures.readSample("bulk-work-err.xml"));
    defer t.deinit();
    try testing.expectEqual(@as(usize, 1), t.count(.errors));
    var buf: [1024]u8 = undefined; // the developer message is 623 bytes
    try testing.expect(std.mem.startsWith(u8, get(&buf, &t, .errors, 0, "developer_message"), "Invalid work type, valid values are:"));
    try expectRow(&t, .errors, 0, &.{
        "response_code", "user_message", "error_code", "more_info", "container", "position", "orcid", "primary_orcid",
    }, &.{
        "400", "Please specify a work type.", "9037", "http://members.orcid.org/api/api-error-codes", "bulk", "2", "<null>", "<null>",
    });
    // the work of the same response is still a works row
    try testing.expectEqual(@as(usize, 1), t.count(.works));
}

const xml_decl = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n";
const error_open = "<error:error xmlns:error=\"http://www.orcid.org/ns/error\">\n";

/// yorc-duckdb's test/data/errors/0000-0001-5272-5001_locked.xml (only the
/// `error` namespace declaration kept), without its first two lines.
const locked_body =
    \\    <error:response-code>409</error:response-code>
    \\    <error:developer-message>409 Conflict: The ORCID record is locked and cannot be edited. ORCID https://orcid.org/0000-0001-5272-5001</error:developer-message>
    \\    <error:user-message>The ORCID record is locked.</error:user-message>
    \\    <error:error-code>9018</error:error-code>
    \\    <error:more-info>https://members.orcid.org/api/resources/troubleshooting</error:more-info>
    \\</error:error>
    \\
;
const locked = xml_decl ++ error_open ++ locked_body;

/// yorc-duckdb's test/data/errors/0000-0001-5433-3001_deprecated.xml (only
/// the `error` namespace declaration kept).
const deprecated = xml_decl ++ error_open ++
    \\    <error:response-code>301</error:response-code>
    \\    <error:developer-message>301 Moved Permanently: This account is deprecated. Please refer to account: https://orcid.org/0009-0008-8963-1314. ORCID https://orcid.org/0000-0001-5433-3001</error:developer-message>
    \\    <error:user-message>This account is deprecated. Please refer to account: https://orcid.org/0009-0008-8963-1314.</error:user-message>
    \\    <error:error-code>9007</error:error-code>
    \\    <error:more-info>https://members.orcid.org/api/resources/troubleshooting</error:more-info>
    \\</error:error>
    \\
;

test "locked and deprecated errors" {
    // orcid_locked_deprecated.test, orcid_recipes.test
    const cols = [_][]const u8{ "orcid", "response_code", "error_code", "user_message", "container", "primary_orcid" };
    {
        var t = try tables(locked);
        defer t.deinit();
        try testing.expectEqual(@as(usize, 1), t.count(.errors));
        try expectRow(&t, .errors, 0, &cols, &.{
            "0000-0001-5272-5001", "409", "9018", "The ORCID record is locked.", "<null>", "<null>",
        });
    }
    {
        var t = try tables(deprecated);
        defer t.deinit();
        try testing.expectEqual(@as(usize, 1), t.count(.errors));
        try expectRow(&t, .errors, 0, &cols, &.{
            "0000-0001-5433-3001",                                                                         "301",    "9007",
            "This account is deprecated. Please refer to account: https://orcid.org/0009-0008-8963-1314.", "<null>", "0009-0008-8963-1314",
        });
    }
    // neither document is a record: no person, history or works rows
    for ([_][]const u8{ locked, deprecated }) |xml| {
        var t = try tables(xml);
        defer t.deinit();
        for ([_]Section{ .person, .history, .works }) |s| try testing.expectEqual(@as(usize, 0), t.count(s));
    }
    // a root path wins over the iD the message names
    const with_path = xml_decl ++ "<error:error path=\"/0000-0002-1825-0097\" xmlns:error=\"http://www.orcid.org/ns/error\">\n" ++ locked_body;
    var tp = try tables(with_path);
    defer tp.deinit();
    try expectCell("0000-0002-1825-0097", &tp, .errors, 0, "orcid");
}

test "API message items only at the document element" {
    // orcid_activity_items.test: elements named like API messages inside a
    // work are not items
    const xml =
        \\<work:work xmlns:work="w" xmlns:x="x" put-code="1" path="/0000-0002-1825-0097/work/1"><x:person><x:name><x:given-names>No</x:given-names></x:name></x:person><x:history><x:claimed>true</x:claimed></x:history><x:record><x:person/></x:record><x:error><x:response-code>400</x:response-code></x:error><x:notification/><x:record-summary/><x:search><x:result/></x:search><x:group-id-record put-code="2"/></work:work>
    ;
    var t = try tables(xml);
    defer t.deinit();
    var got: [5]usize = undefined;
    for ([_]Section{ .person, .history, .errors, .search_results, .works }, &got) |s, *g| g.* = t.count(s);
    try testing.expectEqualSlices(usize, &.{ 0, 0, 0, 0, 1 }, &got);
}

fn jsonTables(kind: []const u8, j: []const u8) !Tables {
    var doc = try yorc.json.parse(gpa, kind, j, null);
    defer doc.deinit();
    return Tables.fromDocument(gpa, &doc, null);
}

test "API messages from JSON" {
    // orcid_json.test
    {
        var t = try jsonTables("error",
            \\{"response-code": 0, "developer-message": "error:developer-message", "user-message": "error:user-message", "error-code": 0, "more-info": "http://tempuri.org"}
        );
        defer t.deinit();
        var x = try tables(fixtures.readSample("error-3.0.xml"));
        defer x.deinit();
        var a: [512]u8 = undefined;
        var b: [512]u8 = undefined;
        for (Section.errors.columns()) |c| {
            if (std.mem.eql(u8, c.name, "source_hash")) continue;
            try testing.expectEqualStrings(get(&a, &x, .errors, 0, c.name), get(&b, &t, .errors, 0, c.name));
        }
    }
    {
        var t = try jsonTables("search",
            \\{"result": [{"orcid-identifier": {"uri": "https://orcid.org/8888-8888-8888-8880", "path": "8888-8888-8888-8880", "host": "orcid.org"}}], "num-found": 1}
        );
        defer t.deinit();
        try expectRow(&t, .search_results, 0, &.{ "num_found", "ordinal", "orcid", "orcid_uri", "item" }, &.{
            "1", "1", "8888-8888-8888-8880", "https://orcid.org/8888-8888-8888-8880", "result",
        });
    }
    {
        var t = try jsonTables("bulk",
            \\{"bulk": [{"work": {"put-code": 156043, "title": {"title": {"value": "W"}}, "type": "journal-article"}}, {"error": {"response-code": 400, "developer-message": "Invalid work type", "user-message": "Please specify a work type.", "error-code": 9037, "more-info": "http://members.orcid.org/api/api-error-codes"}}]}
        );
        defer t.deinit();
        try expectRow(&t, .errors, 0, &.{ "container", "position", "response_code", "error_code" }, &.{ "bulk", "2", "400", "9037" });
    }
}

// ------------------------------- CROSSCHECK #9 and #10 in ORCID's JSON

fn textLess(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

/// The distinct `put_code`s (person items: `kind:put_code`) of the rows of
/// `s` whose `assertion_origin_orcid` is `who`, sorted, against `want`.
fn expectAsserted(t: *const Tables, s: Section, who: []const u8, want: []const []const u8) !void {
    var got: std.ArrayList([]const u8) = .empty;
    defer {
        for (got.items) |g| gpa.free(g);
        got.deinit(gpa);
    }
    var a: [512]u8 = undefined;
    var b: [512]u8 = undefined;
    for (0..t.count(s)) |r| {
        if (!std.mem.eql(u8, get(&a, t, s, r, "assertion_origin_orcid"), who)) continue;
        const pc = get(&a, t, s, r, "put_code");
        const one = if (s == .person_items)
            try std.fmt.allocPrint(gpa, "{s}:{s}", .{ get(&b, t, s, r, "kind"), pc })
        else
            try gpa.dupe(u8, pc);
        try got.append(gpa, one);
    }
    std.mem.sort([]const u8, got.items, {}, textLess);
    var n: usize = 0;
    for (got.items, 0..) |g, i| {
        if (i > 0 and std.mem.eql(u8, g, got.items[n - 1])) {
            gpa.free(g);
            continue;
        }
        got.items[n] = g;
        n += 1;
    }
    got.items.len = n;
    try testing.expectEqual(want.len, got.items.len);
    for (want, got.items) |w, g| try testing.expectEqualStrings(w, g);
}

// read_samples/record-full-3.0.json carries the assertion origin in person
// items and in activity summaries, a normalization error and a sandbox
// orcid-identifier (the values of yorc-rs's
// record_full_json_context_columns, from python3 -I over the file).
test "record-full JSON sample: the appended context columns" {
    var t = try jsonTables("record", fixtures.readSample("record-full-3.0.json"));
    defer t.deinit();
    const me = "0000-0002-7319-2192";
    // funding-summary 5909 (of 5132, 5909)
    try expectAsserted(&t, .fundings, me, &.{"5909"});
    // one per affiliation type but services' 7093 and educations' 6455, 8718
    try expectAsserted(&t, .affiliations, me, &.{ "9264", "9265", "9266", "9267", "9268", "9269", "9270" });
    // peer-review-summary 2389 (of 1961, 2389), research-resource-summary
    // 1498, work-summary 178602
    try expectAsserted(&t, .peer_reviews, me, &.{"2389"});
    try expectAsserted(&t, .research_resources, me, &.{"1498"});
    try expectAsserted(&t, .works, me, &.{"178602"});
    // person items: other-name 5813, address 3527, keyword 5097, external
    // identifier 3995
    try expectAsserted(&t, .person_items, me, &.{ "address:3527", "external-identifier:3995", "keyword:5097", "other-name:5813" });

    // the name beside the iD; no assertion-origin-client-id in any sample
    // (grep -c assertion-origin-client-id: 0)
    var a: [512]u8 = undefined;
    for ([_]Section{ .fundings, .affiliations, .peer_reviews, .research_resources, .person_items, .history }) |s| {
        for (0..t.count(s)) |r| {
            try expectCell("<null>", &t, s, r, "assertion_origin_client_id");
            const asserted = std.mem.eql(u8, get(&a, &t, s, r, "assertion_origin_orcid"), me);
            try expectCell(if (asserted) "Three releasecandidate1" else "<null>", &t, s, r, "assertion_origin_name");
            if (!asserted) try expectCell("<null>", &t, s, r, "assertion_origin_orcid");
        }
    }
    // history: no source in the sample
    try expectCell("<null>", &t, .history, 0, "assertion_origin_name");

    // works/group[0]: external-id[1] has external-id-normalized-error
    // {"error-code": "8001", ...}, at group level and in the work summary
    const e = Section.external_ids;
    var codes: usize = 0;
    for (0..t.count(e)) |r| {
        if (std.mem.eql(u8, get(&a, &t, e, r, "normalized_error_code"), "<null>")) continue;
        try expectCell("8001", &t, e, r, "normalized_error_code");
        try expectCell("Cannot normalize identifier value doi:work:doi", &t, e, r, "normalized_error");
        codes += 1;
    }
    try testing.expectEqual(@as(usize, 2), codes);
    // the person external identifier 3995 has no normalized form
    const ext = findRow(&t, .person_items, "kind", "external-identifier") orelse return error.TestMissingItem;
    for ([_][]const u8{ "normalized", "normalized_error", "normalized_error_code" }) |c| {
        try expectCell("<null>", &t, .person_items, ext, c);
    }

    // /orcid-identifier: {"uri": "https://sandbox.orcid.org/0000-0002-7319-2192",
    // "path": ..., "host": "sandbox.orcid.org"}
    try expectCell("https://sandbox.orcid.org/0000-0002-7319-2192", &t, .person, 0, "orcid_uri");
    try expectCell("sandbox.orcid.org", &t, .person, 0, "orcid_host");

    // research-resource-summary 1498: one host, NASA (proposal.hosts.organization[0])
    try testing.expectEqual(@as(usize, 1), t.count(.research_resource_hosts));
    try expectRow(&t, .research_resource_hosts, 0, &host_cols_all, &.{
        me,   "1498",          "1",    "NASA",     "Washington", "District of Columbia",
        "US", "grid.238252.c", "GRID", "proposal", "<null>",
    });
}

test "appended columns: person external identifiers, contributor host, standalone person" {
    // a person external identifier with ORCID's transient normalization and
    // an assertion origin; the other person item kinds have no normalized
    // columns
    const xml =
        \\<person:person path="/0000-0002-1825-0097/person" xmlns:person="http://www.orcid.org/ns/person" xmlns:common="http://www.orcid.org/ns/common" xmlns:external-identifier="http://www.orcid.org/ns/external-identifier" xmlns:keyword="http://www.orcid.org/ns/keyword"><external-identifier:external-identifiers><external-identifier:external-identifier put-code="7"><common:source><common:assertion-origin-orcid><common:path>0000-0003-0100-6634</common:path></common:assertion-origin-orcid><common:assertion-origin-client-id><common:path>APP-1</common:path></common:assertion-origin-client-id><common:assertion-origin-name>Origin</common:assertion-origin-name></common:source><common:external-id-type>doi</common:external-id-type><common:external-id-value>X</common:external-id-value><common:external-id-normalized transient="true">x</common:external-id-normalized><common:external-id-normalized-error transient="true"><common:error-code>8001</common:error-code><common:error-message>m</common:error-message></common:external-id-normalized-error></external-identifier:external-identifier></external-identifier:external-identifiers><keyword:keywords><keyword:keyword put-code="8"><keyword:content>k</keyword:content></keyword:keyword></keyword:keywords></person:person>
    ;
    var t = try tables(xml);
    defer t.deinit();
    const pi = Section.person_items;
    const x = findRow(&t, pi, "kind", "external-identifier") orelse return error.TestMissingItem;
    try expectRow(&t, pi, x, &.{
        "assertion_origin_name", "assertion_origin_orcid", "assertion_origin_client_id", "normalized", "normalized_error", "normalized_error_code",
    }, &.{ "Origin", "0000-0003-0100-6634", "APP-1", "x", "m", "8001" });
    const k = findRow(&t, pi, "kind", "keyword") orelse return error.TestMissingItem;
    for ([_][]const u8{ "normalized", "normalized_error", "normalized_error_code" }) |c| try expectCell("<null>", &t, pi, k, c);
    // a standalone person: no record orcid-identifier
    try testing.expectEqual(@as(usize, 1), t.count(.person));
    try expectCell("<null>", &t, .person, 0, "orcid_uri");
    try expectCell("<null>", &t, .person, 0, "orcid_host");

    // contributor_orcid_host from contributor-orcid/host
    var w = try tables(fixtures.readSample("work-full-3.0.xml"));
    defer w.deinit();
    try testing.expect(w.count(.contributors) > 0);
    var a: [512]u8 = undefined;
    for (0..w.count(.contributors)) |r| {
        const has_id = !std.mem.eql(u8, get(&a, &w, .contributors, r, "contributor_orcid"), "<null>");
        if (has_id) try expectCell("orcid.org", &w, .contributors, r, "contributor_orcid_host");
    }
}

// ------------------------------------------------------- sizing and copies

/// Every row list ends exactly at the capacity counted before the walk.
fn expectExactSizes(t: *const Tables, label: []const u8) !void {
    for (Section.all, &t.rows) |s, *list| {
        if (list.items.len != list.capacity) {
            std.debug.print("{s}: {s} has {d} rows, {d} counted\n", .{ label, s.name(), list.items.len, list.capacity });
            return error.TestRowCountDiffers;
        }
    }
}

fn expectSameCell(want: rows.Cell, got: rows.Cell) !void {
    try testing.expectEqual(std.meta.activeTag(want), std.meta.activeTag(got));
    switch (want) {
        .varchar => |s| try testing.expectEqualStrings(s, got.varchar),
        else => try testing.expectEqual(want, got),
    }
}

fn expectSameTables(want: *const Tables, got: *const Tables) !void {
    for (Section.all) |s| {
        try testing.expectEqual(want.count(s), got.count(s));
        for (want.get(s), got.get(s)) |wr, gr| {
            for (wr, gr) |wc, gc| try expectSameCell(wc, gc);
        }
    }
}

test "rows are counted exactly before they are built" {
    for ([_][]const fixtures.File{ &fixtures.read_samples, &fixtures.write_samples }) |set| {
        for (set) |f| {
            if (!support.isXml(f)) continue;
            var doc = try yorc.xml.parse(gpa, f.data, .{}, null);
            defer doc.deinit();
            var t = try Tables.fromDocument(gpa, &doc, "h");
            defer t.deinit();
            try expectExactSizes(&t, f.name);
        }
    }
    var t = try tables(fixtures.real_record);
    defer t.deinit();
    try expectExactSizes(&t, "0000-0003-0100-6634.xml");
}

test "rows of the record read from JSON: the same sizes, and they outlive the document" {
    var xml_doc = try yorc.xml.parse(gpa, fixtures.real_record, .{}, null);
    defer xml_doc.deinit();
    const j = try yorc.json.toOwned(gpa, &xml_doc.root, null);
    defer gpa.free(j);

    var doc = try yorc.json.parse(gpa, "record", j, null);
    var doc_alive = true;
    defer if (doc_alive) doc.deinit();
    var t = try Tables.fromDocument(gpa, &doc, fixture_hash);
    defer t.deinit();
    try expectExactSizes(&t, "record from JSON");
    // the document's memory is gone (and overwritten by the testing allocator)
    doc.deinit();
    doc_alive = false;

    var again = try yorc.json.parse(gpa, "record", j, null);
    defer again.deinit();
    var want = try Tables.fromDocument(gpa, &again, fixture_hash);
    defer want.deinit();
    try expectSameTables(&want, &t);
    try testing.expectEqualSlices(usize, &.{ 382, 7, 79, 2, 0, 0, 0, 864, 1, 49, 1, 0, 0, 0 }, &counts(&t));
}

test "tables copy document text, including vocabulary values outside the vocabulary" {
    const buf = try gpa.dupe(u8, "new-type/0000-0002-1825-0097/title");
    defer gpa.free(buf);
    const doc: yorc.Document = .{ .root_name = "work", .root = .{ .work = .{
        .meta = .{ .put_code = 1, .path = buf[8..] },
        .work_type = .{ .other = buf[0..8] },
        .title = .{ .title = buf[29..] },
        .publication_date = .{ .year = 2001 },
    } } };
    var t = try Tables.fromDocument(gpa, &doc, "h");
    defer t.deinit();
    @memset(buf, 'X');
    try expectCell("new-type", &t, .works, 0, "type");
    try expectCell("0000-0002-1825-0097", &t, .works, 0, "orcid");
    try expectCell("/0000-0002-1825-0097/title", &t, .works, 0, "path");
    try expectCell("title", &t, .works, 0, "title");
    try expectCell("2001", &t, .works, 0, "pub_year");
    try expectCell("<null>", &t, .works, 0, "pub_month");
    try expectCell("work", &t, .works, 0, "item");
    try expectCell("h", &t, .works, 0, "source_hash");
}

test "many rows and long strings (string chunks, cell blocks)" {
    const n = 3000;
    const long = try gpa.alloc(u8, 100_000);
    defer gpa.free(long);
    for (long, 0..) |*c, i| c.* = 'a' + @as(u8, @intCast(i % 26));
    const works = try gpa.alloc(yorc.model.Work, n);
    defer gpa.free(works);
    const items = try gpa.alloc(yorc.model.BulkItem, n);
    defer gpa.free(items);
    const ids = [_]yorc.model.ExternalId{
        .{ .id_type = "doi", .value = "10.1/ABC", .relationship = .{ .known = .self } },
        .{ .id_type = "isbn", .value = "1", .relationship = .{ .other = "rel" } },
    };
    for (works, items, 0..) |*w, *it, i| {
        // titles of every length up to 100 000 bytes, across chunk ends
        const len = (i * 7919) % long.len;
        w.* = .{ .meta = .{ .put_code = @as(i64, @intCast(i)) }, .title = .{ .title = long[0..len] }, .external_ids = &ids };
        it.* = .{ .work = w.* };
    }
    const doc: yorc.Document = .{ .root_name = "bulk", .root = .{ .bulk = .{ .items = items } } };
    var t = try Tables.fromDocument(gpa, &doc, null);
    defer t.deinit();
    try expectExactSizes(&t, "bulk");
    try testing.expectEqual(@as(usize, n), t.count(.works));
    try testing.expectEqual(@as(usize, 2 * n), t.count(.external_ids));
    for (0..n) |i| {
        const len = (i * 7919) % long.len;
        const title = t.cell(.works, i, "title").?;
        if (len == 0) {
            try testing.expect(title.asStr().?.len == 0);
        } else try testing.expectEqualSlices(u8, long[0..len], title.asStr().?);
        try testing.expectEqual(@as(?i64, @as(i64, @intCast(i))), t.cell(.works, i, "put_code").?.asInt());
        try testing.expectEqualStrings("10.1/abc", t.cell(.works, i, "doi").?.asStr().?);
        try testing.expect(t.cell(.works, i, "source_hash").?.isNull());
    }
    try expectCell("rel", &t, .external_ids, 1, "relationship");
    try expectCell("self", &t, .external_ids, 0, "relationship");
}

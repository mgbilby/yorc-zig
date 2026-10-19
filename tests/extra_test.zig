//! Group-id records (model, XML and JSON), the `timeline` and `group_ids`
//! sections, the snapshot diff (`rows.changes`), `Tables.take` and
//! `rows.sectionRows`: the expectations of yorc-rs's tests/extra_sections.rs
//! (yorc-duckdb's test/sql/orcid_history_of_record.test and
//! orcid_api_messages.test, and counts derived with python3 -I from a port
//! of yorc-duckdb's extractor over the same files).
const std = @import("std");
const yorc = @import("yorc");
const fixtures = @import("fixtures");
const support = @import("support.zig");

const testing = std.testing;
const gpa = testing.allocator;
const rows = yorc.rows;
const model = yorc.model;
const Extra = rows.Extra;

fn show(buf: []u8, c: ?rows.Cell) []const u8 {
    const x = c orelse return "<no cell>";
    return std.fmt.bufPrint(buf, "{f}", .{x}) catch "<too long>";
}

fn expectCell(want: []const u8, r: *const rows.ExtraRows, row: usize, column: []const u8) !void {
    var buf: [512]u8 = undefined;
    const got = show(&buf, r.cell(row, column));
    if (!std.mem.eql(u8, want, got)) {
        std.debug.print("{s}[{d}].{s}: expected \"{s}\", got \"{s}\"\n", .{ r.extra.name(), row, column, want, got });
        return error.TestUnexpectedCell;
    }
}

fn countWhere(r: *const rows.ExtraRows, column: []const u8, value: []const u8) usize {
    var buf: [512]u8 = undefined;
    var n: usize = 0;
    for (0..r.rows.len) |i| {
        if (std.mem.eql(u8, show(&buf, r.cell(i, column)), value)) n += 1;
    }
    return n;
}

fn parse(xml: []const u8) !yorc.Document {
    return yorc.xml.parse(gpa, xml, .{}, null);
}

// ------------------------------------------------------------------ schema

test "extra schemas match yorc-duckdb" {
    const timeline_names = [_][]const u8{ "orcid", "event_at", "event", "kind", "put_code", "label", "organization", "visibility", "source_name", "created", "last_modified", "path", "source_hash" };
    for (Extra.timeline.columns(), timeline_names) |c, n| try testing.expectEqualStrings(n, c.name);
    try testing.expectEqual(timeline_names.len, Extra.timeline.columns().len);
    const group_names = [_][]const u8{ "put_code", "name", "group_id", "description", "type", "source_name", "source_client_id", "source_orcid", "total", "page", "page_size", "source_hash" };
    for (Extra.group_ids.columns(), group_names) |c, n| try testing.expectEqualStrings(n, c.name);
    try testing.expectEqual(group_names.len, Extra.group_ids.columns().len);
    try testing.expectEqual(rows.ColType.bigint, Extra.group_ids.columns()[0].ty);
    try testing.expectEqual(rows.ColType.integer, Extra.group_ids.columns()[8].ty);
    try testing.expectEqual(rows.ColType.bigint, Extra.timeline.columns()[4].ty);
    const change_names = [_][]const u8{ "orcid", "section", "kind", "put_code", "change", "field", "old_value", "new_value", "label" };
    for (rows.change_columns, change_names) |c, n| try testing.expectEqualStrings(n, c.name);
    // the fourteen sections are unchanged
    var width: usize = 0;
    for (rows.Section.all) |s| width += s.columns().len;
    try testing.expectEqual(@as(usize, 14), rows.Section.all.len);
    try testing.expectEqual(@as(usize, 300), width);
}

// --------------------------------------------------------------- group ids

test "group-id sample: model, rows, XML written back" {
    var doc = try parse(fixtures.group_id_sample);
    defer doc.deinit();
    const g = doc.root.group_id_record;
    try testing.expectEqualStrings("group-id:name", g.name.?);
    try testing.expectEqualStrings("issn:xxxxxxxx", g.group_id.?);
    try testing.expectEqualStrings("group-id:description", g.description.?);
    try testing.expect(g.group_type.?.is(.publisher));
    try testing.expect(g.put_code == null and g.source == null);

    // orcid_api_messages.test: put_code, name, group_id, description, type,
    // source_name, total of orcid_group_ids('.../group-id-3.0.xml')
    var r = try rows.extraFromXml(gpa, .group_ids, fixtures.group_id_sample);
    defer r.deinit();
    try testing.expectEqual(@as(usize, 1), r.rows.len);
    try expectCell("<null>", &r, 0, "put_code");
    try expectCell("group-id:name", &r, 0, "name");
    try expectCell("issn:xxxxxxxx", &r, 0, "group_id");
    try expectCell("group-id:description", &r, 0, "description");
    try expectCell("publisher", &r, 0, "type");
    try expectCell("<null>", &r, 0, "source_name");
    try expectCell("<null>", &r, 0, "total");
    const h = yorc.hash.sha256Hex(fixtures.group_id_sample);
    try expectCell(&h, &r, 0, "source_hash");

    var tl = try rows.timeline(gpa, &doc, null);
    defer tl.deinit();
    try testing.expectEqual(@as(usize, 0), tl.rows.len);

    const xml = try yorc.xml.toOwned(gpa, &doc.root, null);
    defer gpa.free(xml);
    try testing.expectEqualStrings(
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n" ++
            "<group-id:group-id-record xmlns:group-id=\"http://www.orcid.org/ns/group-id\">\n" ++
            "  <group-id:name>group-id:name</group-id:name>\n" ++
            "  <group-id:group-id>issn:xxxxxxxx</group-id:group-id>\n" ++
            "  <group-id:description>group-id:description</group-id:description>\n" ++
            "  <group-id:type>publisher</group-id:type>\n" ++
            "</group-id:group-id-record>\n",
        xml,
    );
    var again = try parse(xml);
    defer again.deinit();
    try testing.expect(model.eql(doc.root, again.root));
}

test "group-id-records page" {
    var r = try rows.extraFromXml(gpa, .group_ids, fixtures.group_id_records);
    defer r.deinit();
    // orcid_api_messages.test (ORDER BY put_code)
    try testing.expectEqual(@as(usize, 2), r.rows.len);
    const want = [_][9][]const u8{
        .{ "11", "A", "issn:0000-0001", "journal", "APP-1", "Client", "2", "0", "100" },
        .{ "12", "B", "issn:0000-0002", "conference", "<null>", "<null>", "2", "0", "100" },
    };
    const cols = [_][]const u8{ "put_code", "name", "group_id", "type", "source_client_id", "source_name", "total", "page", "page_size" };
    for (want, 0..) |line, i| {
        for (line, cols) |v, c| try expectCell(v, &r, i, c);
    }
    try expectCell("Second", &r, 1, "description");

    var doc = try parse(fixtures.group_id_records);
    defer doc.deinit();
    const pg = doc.root.group_id_records;
    try testing.expectEqual(@as(?i64, 2), pg.total);
    try testing.expectEqual(@as(?i64, 0), pg.page);
    try testing.expectEqual(@as(?i64, 100), pg.page_size);
    try testing.expectEqualStrings("APP-1", pg.records[0].source.?.source_client_id.?.path.?);
    try testing.expect(pg.records[1].source == null);

    const xml = try yorc.xml.toOwned(gpa, &doc.root, null);
    defer gpa.free(xml);
    try testing.expectEqualStrings(
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n" ++
            "<group-id:group-id-records xmlns:common=\"http://www.orcid.org/ns/common\" xmlns:group-id=\"http://www.orcid.org/ns/group-id\">\n" ++
            "  <group-id:total>2</group-id:total>\n" ++
            "  <group-id:page>0</group-id:page>\n" ++
            "  <group-id:page-size>100</group-id:page-size>\n" ++
            "  <group-id:group-id-record put-code=\"11\">\n" ++
            "    <group-id:name>A</group-id:name>\n" ++
            "    <group-id:group-id>issn:0000-0001</group-id:group-id>\n" ++
            "    <group-id:description>First</group-id:description>\n" ++
            "    <group-id:type>journal</group-id:type>\n" ++
            "    <common:source>\n" ++
            "      <common:source-client-id>\n" ++
            "        <common:path>APP-1</common:path>\n" ++
            "      </common:source-client-id>\n" ++
            "      <common:source-name>Client</common:source-name>\n" ++
            "    </common:source>\n" ++
            "  </group-id:group-id-record>\n" ++
            "  <group-id:group-id-record put-code=\"12\">\n" ++
            "    <group-id:name>B</group-id:name>\n" ++
            "    <group-id:group-id>issn:0000-0002</group-id:group-id>\n" ++
            "    <group-id:description>Second</group-id:description>\n" ++
            "    <group-id:type>conference</group-id:type>\n" ++
            "  </group-id:group-id-record>\n" ++
            "</group-id:group-id-records>\n",
        xml,
    );
    var again = try parse(xml);
    defer again.deinit();
    try testing.expect(model.eql(doc.root, again.root));

    // write into any writer: the same bytes
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try yorc.xml.write(&aw.writer, &doc.root, null);
    try testing.expectEqualStrings(xml, aw.written());
}

test "group-id dates, escaping and errors" {
    const root: model.Root = .{ .group_id_record = .{
        .put_code = 7,
        .created_date = "2020-01-01T00:00:00.000Z",
        .last_modified_date = "2021-01-01T00:00:00.000Z",
        .name = "R&D <x>",
        .group_type = .{ .known = .@"peer-review service" },
    } };
    const xml = try yorc.xml.toOwned(gpa, &root, null);
    defer gpa.free(xml);
    // ORCID's GroupIdRecord propOrder: last-modified-date before created-date
    try testing.expectEqualStrings(
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n" ++
            "<group-id:group-id-record xmlns:common=\"http://www.orcid.org/ns/common\" xmlns:group-id=\"http://www.orcid.org/ns/group-id\" put-code=\"7\">\n" ++
            "  <common:last-modified-date>2021-01-01T00:00:00.000Z</common:last-modified-date>\n" ++
            "  <common:created-date>2020-01-01T00:00:00.000Z</common:created-date>\n" ++
            "  <group-id:name>R&amp;D &lt;x&gt;</group-id:name>\n" ++
            "  <group-id:type>peer-review service</group-id:type>\n" ++
            "</group-id:group-id-record>\n",
        xml,
    );
    const empty: model.Root = .{ .group_id_record = .{} };
    const e = try yorc.xml.toOwned(gpa, &empty, null);
    defer gpa.free(e);
    try testing.expectEqualStrings("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<group-id:group-id-record xmlns:group-id=\"http://www.orcid.org/ns/group-id\"/>\n", e);
    var d: yorc.Diagnostic = .{};
    const bad: model.Root = .{ .group_id_record = .{ .description = "bell\x07" } };
    try testing.expectError(error.Unwritable, yorc.xml.toOwned(gpa, &bad, &d));
    try testing.expectEqualStrings("group-id-record/description", d.path());
    // nothing reaches the writer
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try testing.expectError(error.Unwritable, yorc.xml.write(&aw.writer, &bad, null));
    try testing.expectEqual(@as(usize, 0), aw.written().len);
}

test "group-id JSON" {
    var doc = try yorc.json.parse(gpa, "group-id-record", fixtures.writeSample("peer-review-group-id.json"), null);
    defer doc.deinit();
    const g = doc.root.group_id_record;
    try testing.expectEqualStrings("Group ID name", g.name.?);
    try testing.expectEqualStrings("ringgold:355321", g.group_id.?);
    try testing.expectEqualStrings("Description for a peer-review group id.", g.description.?);
    try testing.expect(g.group_type.?.is(.magazine));
    try testing.expectEqualStrings("group-id-record", doc.root.kind().?);
    const json = try yorc.json.toOwned(gpa, &doc.root, null);
    defer gpa.free(json);
    try testing.expectEqualStrings(
        "{\n  \"description\": \"Description for a peer-review group id.\",\n  \"group-id\": \"ringgold:355321\",\n  \"name\": \"Group ID name\",\n  \"type\": \"magazine\"\n}\n",
        json,
    );
    var r = try rows.groupIds(gpa, &doc, "h");
    defer r.deinit();
    try expectCell("magazine", &r, 0, "type");
    try expectCell("h", &r, 0, "source_hash");

    // the page through JSON and back; the record's dates are XML-only
    var page = try parse(fixtures.group_id_records);
    defer page.deinit();
    const pj = try yorc.json.toOwned(gpa, &page.root, null);
    defer gpa.free(pj);
    var back = try yorc.json.parse(gpa, "group-id-records", pj, null);
    defer back.deinit();
    try testing.expect(model.eql(page.root, back.root));
    const dated: model.Root = .{ .group_id_record = .{ .created_date = "2020-01-01T00:00:00.000Z" } };
    const dj = try yorc.json.toOwned(gpa, &dated, null);
    defer gpa.free(dj);
    try testing.expectEqualStrings("{}\n", dj);
    // inline source keys, as the XSD's source-type has them
    var inl = try yorc.json.parse(gpa, "group-id-record", "{\"source-name\": {\"value\": \"Client\"}, \"put-code\": 3}", null);
    defer inl.deinit();
    try testing.expectEqualStrings("Client", inl.root.group_id_record.source.?.source_name.?);
    try testing.expectEqual(@as(?i64, 3), inl.root.group_id_record.put_code);
}

// ---------------------------------------------------------------- timeline

test "timeline of the record sample" {
    var r = try rows.extraFromXml(gpa, .timeline, fixtures.readSample("record-3.0.xml"));
    defer r.deinit();
    // orcid_history_of_record.test: 20 rows, 18 created, 2 modified, 19 kinds
    try testing.expectEqual(@as(usize, 20), r.rows.len);
    try testing.expectEqual(@as(usize, 18), countWhere(&r, "event", "created"));
    try testing.expectEqual(@as(usize, 2), countWhere(&r, "event", "modified"));
    // document order (python3 -I, the extractor port), with the kinds
    const kinds = [_][]const u8{ "name", "other-name", "biography", "researcher-url", "email", "address", "keyword", "external-identifier", "distinction", "education", "employment", "funding", "invited-position", "membership", "peer-review", "qualification", "research-resource", "research-resource", "service", "work" };
    for (kinds, 0..) |k, i| try expectCell(k, &r, i, "kind");
    try expectCell("modified", &r, 0, "event");
    try expectCell("give-names", &r, 0, "label");
    try expectCell("employment:role-title", &r, 10, "label");
    try expectCell("keyword1", &r, 6, "label");
    try expectCell("biography", &r, 2, "label");
    // ... WHERE event_at > '2002' ORDER BY event_at
    try expectCell("2015-06-25T16:01:12.718Z", &r, 16, "event_at");
    try expectCell("created", &r, 16, "event");
    try expectCell("Giant Laser Award", &r, 16, "label");
    try expectCell("2017-09-08T13:31:19.987Z", &r, 17, "event_at");
    try expectCell("modified", &r, 17, "event");
    try expectCell("1234", &r, 16, "put_code");
    try expectCell("XSEDE", &r, 16, "organization");
    try expectCell("XSEDE ORCID integration", &r, 16, "source_name");
    try expectCell("public", &r, 16, "visibility");
    try expectCell("/0000-0003-0902-4386/research-resource/1234", &r, 16, "path");
    try expectCell("8888-8888-8888-8880", &r, 16, "orcid");
    try expectCell("common:title", &r, 11, "label");
    try expectCell("common:name", &r, 11, "organization");
    try expectCell("<null>", &r, 14, "label");
    try expectCell("common:name", &r, 14, "organization");
}

const Expected = struct { set: []const u8, name: []const u8, rows: usize, created: usize, undated: usize };

test "timeline rows per sample" {
    // python3 -I, the extractor port over every sample; every other XML
    // sample has none
    const expected = [_]Expected{
        .{ .set = "read", .name = "activities-3.0.xml", .rows = 12, .created = 11, .undated = 0 },
        .{ .set = "read", .name = "addresses-3.0.xml", .rows = 2, .created = 2, .undated = 0 },
        .{ .set = "read", .name = "bulk-work-err.xml", .rows = 1, .created = 1, .undated = 0 },
        .{ .set = "read", .name = "distinction-3.0.xml", .rows = 1, .created = 1, .undated = 0 },
        .{ .set = "read", .name = "distinctions-3.0.xml", .rows = 2, .created = 2, .undated = 0 },
        .{ .set = "read", .name = "education-3.0.xml", .rows = 1, .created = 1, .undated = 0 },
        .{ .set = "read", .name = "education-full-3.0.xml", .rows = 1, .created = 1, .undated = 0 },
        .{ .set = "read", .name = "educations-3.0.xml", .rows = 2, .created = 2, .undated = 0 },
        .{ .set = "read", .name = "emails-3.0.xml", .rows = 2, .created = 2, .undated = 0 },
        .{ .set = "read", .name = "employment-3.0.xml", .rows = 1, .created = 1, .undated = 0 },
        .{ .set = "read", .name = "employment-full-3.0.xml", .rows = 1, .created = 1, .undated = 0 },
        .{ .set = "read", .name = "employments-3.0.xml", .rows = 2, .created = 2, .undated = 0 },
        .{ .set = "read", .name = "external-identifiers-3.0.xml", .rows = 2, .created = 2, .undated = 0 },
        .{ .set = "read", .name = "funding-3.0.xml", .rows = 1, .created = 1, .undated = 0 },
        .{ .set = "read", .name = "funding-full-3.0.xml", .rows = 1, .created = 1, .undated = 0 },
        .{ .set = "read", .name = "fundings-3.0.xml", .rows = 6, .created = 3, .undated = 0 },
        .{ .set = "read", .name = "invited-position-3.0.xml", .rows = 1, .created = 1, .undated = 0 },
        .{ .set = "read", .name = "invited-positions-3.0.xml", .rows = 2, .created = 2, .undated = 0 },
        .{ .set = "read", .name = "keywords-3.0.xml", .rows = 2, .created = 2, .undated = 0 },
        .{ .set = "read", .name = "membership-3.0.xml", .rows = 1, .created = 1, .undated = 0 },
        .{ .set = "read", .name = "memberships-3.0.xml", .rows = 2, .created = 2, .undated = 0 },
        .{ .set = "read", .name = "other-names-3.0.xml", .rows = 2, .created = 2, .undated = 0 },
        .{ .set = "read", .name = "peer-review-3.0.xml", .rows = 1, .created = 1, .undated = 0 },
        .{ .set = "read", .name = "peer-review-full-3.0.xml", .rows = 1, .created = 1, .undated = 0 },
        .{ .set = "read", .name = "person-3.0.xml", .rows = 8, .created = 8, .undated = 0 },
        .{ .set = "read", .name = "personal-details-3.0.xml", .rows = 4, .created = 3, .undated = 1 },
        .{ .set = "read", .name = "qualification-3.0.xml", .rows = 1, .created = 1, .undated = 0 },
        .{ .set = "read", .name = "qualifications-3.0.xml", .rows = 2, .created = 2, .undated = 0 },
        .{ .set = "read", .name = "record-3.0.xml", .rows = 20, .created = 18, .undated = 0 },
        .{ .set = "read", .name = "record-no-city-country-for-professional-activities-3.0.xml", .rows = 20, .created = 18, .undated = 0 },
        .{ .set = "read", .name = "research-resource-3.0.xml", .rows = 2, .created = 1, .undated = 0 },
        .{ .set = "read", .name = "research-resources-3.0.xml", .rows = 4, .created = 2, .undated = 0 },
        .{ .set = "read", .name = "researcher-urls-3.0.xml", .rows = 1, .created = 1, .undated = 0 },
        .{ .set = "read", .name = "service-3.0.xml", .rows = 1, .created = 1, .undated = 0 },
        .{ .set = "read", .name = "services-3.0.xml", .rows = 2, .created = 2, .undated = 0 },
        .{ .set = "read", .name = "work-3.0.xml", .rows = 1, .created = 1, .undated = 0 },
        .{ .set = "read", .name = "work-full-3.0.xml", .rows = 1, .created = 1, .undated = 0 },
        .{ .set = "read", .name = "work-review-3.0.xml", .rows = 1, .created = 1, .undated = 0 },
        .{ .set = "read", .name = "works-3.0.xml", .rows = 5, .created = 3, .undated = 0 },
        .{ .set = "write", .name = "bulk-work-3.0.xml", .rows = 2, .created = 0, .undated = 2 },
        .{ .set = "write", .name = "distinction-3.0.xml", .rows = 1, .created = 0, .undated = 1 },
        .{ .set = "write", .name = "education-3.0.xml", .rows = 1, .created = 0, .undated = 1 },
        .{ .set = "write", .name = "employment-3.0.xml", .rows = 1, .created = 0, .undated = 1 },
        .{ .set = "write", .name = "funding-3.0.xml", .rows = 1, .created = 0, .undated = 1 },
        .{ .set = "write", .name = "invited-position-3.0.xml", .rows = 1, .created = 0, .undated = 1 },
        .{ .set = "write", .name = "membership-3.0.xml", .rows = 1, .created = 0, .undated = 1 },
        .{ .set = "write", .name = "peer-review-full-3.0.xml", .rows = 1, .created = 0, .undated = 1 },
        .{ .set = "write", .name = "peer-review-full-award-subject-type-3.0.xml", .rows = 1, .created = 0, .undated = 1 },
        .{ .set = "write", .name = "peer-review-simple-3.0.xml", .rows = 1, .created = 0, .undated = 1 },
        .{ .set = "write", .name = "qualification-3.0.xml", .rows = 1, .created = 0, .undated = 1 },
        .{ .set = "write", .name = "research-resource-3.0.xml", .rows = 1, .created = 0, .undated = 1 },
        .{ .set = "write", .name = "service-3.0.xml", .rows = 1, .created = 0, .undated = 1 },
        .{ .set = "write", .name = "work-full-3.0.xml", .rows = 1, .created = 0, .undated = 1 },
        .{ .set = "write", .name = "work-simple-3.0.xml", .rows = 1, .created = 0, .undated = 1 },
    };
    var seen: usize = 0;
    for ([_][]const u8{ "read", "write" }, [_][]const fixtures.File{ &fixtures.read_samples, &fixtures.write_samples }) |set, files| {
        for (files) |f| {
            if (!support.isXml(f)) continue;
            var r = try rows.extraFromXml(gpa, .timeline, f.data);
            defer r.deinit();
            const got = [3]usize{ r.rows.len, countWhere(&r, "event", "created"), countWhere(&r, "event", "<null>") };
            var want = [3]usize{ 0, 0, 0 };
            for (expected) |e| {
                if (std.mem.eql(u8, e.set, set) and std.mem.eql(u8, e.name, f.name)) {
                    want = .{ e.rows, e.created, e.undated };
                    seen += 1;
                }
            }
            if (!std.mem.eql(usize, &want, &got)) {
                std.debug.print("{s}/{s}: expected {any}, got {any}\n", .{ set, f.name, want, got });
                return error.TestUnexpectedTimeline;
            }
        }
    }
    try testing.expectEqual(expected.len, seen);
}

test "timeline of the real record" {
    var r = try rows.extraFromXml(gpa, .timeline, fixtures.real_record);
    defer r.deinit();
    // orcid_history_of_record.test: at least 382 work rows; exact counts
    // from python3 -I (the extractor port over the record)
    try testing.expectEqual(@as(usize, 679), countWhere(&r, "kind", "work"));
    try testing.expectEqual(@as(usize, 940), r.rows.len);
    try testing.expectEqual(@as(usize, 521), countWhere(&r, "event", "created"));
    try testing.expectEqual(@as(usize, 419), countWhere(&r, "event", "modified"));
    try testing.expectEqual(@as(usize, 54), countWhere(&r, "kind", "service"));
    try testing.expectEqual(@as(usize, 39), countWhere(&r, "kind", "keyword"));
    try testing.expectEqual(@as(usize, 2), countWhere(&r, "kind", "name"));
    try testing.expectEqual(@as(usize, 940), countWhere(&r, "orcid", "0000-0003-0100-6634"));
}

// ----------------------------------------------------------------- changes

/// The change rows without the orcid, `|`-joined, NULL as `NULL`.
fn changeLines(a: std.mem.Allocator, c: []const rows.Change) ![]const []const u8 {
    const out = try a.alloc([]const u8, c.len);
    for (c, out) |*ch, *line| {
        var aw: std.Io.Writer.Allocating = .init(a);
        const cells = ch.cells();
        for (cells[1..], 0..) |cell, i| {
            if (i > 0) try aw.writer.writeByte('|');
            if (cell == .null) try aw.writer.writeAll("NULL") else try aw.writer.print("{f}", .{cell});
        }
        line.* = aw.written();
    }
    return out;
}

test "changes between two snapshots" {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var old = try parse(fixtures.changes_old);
    defer old.deinit();
    var new = try parse(fixtures.changes_new);
    defer new.deinit();
    // orcid_history_of_record.test: orcid_changes(old, new)
    var c = try rows.changes(gpa, &old, &new);
    defer c.deinit();
    const want = [_][]const u8{
        "person|NULL|NULL|modified|given_names|give-names|given-names|given-names",
        "person_items|keyword|2|added|NULL|NULL|NULL|keyword2",
        "works|NULL|0|modified|title|common:title|Revised title|Revised title",
        "fundings|NULL|0|removed|NULL|NULL|NULL|common:title",
        "affiliations|employment|0|modified|role_title|employment:role-title|Senior employment:role-title|Senior employment:role-title",
    };
    const got = try changeLines(a, c.items);
    try testing.expectEqual(want.len, got.len);
    for (want, got) |w, g| try testing.expectEqualStrings(w, g);
    for (c.items) |ch| try testing.expectEqualStrings("8888-8888-8888-8880", ch.orcid.?);

    // identical snapshots: no changes
    var same = try rows.changes(gpa, &old, &old);
    defer same.deinit();
    try testing.expectEqual(@as(usize, 0), same.items.len);
    // reversing the direction swaps added/removed
    var rev = try rows.changes(gpa, &new, &old);
    defer rev.deinit();
    var added: usize = 0;
    var removed: usize = 0;
    for (rev.items) |ch| switch (ch.change) {
        .added => {
            added += 1;
            try testing.expectEqual(rows.Section.fundings, ch.section);
        },
        .removed => {
            removed += 1;
            try testing.expectEqual(rows.Section.person_items, ch.section);
        },
        .modified => {},
    };
    try testing.expectEqual(@as(usize, 1), added);
    try testing.expectEqual(@as(usize, 1), removed);
    // no old snapshot: everything on the new side is added
    var all = try rows.changes(gpa, null, &new);
    defer all.deinit();
    try testing.expectEqual(@as(usize, 19), all.items.len);
    for (all.items) |ch| try testing.expectEqual(rows.ChangeKind.added, ch.change);
    var none = try rows.changes(gpa, null, null);
    defer none.deinit();
    try testing.expectEqual(@as(usize, 0), none.items.len);
}

test "changes of an edited work (the bench's changes_record pair)" {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const f = fixtures.real_record;
    const tag = "<common:title>";
    const at = std.mem.indexOfPos(u8, f, std.mem.indexOf(u8, f, "<work:work-summary").?, tag).? + tag.len;
    const edited = try std.mem.concat(a, u8, &.{ f[0..at], "Edited: ", f[at..] });
    var old = try parse(f);
    defer old.deinit();
    var new = try parse(edited);
    defer new.deinit();
    var c = try rows.changes(gpa, &old, &new);
    defer c.deinit();
    const got = try changeLines(a, c.items);
    try testing.expectEqual(@as(usize, 1), got.len);
    try testing.expectEqualStrings("works|NULL|182082411|modified|title|mgbilby/oga_src: initial oga_src release|Edited: mgbilby/oga_src: initial oga_src release|Edited: mgbilby/oga_src: initial oga_src release", got[0]);
}

// ------------------------------------------------------- take, sectionRows

test "Tables.take and sectionRows" {
    var doc = try parse(fixtures.readSample("record-3.0.xml"));
    defer doc.deinit();
    var t = try rows.Tables.fromDocument(gpa, &doc, "h");
    defer t.deinit();
    const n = t.count(.affiliations);
    try testing.expectEqual(@as(usize, 7), n);
    const taken = t.take(.affiliations);
    try testing.expectEqual(n, taken.len);
    try testing.expectEqual(@as(usize, 0), t.count(.affiliations));
    try testing.expectEqual(@as(usize, 1), t.count(.works));
    var s = try rows.sectionRows(gpa, &doc, .affiliations, "h");
    defer s.deinit();
    try testing.expectEqual(n, s.rows.len);
    try testing.expectEqual(@as(usize, 0), s.tables.count(.affiliations));
}

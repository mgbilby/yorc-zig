//! Pins WALKTHROUGH.md: runs the walkthrough cells 0 to 8
//! (examples/walkthrough.zig, module `walkthrough`) over the package's input
//! files, recreated from the embedded fixtures in a temporary directory, and
//! compares each cell's output with the "Expected output" block of
//! WALKTHROUGH.md. Cell 9 calls the ORCID API and is not run here.
const std = @import("std");
const fixtures = @import("fixtures");
const wt = @import("walkthrough");

const testing = std.testing;

/// Writes the walkthrough's inputs under `dir`, at their package paths.
fn writeInputs(dir: std.Io.Dir) !void {
    const io = testing.io;
    const inputs = [_]struct { []const u8, []const u8 }{
        .{ wt.paths.record, fixtures.demo_record },
        .{ wt.paths.sample_record, fixtures.readSample("record-3.0.xml") },
        .{ wt.paths.work_full_read, fixtures.readSample("work-full-3.0.xml") },
        .{ wt.paths.work_full_write, fixtures.writeSample("work-full-3.0.xml") },
        .{ wt.paths.work_full_json, fixtures.writeSample("work-full-3.0.json") },
        .{ wt.paths.dump, fixtures.dump_tgz },
    };
    try testing.expectEqual(wt.paths.all.len, inputs.len);
    for (inputs) |f| {
        if (std.fs.path.dirname(f[0])) |parent| try dir.createDirPath(io, parent);
        try dir.writeFile(io, .{ .sub_path = f[0], .data = f[1] });
    }
}

/// Runs cell `n` and compares what it writes with `want`.
fn expectCell(n: usize, want: []const u8) !void {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeInputs(tmp.dir);
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try wt.cells[n].run(.{ .gpa = testing.allocator, .io = testing.io, .root = tmp.dir, .out = &aw.writer });
    try testing.expectEqualStrings(want, aw.written());
}

test "walkthrough: ten cells, the last one is the network cell" {
    try testing.expectEqual(@as(usize, 10), wt.cells.len);
    try testing.expectEqual(@as(usize, 9), wt.network_cell);
}

test "walkthrough cell 0: setup" {
    try expectCell(0,
        \\inputs, relative to the package root:
        \\  testdata/0000-0002-2771-9344.xml  45543 bytes
        \\  testdata/record_3.0/samples/read_samples/record-3.0.xml  36958 bytes
        \\  testdata/record_3.0/samples/read_samples/work-full-3.0.xml  2922 bytes
        \\  testdata/record_3.0/samples/write_samples/work-full-3.0.xml  2500 bytes
        \\  testdata/record_3.0/samples/write_samples/work-full-3.0.json  2358 bytes
        \\  testdata/dump/orcid_test_summaries.tgz  64616 bytes
        \\allocator: std.process.Init.gpa, io: std.process.Init.io
        \\
    );
}

test "walkthrough cell 1: ORCID iDs" {
    try expectCell(1,
        \\"0000-0002-1825-0097" -> 0000-0002-1825-0097 (https://orcid.org/0000-0002-1825-0097)
        \\"0000-0002-1825-0098" -> invalid (error.InvalidOrcidId)
        \\"https://orcid.org/000000021694233x" -> 0000-0002-1694-233X (https://orcid.org/0000-0002-1694-233X)
        \\" 0000 0002 2771 9344 " -> 0000-0002-2771-9344 (https://orcid.org/0000-0002-2771-9344)
        \\check character of 0000-0002-1825-009?: 7
        \\more forms:
        \\  "orcid.org/0000000218250097" -> 0000-0002-1825-0097
        \\  "HTTPS://ORCID.ORG/0000-0002-1825-0097" -> invalid (error.InvalidOrcidId)
        \\  "0000-0002-1825-009" -> invalid (error.InvalidOrcidId)
        \\
    );
}

test "walkthrough cell 2: record summary" {
    try expectCell(2,
        \\iD: 0000-0002-2771-9344
        \\sha256: 59018b6d315be538bb84a6105ff3ac1c4c274f3b467a455eb2576e03bbc2f86e
        \\name: Sofia Hernandez
        \\credit name: Sofia Maria Garcia Hernandez
        \\works: 12
        \\fundings: 0
        \\affiliations: 0
        \\peer reviews: 0
        \\
    );
}

test "walkthrough cell 3: newest works" {
    try expectCell(3,
        \\12 works; the 10 newest (publication date, newest first, then put-code):
        \\2026-08-17  data-set         10.25592/uhhfdm.19102      Point cloud calorimeter shower datasets for multi-geometry pre-training: SimpleBox and LEMURS
        \\2026-08-17  data-set         10.25592/uhhfdm.19103      Point cloud calorimeter shower datasets for multi-geometry pre-training: SimpleBox and LEMURS
        \\2026-08-17  data-set         10.25592/uhhfdm.19102      Point cloud calorimeter shower datasets for multi-geometry pre-training: SimpleBox and LEMURS
        \\2017-03-28  other            10.5281/zenodo.495149      Introducing Orcid
        \\2017        other            10.6084/m9.figshare.5479792.v1  ORCID Public Data File 2017
        \\2016-11-23  other            10.5281/zenodo.168190      Introducing Orcid: What, Why And How
        \\2016        data-set         10.6084/m9.figshare.4134027.v1  ORCID Public Data File 2016
        \\2016        journal-article  10.1002/chemv.201600091    Your Lifelong Digital Name
        \\2015        data-set         10.6084/m9.figshare.1582705  ORCID Public Data File 2015
        \\2014        data-set         10.14454/07243.2014.001    ORCID Annual Public Data File, 2014
        \\
    );
}

test "walkthrough cell 4: JSON work and XML -> JSON -> XML" {
    try expectCell(4,
        \\JSON work: "Work Title", journal-article, published 2022-05-24, 2 external ids
        \\  contributor: Jordan (0000-0002-5391-5437)
        \\  contributor: Fran (0000-0002-4325-871X)
        \\XML -> JSON: kind "work", keys: citation, contributors, country, external-ids, journal-title, language-code, publication-date, short-description, title, type, url
        \\JSON -> XML: same model: true, same XML: true
        \\
    );
}

test "walkthrough cell 5: section tables and CSV" {
    try expectCell(5,
        \\works                      12 rows, 32 columns
        \\fundings                    0 rows, 37 columns
        \\affiliations                0 rows, 32 columns
        \\peer_reviews                0 rows, 38 columns
        \\research_resources          0 rows, 32 columns
        \\research_resource_items     0 rows, 13 columns
        \\contributors                0 rows, 12 columns
        \\external_ids               26 rows, 13 columns
        \\person                      1 rows, 15 columns
        \\person_items                4 rows, 24 columns
        \\history                     1 rows, 17 columns
        \\search_results              0 rows, 13 columns
        \\errors                      0 rows, 10 columns
        \\research_resource_hosts     0 rows, 12 columns
        \\works.csv: a header and 12 rows, built in memory; the first lines:
        \\orcid,put_code,group_index,display_index,title,subtitle,journal,type,pub_year,pub_month,pub_day,doi,url,source_name,visibility,created,last_modified,source_hash,translated_title,translated_title_language,short_description,citation_type,citation_value,language_code,country,path,source_client_id,source_orcid,assertion_origin_name,assertion_origin_orcid,assertion_origin_client_id,item
        \\0000-0002-2771-9344,224052945,1,1,Point cloud calorimeter shower datasets for multi-geometry pre-training: SimpleBox and LEMURS,,Universität Hamburg,data-set,2026,8,17,10.25592/uhhfdm.19102,,DataCite,public,2026-08-17T12:42:27.716Z,2026-08-17T12:42:27.716Z,59018b6d315be538bb84a6105ff3ac1c4c274f3b467a455eb2576e03bbc2f86e,,,,,,,,/0000-0002-2771-9344/work/224052945,0000-0001-8099-6984,,,,,work-summary
        \\0000-0002-2771-9344,224052944,1,1,Point cloud calorimeter shower datasets for multi-geometry pre-training: SimpleBox and LEMURS,,Universität Hamburg,data-set,2026,8,17,10.25592/uhhfdm.19103,,DataCite,public,2026-08-17T12:42:27.716Z,2026-08-17T12:42:27.716Z,59018b6d315be538bb84a6105ff3ac1c4c274f3b467a455eb2576e03bbc2f86e,,,,,,,,/0000-0002-2771-9344/work/224052944,0000-0001-8099-6984,,,,,work-summary
        \\
    );
}

test "walkthrough cell 6: contributors" {
    try expectCell(6,
        \\testdata/record_3.0/samples/read_samples/work-full-3.0.xml: "common:title"
        \\  1. 8888-8888-8888-8880  work:credit-name  email=work@contributor.email  sequence=first  role=author  owner=work/123
        \\testdata/record_3.0/samples/write_samples/work-full-3.0.xml: "Work Title"
        \\  1. 0000-0001-5109-3700  Laure L. Haak  email=<null>  sequence=first  role=author  owner=<null>/<null>
        \\co-authors over both works (distinct contributor iDs): 2
        \\  0000-0001-5109-3700  Laure L. Haak
        \\  8888-8888-8888-8880  work:credit-name
        \\testdata/0000-0002-2771-9344.xml: 0 contributor rows (12 work summaries; contributors come only with full works)
        \\
    );
}

test "walkthrough cell 7: affiliation timeline" {
    try expectCell(7,
        \\2 employment and education entries, oldest first:
        \\1948-02-02  2019-01-01  education   education-org [GRID common:disambiguated-organization-identifier-education]: education:role-title (education:department-name)
        \\1948-02-02  2025        employment  employment-org [GRID common:disambiguated-organization-identifier-employment]: employment:role-title (employment:department-name)
        \\
    );
}

test "walkthrough cell 8: dump and seeded sample" {
    try expectCell(8,
        \\  0000-0003-0100-6634  record  ORCID_test_summaries/634/0000-0003-0100-6634.xml
        \\  8888-8888-8888-8880  record  ORCID_test_summaries/880/8888-8888-8888-8880.xml
        \\  (not an iD)          works   ORCID_test_summaries/a-directory-name-long-enough-to-need-gnu-long-names-or-pax-headers/and-a-file-name-too-0000-0000-0000-0000.xml
        \\members: 8 (4 files, 4 directories); XML members: 3; records: 2
        \\seeded sample, capacity 1, seed 42: 0000-0003-0100-6634 (2 records offered, 1 read)
        \\seeded sample, capacity 1, seed 7: 8888-8888-8888-8880 (2 records offered, 2 read)
        \\
    );
}

# yorc-zig walkthrough

A notebook-like tour of yorc-zig in ten cells. It needs only the pinned
Zig toolchain (`0.18.0-dev.131+41f885830`): no Jupyter, nothing else. Every
input is a file shipped in the package (`testdata/`), and paths are relative
to the package root.

```sh
zig build walkthrough                  # run cells 0 to 8, in order
zig build walkthrough -- 5             # run cell 5 only
zig build walkthrough -- 9 --network   # cell 9: one request to ORCID
```

The program is `examples/walkthrough.zig`, with the `orcid` and
`yorc_client` modules. Each cell is a function (`cell0` ... `cell9`); the
code block of a cell below is that function's body. The program prints
`== Cell N: title ==` before each cell's output. The "Expected output"
blocks show the output that follows that line, exactly, and
`tests/walkthrough_test.zig` (part of `zig build test`) runs cells 0 to 8
and compares their output with these blocks. Cell 9 uses the network and
is not run unless you ask for it, and is not tested.

Every cell receives a `Ctx`, and some call the small helpers listed at the
end (reading a file, building the section tables, counting, dates, CSV).

The record is 0000-0002-2771-9344, a public record that ORCID staff use as an
example (its owner, Sofia Maria Garcia Hernandez, is a fictitious person): 12
works and four other names, but no fundings, affiliations or peer reviews.
Cell 7 therefore reads ORCID's sample record (`record-3.0.xml`) instead.

yorc-zig is an independent open-source project, not affiliated with,
endorsed by or sponsored by ORCID, Inc. Its client reads only ORCID's
Public API: no ORCID Sandbox, no ORCID Member API.

## Cell 0: Setup: the paths and the allocator

Goal: Name the inputs (all shipped in `testdata/`, paths relative to the package root) and the allocator every cell uses.

The context every cell gets, and the input paths:

```zig
pub const Ctx = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    root: std.Io.Dir,
    out: *std.Io.Writer,
};

/// The inputs, relative to the package root.
pub const paths = struct {
    /// The public record of 0000-0002-2771-9344 (CC0): 12 works, no
    /// affiliations.
    pub const record = "testdata/0000-0002-2771-9344.xml";
    /// ORCID's read sample of a full record (fictitious iD
    /// 8888-8888-8888-8880), for the affiliations the record does not have.
    pub const sample_record = "testdata/record_3.0/samples/read_samples/record-3.0.xml";
    /// ORCID's read sample of a full work (one contributor).
    pub const work_full_read = "testdata/record_3.0/samples/read_samples/work-full-3.0.xml";
    /// ORCID's write sample of a full work, as XML (one contributor) and as
    /// JSON (two contributors).
    pub const work_full_write = "testdata/record_3.0/samples/write_samples/work-full-3.0.xml";
    pub const work_full_json = "testdata/record_3.0/samples/write_samples/work-full-3.0.json";
    /// A small Public Data File-shaped `.tar.gz` (yorc-duckdb's
    /// test/data/dump/orcid_test_summaries.tar.gz is the same file).
    pub const dump = "testdata/dump/orcid_test_summaries.tgz";

    pub const all = [_][]const u8{ record, sample_record, work_full_read, work_full_write, work_full_json, dump };
};
```

The cell:

```zig
const out = cx.out;
try out.writeAll("inputs, relative to the package root:\n");
for (paths.all) |path| {
    const bytes = try readInput(cx, path);
    defer cx.gpa.free(bytes);
    try out.print("  {s}  {d} bytes\n", .{ path, bytes.len });
}
try out.writeAll("allocator: std.process.Init.gpa, io: std.process.Init.io\n");
```

Expected output:

<!-- derived: Sizes: `wc -c` on each file under `testdata/`. The allocator line is a fixed string. -->

```text
inputs, relative to the package root:
  testdata/0000-0002-2771-9344.xml  45543 bytes
  testdata/record_3.0/samples/read_samples/record-3.0.xml  36958 bytes
  testdata/record_3.0/samples/read_samples/work-full-3.0.xml  2922 bytes
  testdata/record_3.0/samples/write_samples/work-full-3.0.xml  2500 bytes
  testdata/record_3.0/samples/write_samples/work-full-3.0.json  2358 bytes
  testdata/dump/orcid_test_summaries.tgz  64616 bytes
allocator: std.process.Init.gpa, io: std.process.Init.io
```

## Cell 1: Check and normalise ORCID iDs

Goal: Validate and normalise the four shared iD forms (valid, wrong check character, URL, spaced) with their URIs, compute a check character, then a few more forms (ISO 7064 MOD 11-2, yorc-duckdb's normalisation rules).

```zig
const out = cx.out;
const inputs = [_][]const u8{
    "0000-0002-1825-0097", // valid
    "0000-0002-1825-0098", // wrong check character
    "https://orcid.org/000000021694233x", // URL form, no hyphens, lowercase x
    " 0000 0002 2771 9344 ", // spaced
};
for (inputs) |input| {
    if (yorc.OrcidId.parse(input)) |id| {
        const uri = id.uri();
        try out.print("\"{s}\" -> {f} ({s})\n", .{ input, id, &uri });
    } else |err| {
        try out.print("\"{s}\" -> invalid (error.{s})\n", .{ input, @errorName(err) });
    }
}
// ISO 7064 MOD 11-2 over the first 15 digits
try out.print("check character of 0000-0002-1825-009?: {c}\n", .{yorc.id.checkChar("000000021825009").?});

// more forms
try out.writeAll("more forms:\n");
const more = [_][]const u8{
    "orcid.org/0000000218250097", // bare host prefix
    "HTTPS://ORCID.ORG/0000-0002-1825-0097", // prefixes are case-sensitive
    "0000-0002-1825-009", // too short
};
for (more) |input| {
    if (yorc.OrcidId.parse(input)) |id| {
        try out.print("  \"{s}\" -> {f}\n", .{ input, id });
    } else |err| {
        try out.print("  \"{s}\" -> invalid (error.{s})\n", .{ input, @errorName(err) });
    }
}
```

Expected output:

<!-- derived: A python3 -I re-implementation of `src/id.zig` (skip leading C whitespace, strip one case-sensitive prefix, drop hyphens and whitespace, upper-case, 16 characters, ISO 7064 MOD 11-2) over the seven strings: 0000-0002-1825-009 -> 7, 0000-0002-1694-233 -> X, 0000-0002-2771-934 -> 4, ...0098 fails the check. The first five lines are the inputs and results of yorc-rs's cell 1; the invalid wording is Zig's error name. -->

```text
"0000-0002-1825-0097" -> 0000-0002-1825-0097 (https://orcid.org/0000-0002-1825-0097)
"0000-0002-1825-0098" -> invalid (error.InvalidOrcidId)
"https://orcid.org/000000021694233x" -> 0000-0002-1694-233X (https://orcid.org/0000-0002-1694-233X)
" 0000 0002 2771 9344 " -> 0000-0002-2771-9344 (https://orcid.org/0000-0002-2771-9344)
check character of 0000-0002-1825-009?: 7
more forms:
  "orcid.org/0000000218250097" -> 0000-0002-1825-0097
  "HTTPS://ORCID.ORG/0000-0002-1825-0097" -> invalid (error.InvalidOrcidId)
  "0000-0002-1825-009" -> invalid (error.InvalidOrcidId)
```

## Cell 2: Read a saved ORCID record and summarise it

Goal: Parse the saved public record and print its iD, hash, name and the counts of works, fundings, affiliations and peer reviews.

```zig
const out = cx.out;
const bytes = try readInput(cx, paths.record);
defer cx.gpa.free(bytes);
var diag: yorc.Diagnostic = .{};
var doc = yorc.xml.parse(cx.gpa, bytes, .{}, &diag) catch |err| {
    try out.print("cannot read {s}: {f}\n", .{ paths.record, diag });
    return err;
};
defer doc.deinit();

const hash = yorc.hash.sha256Hex(bytes);
try out.print("iD: {s}\n", .{doc.orcid() orelse "-"});
try out.print("sha256: {s}\n", .{&hash});
const rec = doc.record() orelse return error.NotARecord;
if (rec.person) |person| {
    if (person.name) |name| {
        try out.print("name: {s} {s}\n", .{ name.given_names orelse "-", name.family_name orelse "-" });
        try out.print("credit name: {s}\n", .{name.credit_name orelse "-"});
    }
}
const n = countActivities(doc.activitiesSummary() orelse return error.NoActivities);
try out.print("works: {d}\nfundings: {d}\naffiliations: {d}\npeer reviews: {d}\n", .{
    n.works, n.fundings, n.affiliations, n.peer_reviews,
});
```

Expected output:

<!-- derived: python3 -I `xml.etree` over `testdata/0000-0002-2771-9344.xml`: root `path`, `person/name` texts, and the number of `work-summary` (12), `funding-summary`, `*-summary` under the seven affiliation containers and `peer-review-summary` elements (none: those containers are empty elements). `sha256sum` (python3 -I `hashlib.sha256` of the file bytes agrees) for the hash. -->

```text
iD: 0000-0002-2771-9344
sha256: 59018b6d315be538bb84a6105ff3ac1c4c274f3b467a455eb2576e03bbc2f86e
name: Sofia Hernandez
credit name: Sofia Maria Garcia Hernandez
works: 12
fundings: 0
affiliations: 0
peer reviews: 0
```

## Cell 3: List the record's works with year, type and DOI, newest first, top 10

Goal: Print the 10 newest works with publication date, type and DOI (the `works` table's `doi`: first `doi`/`self` id, lowercased).

```zig
const out = cx.out;
var t = try loadTables(cx, paths.record);
defer t.deinit();
const tables: *const yorc.rows.Tables = &t;

const order = try cx.gpa.alloc(usize, t.count(.works));
defer cx.gpa.free(order);
for (order, 0..) |*o, i| o.* = i;
std.mem.sort(usize, order, tables, newestWorkFirst);

try out.print("{d} works; the 10 newest (publication date, newest first, then put-code):\n", .{order.len});
for (order[0..@min(10, order.len)]) |r| {
    var buf: [16]u8 = undefined;
    const when = try fuzzyDate(&buf, tables, .works, r, "pub");
    try out.print("{s:<10}  {s:<15}  {s:<25}  {s}\n", .{
        when,
        t.cell(.works, r, "type").?.asStr() orelse "-",
        t.cell(.works, r, "doi").?.asStr() orelse "-",
        t.cell(.works, r, "title").?.asStr() orelse "-",
    });
}
```

Expected output:

<!-- derived: python3 -I `xml.etree`: every `work-summary` with its `put-code`, `title/title`, `type`, `publication-date` parts and first `external-id` of type `doi` and relationship `self` (value lowercased), sorted by year, month, day descending (missing parts last), then put-code ascending; formatted `%-10s  %-15s  %-25s  %s`. -->

```text
12 works; the 10 newest (publication date, newest first, then put-code):
2026-08-17  data-set         10.25592/uhhfdm.19102      Point cloud calorimeter shower datasets for multi-geometry pre-training: SimpleBox and LEMURS
2026-08-17  data-set         10.25592/uhhfdm.19103      Point cloud calorimeter shower datasets for multi-geometry pre-training: SimpleBox and LEMURS
2026-08-17  data-set         10.25592/uhhfdm.19102      Point cloud calorimeter shower datasets for multi-geometry pre-training: SimpleBox and LEMURS
2017-03-28  other            10.5281/zenodo.495149      Introducing Orcid
2017        other            10.6084/m9.figshare.5479792.v1  ORCID Public Data File 2017
2016-11-23  other            10.5281/zenodo.168190      Introducing Orcid: What, Why And How
2016        data-set         10.6084/m9.figshare.4134027.v1  ORCID Public Data File 2016
2016        journal-article  10.1002/chemv.201600091    Your Lifelong Digital Name
2015        data-set         10.6084/m9.figshare.1582705  ORCID Public Data File 2015
2014        data-set         10.14454/07243.2014.001    ORCID Annual Public Data File, 2014
```

## Cell 4: Read ORCID JSON, and convert a document XML→JSON→XML

Goal: Read ORCID's full work write sample as JSON, then take the same sample's XML through JSON and back.

```zig
const out = cx.out;

// ORCID JSON in: the kind is the XML root's local name (JSON documents
// do not name their root)
const json_in = try readInput(cx, paths.work_full_json);
defer cx.gpa.free(json_in);
var diag: yorc.Diagnostic = .{};
var doc = yorc.json.parse(cx.gpa, "work", json_in, &diag) catch |err| {
    try out.print("cannot read {s}: {f}\n", .{ paths.work_full_json, diag });
    return err;
};
defer doc.deinit();
const work = switch (doc.root) {
    .work => |*w| w,
    else => return error.NotAWork,
};
var date_buf: [16]u8 = undefined;
try out.print("JSON work: \"{s}\", {s}, published {s}, {d} external ids\n", .{
    if (work.title) |t| t.title orelse "-" else "-",
    if (work.work_type) |t| t.text() else "-",
    try modelDate(&date_buf, work.publication_date),
    work.external_ids.len,
});
for (work.contributors) |c| {
    const id_path: ?[]const u8 = if (c.contributor_orcid) |o| o.path else null;
    try out.print("  contributor: {s} ({s})\n", .{ c.credit_name orelse "-", id_path orelse "-" });
}

// XML -> JSON -> XML
const xml_in = try readInput(cx, paths.work_full_write);
defer cx.gpa.free(xml_in);
var from_xml = try yorc.xml.parse(cx.gpa, xml_in, .{}, null);
defer from_xml.deinit();
const kind = from_xml.root.kind() orelse return error.UnknownKind;
const json_text = try yorc.json.toOwned(cx.gpa, &from_xml.root, null);
defer cx.gpa.free(json_text);
var from_json = try yorc.json.parse(cx.gpa, kind, json_text, null);
defer from_json.deinit();
const xml_again = try yorc.xml.toOwned(cx.gpa, &from_json.root, null);
defer cx.gpa.free(xml_again);
const xml_direct = try yorc.xml.toOwned(cx.gpa, &from_xml.root, null);
defer cx.gpa.free(xml_direct);

// the top-level keys, in the writer's (sorted) order
const parsed = try std.json.parseFromSlice(std.json.Value, cx.gpa, json_text, .{});
defer parsed.deinit();
if (parsed.value != .object) return error.NotAnObject;
try out.print("XML -> JSON: kind \"{s}\", keys: ", .{kind});
for (parsed.value.object.keys(), 0..) |key, i| {
    if (i > 0) try out.writeAll(", ");
    try out.writeAll(key);
}
try out.writeByte('\n');
try out.print("JSON -> XML: same model: {s}, same XML: {s}\n", .{
    if (yorc.model.eql(from_json.root, from_xml.root)) "true" else "false",
    if (std.mem.eql(u8, xml_again, xml_direct)) "true" else "false",
});
```

Expected output:

<!-- derived: python3 -I `json` over `write_samples/work-full-3.0.json`: title.title.value, type, publication-date 2022/05/24, 2 external-id entries, contributors Jordan (0000-0002-5391-5437) and Fran (0000-0002-4325-871X). The keys: the 11 child elements of `write_samples/work-full-3.0.xml` under their JSON names (`wWork` in `src/json.zig`), sorted bytewise as the writer sorts them. `same model` and `same XML` hold for a document without timestamps (`tests/json_test.zig`, XML samples through JSON). Matches yorc-rs's cell 4 line for line. -->

```text
JSON work: "Work Title", journal-article, published 2022-05-24, 2 external ids
  contributor: Jordan (0000-0002-5391-5437)
  contributor: Fran (0000-0002-4325-871X)
XML -> JSON: kind "work", keys: citation, contributors, country, external-ids, journal-title, language-code, publication-date, short-description, title, type, url
JSON -> XML: same model: true, same XML: true
```

## Cell 5: Flatten the record into section tables and export one as CSV

Goal: Flatten the record into yorc-duckdb's section tables, count their rows, and export the works table as CSV (shown: the header and the first 2 rows).

```zig
const out = cx.out;
// the rows yorc-duckdb's orcid_<section>_xml(xml) returns, source_hash included
var t = try loadTables(cx, paths.record);
defer t.deinit();
for (yorc.rows.Section.all) |s| {
    try out.print("{s:<24} {d:>4} rows, {d:>2} columns\n", .{ s.name(), t.count(s), s.columns().len });
}

// one section as CSV, every column (RFC 4180 quoting; NULL is an empty field)
var csv: std.Io.Writer.Allocating = .init(cx.gpa);
defer csv.deinit();
var names: std.ArrayList([]const u8) = .empty;
defer names.deinit(cx.gpa);
for (yorc.rows.Section.works.columns()) |column| try names.append(cx.gpa, column.name);
try writeCsv(&csv.writer, &t, .works, names.items);
try out.print("works.csv: a header and {d} rows, built in memory; the first lines:\n", .{t.count(.works)});
var lines = std.mem.splitScalar(u8, csv.written(), '\n');
for (0..3) |_| try out.print("{s}\n", .{lines.next() orelse break});
```

yorc-zig has the fourteen sections of yorc-rs, with the same 300 columns,
so the counts are yorc-rs's.
The full CSV is in `csv.written()`; the cell prints its first three lines.

Expected output:

<!-- derived: Row counts: python3 -I `xml.etree` over the record (12, 0, 0, 0, 0, 0, 0, 26, 1, 4, 1, 0, 0, 0: 26 = every `common:external-id`, 11 at work-group level and 15 in the work summaries; 4 = the four other names, the other person-item containers being empty), the same counts as yorc-rs's cell 5. Column counts: `col("` occurrences per `*_cols` table in `src/rows.zig` (sum 300, as yorc-rs). CSV: the 32 `works` columns of `src/rows.zig` (the same names and order as yorc-rs's) and python3 -I `xml.etree` over the first two `work-summary` elements, `source_hash` = `sha256sum` of the record; identical to yorc-rs's three lines (checked with diff). -->

```text
works                      12 rows, 32 columns
fundings                    0 rows, 37 columns
affiliations                0 rows, 32 columns
peer_reviews                0 rows, 38 columns
research_resources          0 rows, 32 columns
research_resource_items     0 rows, 13 columns
contributors                0 rows, 12 columns
external_ids               26 rows, 13 columns
person                      1 rows, 15 columns
person_items                4 rows, 24 columns
history                     1 rows, 17 columns
search_results              0 rows, 13 columns
errors                      0 rows, 10 columns
research_resource_hosts     0 rows, 12 columns
works.csv: a header and 12 rows, built in memory; the first lines:
orcid,put_code,group_index,display_index,title,subtitle,journal,type,pub_year,pub_month,pub_day,doi,url,source_name,visibility,created,last_modified,source_hash,translated_title,translated_title_language,short_description,citation_type,citation_value,language_code,country,path,source_client_id,source_orcid,assertion_origin_name,assertion_origin_orcid,assertion_origin_client_id,item
0000-0002-2771-9344,224052945,1,1,Point cloud calorimeter shower datasets for multi-geometry pre-training: SimpleBox and LEMURS,,Universität Hamburg,data-set,2026,8,17,10.25592/uhhfdm.19102,,DataCite,public,2026-08-17T12:42:27.716Z,2026-08-17T12:42:27.716Z,59018b6d315be538bb84a6105ff3ac1c4c274f3b467a455eb2576e03bbc2f86e,,,,,,,,/0000-0002-2771-9344/work/224052945,0000-0001-8099-6984,,,,,work-summary
0000-0002-2771-9344,224052944,1,1,Point cloud calorimeter shower datasets for multi-geometry pre-training: SimpleBox and LEMURS,,Universität Hamburg,data-set,2026,8,17,10.25592/uhhfdm.19103,,DataCite,public,2026-08-17T12:42:27.716Z,2026-08-17T12:42:27.716Z,59018b6d315be538bb84a6105ff3ac1c4c274f3b467a455eb2576e03bbc2f86e,,,,,,,,/0000-0002-2771-9344/work/224052944,0000-0001-8099-6984,,,,,work-summary
```

## Cell 6: Contributors and co-authors of the works

Goal: List the contributors of ORCID's two full work samples, and the distinct co-authors over both.

```zig
const out = cx.out;
var arena: std.heap.ArenaAllocator = .init(cx.gpa);
defer arena.deinit();
const keep = arena.allocator();
var coauthors: std.ArrayList(CoAuthor) = .empty;

for ([_][]const u8{ paths.work_full_read, paths.work_full_write }) |path| {
    var t = try loadTables(cx, path);
    defer t.deinit();
    try out.print("{s}: \"{s}\"\n", .{ path, t.cell(.works, 0, "title").?.asStr() orelse "-" });
    for (0..t.count(.contributors)) |r| {
        try out.print("  {f}. {f}  {f}  email={f}  sequence={f}  role={f}  owner={f}/{f}\n", .{
            t.cell(.contributors, r, "ordinal").?,
            t.cell(.contributors, r, "contributor_orcid").?,
            t.cell(.contributors, r, "credit_name").?,
            t.cell(.contributors, r, "email").?,
            t.cell(.contributors, r, "sequence").?,
            t.cell(.contributors, r, "role").?,
            t.cell(.contributors, r, "owner").?,
            t.cell(.contributors, r, "owner_put_code").?,
        });
        const id_text = t.cell(.contributors, r, "contributor_orcid").?.asStr() orelse continue;
        const known = for (coauthors.items) |ca| {
            if (std.mem.eql(u8, ca.id, id_text)) break true;
        } else false;
        if (!known) try coauthors.append(keep, .{
            .id = try keep.dupe(u8, id_text),
            .name = try keep.dupe(u8, t.cell(.contributors, r, "credit_name").?.asStr() orelse "-"),
        });
    }
}
std.mem.sort(CoAuthor, coauthors.items, {}, CoAuthor.lessThan);
try out.print("co-authors over both works (distinct contributor iDs): {d}\n", .{coauthors.items.len});
for (coauthors.items) |ca| try out.print("  {s}  {s}\n", .{ ca.id, ca.name });

var rec = try loadTables(cx, paths.record);
defer rec.deinit();
try out.print("{s}: {d} contributor rows ({d} work summaries; contributors come only with full works)\n", .{
    paths.record, rec.count(.contributors), rec.count(.works),
});
```

Contributors exist only on full works (`work`, `funding`); a record
holds work summaries, so its `contributors` table is empty. Fetch the full
works to see a record's co-authors.

Expected output:

<!-- derived: python3 -I `xml.etree` over the two `work-full-3.0.xml` samples: `put-code` attribute (read sample 123, write sample none, so `owner` is NULL), `contributor-orcid/path`, `credit-name`, `contributor-email`, `contributor-sequence`, `contributor-role`. 0 contributor rows for the record: its 12 works are work summaries, which have no contributors. -->

```text
testdata/record_3.0/samples/read_samples/work-full-3.0.xml: "common:title"
  1. 8888-8888-8888-8880  work:credit-name  email=work@contributor.email  sequence=first  role=author  owner=work/123
testdata/record_3.0/samples/write_samples/work-full-3.0.xml: "Work Title"
  1. 0000-0001-5109-3700  Laure L. Haak  email=<null>  sequence=first  role=author  owner=<null>/<null>
co-authors over both works (distinct contributor iDs): 2
  0000-0001-5109-3700  Laure L. Haak
  8888-8888-8888-8880  work:credit-name
testdata/0000-0002-2771-9344.xml: 0 contributor rows (12 work summaries; contributors come only with full works)
```

## Cell 7: An affiliation timeline

Goal: Employment and education entries, oldest first, with their organisation ids.

The record 0000-0002-2771-9344 has no affiliations, so this cell reads ORCID's
sample record (`paths.sample_record`, `record-3.0.xml` of the read samples,
fictitious iD 8888-8888-8888-8880), which has one summary of each affiliation
kind; its values are ORCID's placeholders (`education-org`,
`education:role-title`, ...).

```zig
const out = cx.out;
var t = try loadTables(cx, paths.sample_record);
defer t.deinit();
const tables: *const yorc.rows.Tables = &t;

var picked: std.ArrayList(usize) = .empty;
defer picked.deinit(cx.gpa);
for (0..t.count(.affiliations)) |r| {
    const kind = t.cell(.affiliations, r, "affiliation_type").?.asStr() orelse continue;
    if (std.mem.eql(u8, kind, "employment") or std.mem.eql(u8, kind, "education")) try picked.append(cx.gpa, r);
}
std.mem.sort(usize, picked.items, tables, oldestStartFirst);

try out.print("{d} employment and education entries, oldest first:\n", .{picked.items.len});
for (picked.items) |r| {
    var start_buf: [16]u8 = undefined;
    var end_buf: [16]u8 = undefined;
    try out.print("{s:<10}  {s:<10}  {s:<10}  {s}", .{
        try fuzzyDate(&start_buf, tables, .affiliations, r, "start"),
        try fuzzyDate(&end_buf, tables, .affiliations, r, "end"),
        t.cell(.affiliations, r, "affiliation_type").?.asStr().?,
        t.cell(.affiliations, r, "org_name").?.asStr() orelse "-",
    });
    if (t.cell(.affiliations, r, "org_disambiguated_id").?.asStr()) |org_id| {
        const source = t.cell(.affiliations, r, "org_disambiguation_source").?.asStr() orelse "-";
        try out.print(" [{s} {s}]", .{ source, org_id });
    } else {
        try out.writeAll(" [no organisation id]");
    }
    try out.print(": {s}", .{t.cell(.affiliations, r, "role_title").?.asStr() orelse "-"});
    if (t.cell(.affiliations, r, "department").?.asStr()) |department| try out.print(" ({s})", .{department});
    try out.writeByte('\n');
}
```

Expected output:

<!-- derived: python3 -I `xml.etree` over `testdata/record_3.0/samples/read_samples/record-3.0.xml`: the one `education-summary` and the one `employment-summary` with `start-date`/`end-date` parts, `role-title`, `department-name`, `organization/name` and `disambiguated-organization`. Both start on 1948-02-02 and have put-code 0, so the sort (stable) keeps the table order, educations before employments (`activities` in `src/rows.zig`); the employment's end date has a year only. -->

```text
2 employment and education entries, oldest first:
1948-02-02  2019-01-01  education   education-org [GRID common:disambiguated-organization-identifier-education]: education:role-title (education:department-name)
1948-02-02  2025        employment  employment-org [GRID common:disambiguated-organization-identifier-employment]: employment:role-title (employment:department-name)
```

## Cell 8: Stream the Public Data File dump fixture

Goal: Walk the `.tar.gz` without unpacking it: list XML members and iDs, count records, draw a seeded reservoir sample.

```zig
const out = cx.out;
{
    const fa = try yorc.dump.FileArchive.openAt(cx.gpa, cx.io, cx.root, paths.dump);
    defer fa.deinit();
    var files: usize = 0;
    var dirs: usize = 0;
    var xml_members: usize = 0;
    var records: usize = 0;
    while (try fa.archive.next()) |m| {
        switch (m.kind) {
            .file => files += 1,
            .directory => dirs += 1,
            .sym_link => {},
        }
        if (m.kind != .file) continue;
        const stem = yorc.dump.xmlEntryStem(m.name) orelse continue;
        xml_members += 1;
        const bytes = try fa.archive.read(m, 64 << 20); // valid until the next member
        var doc = try yorc.xml.parse(cx.gpa, bytes, .{}, null);
        defer doc.deinit();
        if (doc.record() != null) records += 1;
        const canonical = yorc.id.normalize(stem);
        const id_text: []const u8 = if (canonical) |*c| c else "(not an iD)";
        try out.print("  {s:<19}  {s:<6}  {s}\n", .{ id_text, doc.root.kind() orelse "?", m.name });
    }
    try out.print("members: {d} ({d} files, {d} directories); XML members: {d}; records: {d}\n", .{
        files + dirs, files, dirs, xml_members, records,
    });
}

for ([_]u64{ 42, 7 }) |seed| {
    const fa = try yorc.dump.FileArchive.openAt(cx.gpa, cx.io, cx.root, paths.dump);
    defer fa.deinit();
    var sample: yorc.reservoir.Reservoir([19]u8) = .init(1, seed);
    defer sample.deinit(cx.gpa);
    var reads: usize = 0;
    while (try fa.archive.nextXml()) |m| {
        const canonical = yorc.id.normalize(yorc.dump.xmlEntryStem(m.name).?) orelse continue;
        const slot = sample.offer();
        if (slot == .skip) continue; // decided before the member is read
        _ = try fa.archive.read(m, 64 << 20);
        reads += 1;
        _ = try sample.put(cx.gpa, slot, canonical);
    }
    try out.print("seeded sample, capacity 1, seed {d}: {s} ({d} records offered, {d} read)\n", .{
        seed, &sample.slice()[0], sample.seen, reads,
    });
}
```

Expected output:

<!-- derived: python3 -I `tarfile` over the archive (8 members: 4 files, 4 directories, as pinned in `tests/dump_test.zig`), `xml.etree` for each XML member's root element, and a python3 re-implementation of SplitMix64 and Algorithm R (it reproduces the pinned vectors of `src/reservoir.zig`): with capacity 1, seed 42 draws below(2) = 1 (the second record is skipped, never read), seed 7 draws 0 (it replaces the first). -->

```text
  0000-0003-0100-6634  record  ORCID_test_summaries/634/0000-0003-0100-6634.xml
  8888-8888-8888-8880  record  ORCID_test_summaries/880/8888-8888-8888-8880.xml
  (not an iD)          works   ORCID_test_summaries/a-directory-name-long-enough-to-need-gnu-long-names-or-pax-headers/and-a-file-name-too-0000-0000-0000-0000.xml
members: 8 (4 files, 4 directories); XML members: 3; records: 2
seeded sample, capacity 1, seed 42: 0000-0003-0100-6634 (2 records offered, 1 read)
seeded sample, capacity 1, seed 7: 8888-8888-8888-8880 (2 records offered, 2 read)
```

## Cell 9: Getting one public record from ORCID

Goal: One `GET /record` from the Public API with `.public` access, at most one request every 45 s (run only with `-- 9 --network`).

```zig
const out = cx.out;
try out.writeAll(
    \\One request to ORCID's Public API (https://pub.orcid.org/v3.0):
    \\- the client is built with .public access: public reads only;
    \\- the client enforces ORCID's cap of one request every 45 s to ORCID's
    \\  hosts, process-wide and one at a time (retries and token calls included);
    \\- bulk data must come from the Public Data File (cell 8, yorc.dump),
    \\  never from crawling the API;
    \\- it has no access to the ORCID Sandbox or the ORCID Member API.
    \\
);
var c = try client.Client.init(cx.gpa, cx.io, .{ .access = .public }, null);
defer c.deinit();
try out.print("spacing of this client's requests: {d} s\n", .{c.minInterval() / std.time.ns_per_s});
try out.flush();

var fail: client.Failure = .{};
defer fail.deinit(cx.gpa);
var doc = c.record("0000-0002-2771-9344", .xml, &fail) catch |err| {
    try out.print("the request failed: error.{s}", .{@errorName(err)});
    if (fail.status != 0) try out.print(", HTTP {d}", .{fail.status});
    if (fail.orcidError()) |e| try out.print(", {s}", .{e.developer_message orelse "-"});
    if (fail.message.len > 0) try out.print(", {s}", .{fail.message});
    try out.writeByte('\n');
    return;
};
defer doc.deinit();
try out.print("iD: {s}\n", .{doc.orcid() orelse "-"});
if (doc.record()) |r| {
    if (r.person) |person| {
        if (person.name) |name| try out.print("name: {s} {s}\n", .{ name.given_names orelse "-", name.family_name orelse "-" });
    }
}
if (doc.activitiesSummary()) |a| {
    const n = countActivities(a);
    try out.print("works {d}, fundings {d}, affiliations {d}, peer reviews {d}\n", .{
        n.works, n.fundings, n.affiliations, n.peer_reviews,
    });
}
```

Without `--network` the program prints only the cell header and a note.
With it, the cell makes one request (`GET https://pub.orcid.org/v3.0/0000-0002-2771-9344/record`).

Expected output (the text is fixed; the record values are whatever ORCID
returns today, so they are not pinned; the saved copy in `testdata/` has 12
works and no fundings, affiliations or peer reviews):

```text
One request to ORCID's Public API (https://pub.orcid.org/v3.0):
- the client is built with .public access: public reads only;
- the client enforces ORCID's cap of one request every 45 s to ORCID's
  hosts, process-wide and one at a time (retries and token calls included);
- bulk data must come from the Public Data File (cell 8, yorc.dump),
  never from crawling the API;
- it has no access to the ORCID Sandbox or the ORCID Member API.
spacing of this client's requests: 45 s
iD: 0000-0002-2771-9344
name: Sofia Hernandez
works N, fundings N, affiliations N, peer reviews N
```

On a network or API error the last three lines are replaced by
`the request failed: error.<Name>` with the HTTP status and ORCID's message
when there are any.

## Helpers

The helpers the cells call (the end of `examples/walkthrough.zig`):

```zig
/// Reads an input file (relative to the package root); caller frees.
fn readInput(cx: Ctx, path: []const u8) ![]u8 {
    return cx.root.readFileAlloc(cx.io, path, cx.gpa, .limited(64 << 20));
}

/// The section tables of an XML file (`source_hash` = its SHA-256). The
/// tables copy what they keep, so the bytes are freed here.
fn loadTables(cx: Ctx, path: []const u8) !yorc.rows.Tables {
    const bytes = try readInput(cx, path);
    defer cx.gpa.free(bytes);
    return yorc.rows.Tables.fromXml(cx.gpa, bytes);
}

const Counts = struct {
    works: usize = 0,
    fundings: usize = 0,
    affiliations: usize = 0,
    peer_reviews: usize = 0,
};

/// Work, funding, affiliation (all seven kinds) and peer-review summaries.
fn countActivities(a: *const yorc.model.ActivitiesSummary) Counts {
    var n: Counts = .{ .works = a.workSummaryCount() };
    if (a.fundings) |f| {
        for (f.groups) |g| n.fundings += g.funding_summaries.len;
    }
    for (yorc.model.AffiliationKind.all) |kind| {
        if (a.affiliations(kind)) |list| {
            for (list.groups) |g| n.affiliations += g.summaries.len;
        }
    }
    if (a.peer_reviews) |reviews| {
        for (reviews.groups) |g| {
            for (g.duplicates) |d| n.peer_reviews += d.summaries.len;
        }
    }
    return n;
}

/// `<prefix>_year`, `_month`, `_day` of a row as `YYYY`, `YYYY-MM` or
/// `YYYY-MM-DD`; `-` without a year.
fn fuzzyDate(buf: []u8, t: *const yorc.rows.Tables, comptime section: yorc.rows.Section, row: usize, comptime prefix: []const u8) ![]const u8 {
    const year = t.cell(section, row, prefix ++ "_year").?.asInt() orelse return "-";
    const month = t.cell(section, row, prefix ++ "_month").?.asInt() orelse
        return try std.fmt.bufPrint(buf, "{d:0>4}", .{year});
    const day = t.cell(section, row, prefix ++ "_day").?.asInt() orelse
        return try std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}", .{ year, month });
    return try std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}", .{ year, month, day });
}

/// A model fuzzy date as `YYYY-MM-DD`, `YYYY-MM` or `YYYY`; `-` without a year.
fn modelDate(buf: []u8, date: ?yorc.model.FuzzyDate) ![]const u8 {
    const d = date orelse return "-";
    const year = d.year orelse return "-";
    const month = d.month orelse return try std.fmt.bufPrint(buf, "{d:0>4}", .{year});
    const day = d.day orelse return try std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}", .{ year, month });
    return try std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}", .{ year, month, day });
}

/// SQL's `NULLS LAST` in either direction.
fn nullsLast(x: ?i64, y: ?i64, descending: bool) std.math.Order {
    const a = x orelse return if (y == null) .eq else .gt;
    const b = y orelse return .lt;
    return if (descending) std.math.order(b, a) else std.math.order(a, b);
}

/// Rows by `<prefix>_year`, `_month`, `_day` (missing parts last), then by
/// put-code ascending.
fn dateOrder(t: *const yorc.rows.Tables, comptime section: yorc.rows.Section, comptime prefix: []const u8, a: usize, b: usize, descending: bool) std.math.Order {
    inline for (.{ "_year", "_month", "_day" }) |part| {
        const o = nullsLast(t.cell(section, a, prefix ++ part).?.asInt(), t.cell(section, b, prefix ++ part).?.asInt(), descending);
        if (o != .eq) return o;
    }
    return nullsLast(t.cell(section, a, "put_code").?.asInt(), t.cell(section, b, "put_code").?.asInt(), false);
}

fn newestWorkFirst(t: *const yorc.rows.Tables, a: usize, b: usize) bool {
    return dateOrder(t, .works, "pub", a, b, true) == .lt;
}

fn oldestStartFirst(t: *const yorc.rows.Tables, a: usize, b: usize) bool {
    return dateOrder(t, .affiliations, "start", a, b, false) == .lt;
}

/// Writes `columns` of a section as CSV (RFC 4180: a header line, LF line
/// ends, fields with `,`, `"`, CR or LF quoted, NULL as an empty field).
fn writeCsv(w: *std.Io.Writer, t: *const yorc.rows.Tables, section: yorc.rows.Section, columns: []const []const u8) !void {
    for (columns, 0..) |name, i| {
        if (i > 0) try w.writeByte(',');
        try csvField(w, name);
    }
    try w.writeByte('\n');
    for (0..t.count(section)) |r| {
        for (columns, 0..) |name, i| {
            if (i > 0) try w.writeByte(',');
            const v = t.cell(section, r, name) orelse return error.UnknownColumn;
            switch (v) {
                .null => {},
                .varchar => |s| try csvField(w, s),
                .integer, .boolean => try w.print("{f}", .{v}),
            }
        }
        try w.writeByte('\n');
    }
}

fn csvField(w: *std.Io.Writer, s: []const u8) !void {
    if (std.mem.indexOfAny(u8, s, ",\"\r\n") == null) return w.writeAll(s);
    try w.writeByte('"');
    for (s) |ch| {
        if (ch == '"') try w.writeByte('"');
        try w.writeByte(ch);
    }
    try w.writeByte('"');
}

const CoAuthor = struct {
    id: []const u8,
    name: []const u8,

    fn lessThan(_: void, a: CoAuthor, b: CoAuthor) bool {
        return std.mem.lessThan(u8, a.id, b.id);
    }
};
```

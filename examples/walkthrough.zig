//! The yorc-zig walkthrough (WALKTHROUGH.md): ten cells, each a
//! function that writes its output into a `*std.Io.Writer`.
//!
//!   zig build walkthrough                  # cells 0 to 8 (cell 9 is skipped)
//!   zig build walkthrough -- 5             # cell 5 only
//!   zig build walkthrough -- 9 --network  # cell 9: one request to ORCID
//!
//! The build step runs this program in the package root, so the paths in
//! `paths` are relative to it. Every input is a file shipped in the package
//! (testdata/). tests/walkthrough_test.zig runs cells 0 to 8 and compares
//! their output with the expected output in WALKTHROUGH.md.
const std = @import("std");
const yorc = @import("yorc");
const client = @import("yorc_client");

/// What every cell gets: the allocator, the I/O implementation, the package
/// root (inputs are opened relative to it) and the writer for its output.
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

pub const Cell = struct {
    title: []const u8,
    run: *const fn (Ctx) anyerror!void,
};

pub const cells = [_]Cell{
    .{ .title = "Setup: the paths and the allocator", .run = cell0 },
    .{ .title = "Check and normalise ORCID iDs", .run = cell1 },
    .{ .title = "Read a saved ORCID record and summarise it", .run = cell2 },
    .{ .title = "List the record's works with year, type and DOI, newest first, top 10", .run = cell3 },
    .{ .title = "Read ORCID JSON, and convert a document XML→JSON→XML", .run = cell4 },
    .{ .title = "Flatten the record into section tables and export one as CSV", .run = cell5 },
    .{ .title = "Contributors and co-authors of the works", .run = cell6 },
    .{ .title = "An affiliation timeline", .run = cell7 },
    .{ .title = "Stream the Public Data File dump fixture", .run = cell8 },
    .{ .title = "Getting one public record from ORCID", .run = cell9 },
};

/// The only cell that uses the network; it runs only with `--network`.
pub const network_cell = 9;

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    var only: ?usize = null;
    var network = false;
    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--network")) {
            network = true;
            continue;
        }
        const n = std.fmt.parseInt(usize, arg, 10) catch usage(arg);
        if (n >= cells.len) usage(arg);
        only = n;
    }

    var buf: [64 * 1024]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(init.io, &buf);
    const out = &stdout.interface;
    const cx: Ctx = .{ .gpa = init.gpa, .io = init.io, .root = std.Io.Dir.cwd(), .out = out };

    runCells(cx, only, network) catch |err| {
        // A reader that closed the pipe early (`| head`) ends the output
        // quietly, as with cat; any other failure is reported.
        if (err == error.WriteFailed) {
            if (stdout.err) |e| {
                if (e == error.BrokenPipe) return;
            }
        }
        return err;
    };
}

fn runCells(cx: Ctx, only: ?usize, network: bool) !void {
    const out = cx.out;
    for (cells, 0..) |c, i| {
        if (only) |n| if (n != i) continue;
        try out.print("== Cell {d}: {s} ==\n", .{ i, c.title });
        if (i == network_cell and !network) {
            try out.writeAll("(not run: this cell calls the ORCID API; run `zig build walkthrough -- 9 --network`)\n\n");
            continue;
        }
        try out.flush();
        try c.run(cx);
        try out.writeByte('\n');
        try out.flush();
    }
    try out.flush();
}

fn usage(arg: []const u8) noreturn {
    std.debug.print(
        \\unexpected argument: {s}
        \\usage: zig build walkthrough [-- N] [-- 9 --network]   (N = 0..{d})
        \\
    , .{ arg, cells.len - 1 });
    std.process.exit(2);
}

// ===================================================================== cells

/// Cell 0: the inputs (paths relative to the package root) and the allocator.
pub fn cell0(cx: Ctx) anyerror!void {
    const out = cx.out;
    try out.writeAll("inputs, relative to the package root:\n");
    for (paths.all) |path| {
        const bytes = try readInput(cx, path);
        defer cx.gpa.free(bytes);
        try out.print("  {s}  {d} bytes\n", .{ path, bytes.len });
    }
    try out.writeAll("allocator: std.process.Init.gpa, io: std.process.Init.io\n");
}

/// Cell 1: check and normalise ORCID iDs (valid, invalid, URL and spaced forms).
pub fn cell1(cx: Ctx) anyerror!void {
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
}

/// Cell 2: read a saved ORCID record and summarise it.
pub fn cell2(cx: Ctx) anyerror!void {
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
}

/// Cell 3: the record's works with year, type and DOI, newest first, top 10.
/// Order: publication year, month, day (newest first, missing parts last),
/// then put-code (ascending), so that ties are reproducible.
pub fn cell3(cx: Ctx) anyerror!void {
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
}

/// Cell 4: read ORCID JSON, and convert a document XML -> JSON -> XML.
pub fn cell4(cx: Ctx) anyerror!void {
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
}

/// Cell 5: flatten the record into yorc-duckdb's section tables, and
/// export one of them (works) as CSV.
pub fn cell5(cx: Ctx) anyerror!void {
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
}

/// Cell 6: contributors and co-authors of the works. The record holds work
/// summaries, which have no contributors; ORCID's full work samples do.
pub fn cell6(cx: Ctx) anyerror!void {
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
}

/// Cell 7: an affiliation timeline: employment and education, oldest first
/// (start year, month, day ascending, missing parts last, then put-code),
/// with the organisation ids.
pub fn cell7(cx: Ctx) anyerror!void {
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
}

/// Cell 8: stream the Public Data File fixture without unpacking it: list
/// its XML members with their iDs, count the records, and draw a seeded
/// sample with the reservoir sampler (members it skips are never read).
pub fn cell8(cx: Ctx) anyerror!void {
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
}

/// Cell 9: one public record from ORCID (network; `-- 9 --network`).
pub fn cell9(cx: Ctx) anyerror!void {
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
}

// =================================================================== helpers

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
/// `YYYY-MM-DD`; `-` without a year. `@abs`: a padded signed integer prints
/// its sign (`+2025`).
fn fuzzyDate(buf: []u8, t: *const yorc.rows.Tables, comptime section: yorc.rows.Section, row: usize, comptime prefix: []const u8) ![]const u8 {
    const year = t.cell(section, row, prefix ++ "_year").?.asInt() orelse return "-";
    const month = t.cell(section, row, prefix ++ "_month").?.asInt() orelse
        return try std.fmt.bufPrint(buf, "{d:0>4}", .{@abs(year)});
    const day = t.cell(section, row, prefix ++ "_day").?.asInt() orelse
        return try std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}", .{ @abs(year), @abs(month) });
    return try std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}", .{ @abs(year), @abs(month), @abs(day) });
}

/// A model fuzzy date as `YYYY-MM-DD`, `YYYY-MM` or `YYYY`; `-` without a year.
fn modelDate(buf: []u8, date: ?yorc.model.FuzzyDate) ![]const u8 {
    const d = date orelse return "-";
    const year = d.year orelse return "-";
    const month = d.month orelse return try std.fmt.bufPrint(buf, "{d:0>4}", .{@abs(year)});
    const day = d.day orelse return try std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}", .{ @abs(year), @abs(month) });
    return try std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}", .{ @abs(year), @abs(month), @abs(day) });
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

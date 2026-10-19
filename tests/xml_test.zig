//! XML: every ORCID v3.0 write and read sample and the real record round-trip
//! (read → write → read gives the same model; writing the re-read model is
//! byte-identical; the written XML is canonically equal to the original).
//! yorc-rs's tests/write_roundtrip.rs, minus xmllint.
//! The differential tests of the one-pass writer against the writer it
//! replaced (`writer_matches_reference_*`) are in xml_write_test.zig.
const std = @import("std");
const yorc = @import("yorc");
const fixtures = @import("fixtures");
const support = @import("support.zig");

const testing = std.testing;
const gpa = testing.allocator;
const model = yorc.model;

test {
    _ = @import("xml_write_test.zig");
}

/// Elements in ORCID's samples that the v3.0 XSDs do not allow, so the model
/// has no place for them: (file, namespace, local name, reason).
const not_in_schema = [_]struct { []const u8, []const u8, []const u8, []const u8 }{.{
    "peer-reviews-3.0.xml",
    "http://www.orcid.org/ns/peer-review",
    "summary",
    "pre-3.0 layout: peer-review:summary directly in activities:group",
}};

/// read → write → read, byte-identical rewrite, canonical equality.
/// Returns the written XML (caller frees).
fn roundTrip(name: []const u8, original: []const u8) ![]u8 {
    var diag: yorc.Diagnostic = .{};
    var doc = yorc.xml.parse(gpa, original, .{}, &diag) catch |err| {
        std.debug.print("{s}: {f}\n", .{ name, diag });
        return err;
    };
    defer doc.deinit();
    if (doc.root == .unknown) {
        std.debug.print("{s}: unknown root\n", .{name});
        return error.TestUnknownRoot;
    }
    const written = yorc.xml.toOwned(gpa, &doc.root, &diag) catch |err| {
        std.debug.print("{s}: {f}\n", .{ name, diag });
        return err;
    };
    errdefer gpa.free(written);
    var again = try yorc.xml.parse(gpa, written, .{}, null);
    defer again.deinit();
    try support.expectSameDocument(gpa, doc, again, name);
    const rewritten = try yorc.xml.toOwned(gpa, &again.root, null);
    defer gpa.free(rewritten);
    if (!std.mem.eql(u8, written, rewritten)) {
        std.debug.print("{s}: writing is not deterministic\n", .{name});
        return error.TestNotDeterministic;
    }

    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var expected = try support.canonical(a, original);
    for (not_in_schema) |n| {
        if (std.mem.eql(u8, n[0], name)) support.prune(&expected, n[1], n[2]);
    }
    const actual = try support.canonical(a, written);
    try support.expectSameXml(gpa, expected, actual, name);
    return written;
}

fn roundTripAll(set: []const fixtures.File, want: usize) !void {
    var n: usize = 0;
    var failed: usize = 0;
    for (set) |f| {
        if (!support.isXml(f)) continue;
        n += 1;
        const out = roundTrip(f.name, f.data) catch {
            failed += 1;
            continue;
        };
        gpa.free(out);
    }
    try testing.expectEqual(want, n);
    try testing.expectEqual(@as(usize, 0), failed);
}

test "write samples round-trip" {
    try roundTripAll(&fixtures.write_samples, 21);
}

test "read samples round-trip" {
    try roundTripAll(&fixtures.read_samples, 53);
}

test "the real record round-trips" {
    const written = try roundTrip("0000-0003-0100-6634.xml", fixtures.real_record);
    defer gpa.free(written);
    try testing.expect(std.mem.startsWith(u8, written, "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<record:record xmlns:activities="));
}

test "the pre-3.0 peer-review layout is the only content dropped" {
    // canonical comparison without pruning must fail for it, and only for it
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const original = fixtures.readSample("peer-reviews-3.0.xml");
    var doc = try yorc.xml.parse(gpa, original, .{}, null);
    defer doc.deinit();
    const written = try yorc.xml.toOwned(gpa, &doc.root, null);
    defer gpa.free(written);
    var msg: []const u8 = "";
    try testing.expect(try support.diff(a, try support.canonical(a, original), try support.canonical(a, written), "", &msg));
}

test "malformed and hostile input never panics" {
    const inputs = [_][]const u8{
        "",                           "<",               "<a",               "<a b>",
        "<a b='1' b='2'/>",           "<a><b></c></a>",  "<?xml?><a/><b/>",  "<!DOCTYPE a [<!ENTITY x 'y'>]><a>&x;</a>",
        "<a>&#xFFFFFFFF;&#;&#x;</a>", "<a><![CDATA[x",   "<a/>trailing</a>", "\xEF\xBB\xBF<work:work/>",
        "<record:record path=''/>",   "<a xmlns:='x'/>", "<a:b:c/>",         "<record><person><name><given-names>x",
    };
    for (inputs) |in| {
        var doc = yorc.xml.parse(gpa, in, .{}, null) catch continue;
        // whatever was read can be written, or is refused cleanly
        if (yorc.xml.toOwned(gpa, &doc.root, null)) |out| gpa.free(out) else |_| {}
        doc.deinit();
    }
}

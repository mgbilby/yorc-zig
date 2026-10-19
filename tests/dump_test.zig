//! Public Data File streaming over a small `.tar.gz` in the dump layout
//! (testdata/dump/orcid_test_summaries.tgz: the real record, the ORCID
//! sample record, a README and a member with a GNU long name), and the
//! seeded reservoir over its records. Concatenated gzip members (CROSSCHECK
//! #6): testdata/dump/orcid_test_two_members.tgz (Python's gzip, deflated),
//! and archives built here from stored deflate blocks.
const std = @import("std");
const yorc = @import("yorc");
const fixtures = @import("fixtures");

const testing = std.testing;
const gpa = testing.allocator;
const dump = yorc.dump;

test "streams members from a tar.gz" {
    var in: std.Io.Reader = .fixed(fixtures.dump_tgz);
    const ar = try dump.Archive.init(gpa, &in);
    defer ar.deinit();
    var files: usize = 0;
    var dirs: usize = 0;
    var records: usize = 0;
    var saw_long_name = false;
    while (try ar.next()) |m| {
        switch (m.kind) {
            .directory => dirs += 1,
            .file => files += 1,
            .sym_link => {},
        }
        if (std.mem.endsWith(u8, m.name, "/and-a-file-name-too-0000-0000-0000-0000.xml")) {
            saw_long_name = true;
            try testing.expect(std.mem.startsWith(u8, m.name, "ORCID_test_summaries/a-directory-name-long-enough-to-need-gnu-long-names-or-pax-headers/"));
            try testing.expectEqual(@as(u64, 6672), m.size);
        }
        const stem = dump.xmlEntryStem(m.name) orelse continue;
        if (m.kind != .file) continue;
        const id = yorc.OrcidId.parse(stem) catch continue;
        records += 1;
        const bytes = try ar.read(m, 64 << 20);
        try testing.expectEqual(m.size, bytes.len);
        var doc = try yorc.xml.parse(gpa, bytes, .{}, null);
        defer doc.deinit();
        try testing.expectEqualStrings(id.slice(), doc.orcid().?);
        if (std.mem.eql(u8, id.slice(), "0000-0003-0100-6634")) {
            try testing.expectEqualSlices(u8, fixtures.real_record, bytes);
            const h = yorc.hash.sha256Hex(bytes);
            try testing.expectEqualStrings("494662244addfd21664a3a56f222a88614b83f61084888ac6162eeb970324801", &h);
        } else {
            try testing.expectEqualStrings("8888-8888-8888-8880", id.slice());
            try testing.expectEqualSlices(u8, fixtures.readSample("record-3.0.xml"), bytes);
        }
    }
    try testing.expect(saw_long_name);
    try testing.expectEqual(@as(usize, 2), records);
    try testing.expectEqual(@as(usize, 4), files);
    try testing.expectEqual(@as(usize, 4), dirs);
    try testing.expectEqual(@as(u64, 8), ar.members_seen);
}

test "nextXml skips everything else; unread content is skipped" {
    var in: std.Io.Reader = .fixed(fixtures.dump_tgz);
    const ar = try dump.Archive.init(gpa, &in);
    defer ar.deinit();
    var names: [4][]const u8 = undefined;
    var stems: [4][64]u8 = undefined;
    var n: usize = 0;
    while (try ar.nextXml()) |m| {
        const stem = dump.xmlEntryStem(m.name).?;
        @memcpy(stems[n][0..stem.len], stem);
        names[n] = stems[n][0..stem.len];
        n += 1;
    }
    try testing.expectEqual(@as(usize, 3), n);
    try testing.expectEqualStrings("0000-0003-0100-6634", names[0]);
    try testing.expectEqualStrings("8888-8888-8888-8880", names[1]);
    try testing.expectEqualStrings("and-a-file-name-too-0000-0000-0000-0000", names[2]);
}

test "a member over the size limit is refused" {
    var in: std.Io.Reader = .fixed(fixtures.dump_tgz);
    const ar = try dump.Archive.init(gpa, &in);
    defer ar.deinit();
    const m = (try ar.nextXml()).?;
    try testing.expectError(error.CorruptArchive, ar.read(m, 1000));
    try testing.expectEqual(@as(?anyerror, error.StreamTooLong), ar.detail);
}

test "corrupt and truncated archives are errors" {
    {
        var in: std.Io.Reader = .fixed("this is not gzip at all, not at all");
        const ar = try dump.Archive.init(gpa, &in);
        defer ar.deinit();
        try testing.expectError(error.CorruptArchive, ar.next());
    }
    {
        var in: std.Io.Reader = .fixed(fixtures.dump_tgz[0 .. fixtures.dump_tgz.len / 2]);
        const ar = try dump.Archive.init(gpa, &in);
        defer ar.deinit();
        const result: dump.Error!void = blk: {
            while (true) {
                const m = (ar.next() catch |e| break :blk e) orelse break :blk {};
                if (m.kind == .file) _ = ar.read(m, 64 << 20) catch |e| break :blk e;
            }
        };
        try testing.expectError(error.CorruptArchive, result);
    }
}

test "a file archive by path" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "ORCID_test_summaries.tar.gz", .data = fixtures.dump_tgz });
    const fa = try dump.FileArchive.openAt(gpa, testing.io, tmp.dir, "ORCID_test_summaries.tar.gz");
    defer fa.deinit();
    var n: usize = 0;
    while (try fa.archive.nextXml()) |_| n += 1;
    try testing.expectEqual(@as(usize, 3), n);
    try testing.expect(dump.isDumpPath("ORCID_test_summaries.tar.gz"));
}

/// Sampling the dump's records (eligible: `.xml` members whose stem is a
/// valid iD) with capacity 1: the picks follow from SplitMix64 (seed 42:
/// below(2) = 1, the second record is skipped; seed 7: below(2) = 0, it
/// replaces the first), computed independently from the algorithm.
fn sampleDump(seed: u64) ![19]u8 {
    var in: std.Io.Reader = .fixed(fixtures.dump_tgz);
    const ar = try dump.Archive.init(gpa, &in);
    defer ar.deinit();
    var res: yorc.reservoir.Reservoir([19]u8) = .init(1, seed);
    defer res.deinit(gpa);
    while (try ar.nextXml()) |m| {
        const id = yorc.OrcidId.parse(dump.xmlEntryStem(m.name).?) catch continue;
        const slot = res.offer();
        if (slot == .skip) continue; // the content is never read
        _ = try ar.read(m, 64 << 20);
        _ = try res.put(gpa, slot, id.text);
    }
    try testing.expectEqual(@as(u64, 2), res.seen);
    return res.slice()[0];
}

test "reservoir picks over the dump" {
    try testing.expectEqualStrings("0000-0003-0100-6634", &(try sampleDump(42)));
    try testing.expectEqualStrings("8888-8888-8888-8880", &(try sampleDump(7)));
    try testing.expectEqualStrings("0000-0003-0100-6634", &(try sampleDump(0)));
}

// ------------------------------------------------- concatenated gzip members

/// A tar member: name, kind, size, and the content of files.
const Entry = struct { name: []const u8, kind: std.tar.FileKind, size: u64, content: []const u8 };

/// Every member of an archive, copied into `a`; `gzip_members` receives the
/// number of gzip members the archive began.
fn entries(a: std.mem.Allocator, tgz: []const u8, gzip_members: ?*u64) ![]Entry {
    var in: std.Io.Reader = .fixed(tgz);
    const ar = try dump.Archive.init(gpa, &in);
    defer ar.deinit();
    var list: std.ArrayList(Entry) = .empty;
    while (try ar.next()) |m| {
        const content = if (m.kind == .file) try a.dupe(u8, try ar.read(m, 64 << 20)) else "";
        try list.append(a, .{ .name = try a.dupe(u8, m.name), .kind = m.kind, .size = m.size, .content = content });
    }
    if (gzip_members) |g| g.* = ar.gzip_members;
    return list.items;
}

fn expectSameEntries(want: []const Entry, got: []const Entry) !void {
    try testing.expectEqual(want.len, got.len);
    for (want, got) |x, y| {
        try testing.expectEqualStrings(x.name, y.name);
        try testing.expectEqual(x.kind, y.kind);
        try testing.expectEqual(x.size, y.size);
        try testing.expectEqualSlices(u8, x.content, y.content);
    }
}

/// Appends one gzip member holding `data` in stored (uncompressed) deflate
/// blocks of at most 65,535 bytes (RFC 1951, 3.2.4; RFC 1952, 2.3).
fn appendStoredMember(a: std.mem.Allocator, out: *std.ArrayList(u8), data: []const u8) !void {
    // magic, CM = deflate, no flags, MTIME 0, XFL 0, OS unknown
    try out.appendSlice(a, &.{ 0x1f, 0x8b, 8, 0, 0, 0, 0, 0, 0, 0xff });
    var rest = data;
    while (true) {
        const n: u16 = @intCast(@min(rest.len, 0xffff));
        const final = n == rest.len;
        // BFINAL, BTYPE 00, then byte-aligned LEN and NLEN
        try out.append(a, @intFromBool(final));
        var lens: [4]u8 = undefined;
        std.mem.writeInt(u16, lens[0..2], n, .little);
        std.mem.writeInt(u16, lens[2..4], ~n, .little);
        try out.appendSlice(a, &lens);
        try out.appendSlice(a, rest[0..n]);
        rest = rest[n..];
        if (final) break;
    }
    var trailer: [8]u8 = undefined;
    std.mem.writeInt(u32, trailer[0..4], std.hash.Crc32.hash(data), .little);
    std.mem.writeInt(u32, trailer[4..8], @truncate(data.len), .little);
    try out.appendSlice(a, &trailer);
}

/// The tar inside a single-member `.tgz`.
fn tarOf(a: std.mem.Allocator, tgz: []const u8) ![]u8 {
    var in: std.Io.Reader = .fixed(tgz);
    const window = try a.alloc(u8, std.compress.flate.max_window_len);
    var d: std.compress.flate.Decompress = .init(&in, .gzip, window);
    return d.reader.allocRemaining(a, .unlimited);
}

test "the dump fixture is one gzip member" {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var members: u64 = 0;
    const e = try entries(arena.allocator(), fixtures.dump_tgz, &members);
    try testing.expectEqual(@as(usize, 8), e.len);
    try testing.expectEqual(@as(u64, 1), members);
}

// Built with Python (tarfile, USTAR; gzip.compress(level 9, mtime 0)): a
// 40,960-byte tar of four members, split at byte 12,055 (inside the record's
// content) into two gzip members of 1,580 and 2,335 bytes. Python's
// gzip.decompress, which reads every member, gives the tar back.
test "concatenated gzip members: a two-member fixture" {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var members: u64 = 0;
    const e = try entries(arena.allocator(), fixtures.dump_two_members_tgz, &members);
    try testing.expectEqual(@as(u64, 2), members);
    try testing.expectEqual(@as(usize, 4), e.len);
    try testing.expectEqual(std.tar.FileKind.directory, e[0].kind);
    try testing.expectEqualStrings("ORCID_test_summaries/README.txt", e[1].name);
    try testing.expectEqualStrings("Two gzip members: the tar is split inside the record below.\n", e[1].content);
    try testing.expectEqual(std.tar.FileKind.directory, e[2].kind);
    try testing.expectEqualStrings("ORCID_test_summaries/880/8888-8888-8888-8880.xml", e[3].name);
    try testing.expectEqualSlices(u8, fixtures.readSample("record-3.0.xml"), e[3].content);

    // the record parses, and nextXml finds it
    var in: std.Io.Reader = .fixed(fixtures.dump_two_members_tgz);
    const ar = try dump.Archive.init(gpa, &in);
    defer ar.deinit();
    const m = (try ar.nextXml()).?;
    var doc = try yorc.xml.parse(gpa, try ar.read(m, 64 << 20), .{}, null);
    defer doc.deinit();
    try testing.expectEqualStrings("8888-8888-8888-8880", doc.orcid().?);
    try testing.expect((try ar.nextXml()) == null);
}

test "concatenated gzip members: the dump fixture split into stored members" {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const tar = try tarOf(a, fixtures.dump_tgz);
    const want = try entries(a, fixtures.dump_tgz, null);
    // split inside members, with an empty member in between, and at a
    // stored-block boundary
    const cuts = [_]usize{ tar.len / 3 + 123, tar.len / 3 + 123, 2 * tar.len / 3 + 7, 2 * tar.len / 3 + 7 + 0xffff };
    var tgz: std.ArrayList(u8) = .empty;
    var from: usize = 0;
    for (cuts) |cut| {
        const to = @min(cut, tar.len);
        try appendStoredMember(a, &tgz, tar[from..to]);
        from = to;
    }
    try appendStoredMember(a, &tgz, tar[from..]);
    var members: u64 = 0;
    const got = try entries(a, tgz.items, &members);
    try expectSameEntries(want, got);
    try testing.expectEqual(@as(u64, cuts.len + 1), members);

    // the same tar as one stored member
    var single: std.ArrayList(u8) = .empty;
    try appendStoredMember(a, &single, tar);
    try expectSameEntries(want, try entries(a, single.items, &members));
    try testing.expectEqual(@as(u64, 1), members);
}

test "concatenated gzip members: input after a member that is not gzip" {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const tar = try tarOf(a, fixtures.dump_tgz);
    for ([_][]const u8{ "this is not a gzip member at all", "\x1f\x8b" }) |junk| {
        var tgz: std.ArrayList(u8) = .empty;
        try appendStoredMember(a, &tgz, tar[0 .. tar.len / 2]);
        try tgz.appendSlice(a, junk);
        var in: std.Io.Reader = .fixed(tgz.items);
        const ar = try dump.Archive.init(gpa, &in);
        defer ar.deinit();
        const result: dump.Error!void = blk: {
            while (true) {
                const m = (ar.next() catch |e| break :blk e) orelse break :blk {};
                if (m.kind == .file) _ = ar.read(m, 64 << 20) catch |e| break :blk e;
            }
        };
        try testing.expectError(error.CorruptArchive, result);
        // a header that is not gzip's, or one cut short
        const want: anyerror = if (junk.len >= 10) error.BadGzipHeader else error.EndOfStream;
        try testing.expectEqual(@as(?anyerror, want), ar.detail);
        try testing.expectEqual(@as(u64, 2), ar.gzip_members);
    }
}

//! The one-pass XML writer (src/xml_write.zig) against the writer it
//! replaced (xml_write_legacy.zig), as yorc-rs's tests/write_roundtrip.rs
//! `writer_matches_reference_*` do: on every sample and the real record, on
//! the same documents with escapes, multi-byte UTF-8, CR/TAB/LF and quotes
//! appended to every text and attribute value, with characters XML 1.0
//! cannot carry (and bytes that are not UTF-8) appended to every value or to
//! one value at a time, on bulk documents, and on hand-built
//! edge values. Both must write the same bytes, or fail with the same error,
//! `Diagnostic` path, message and code point. `xml.write` (into any writer)
//! must agree with `xml.toOwned` and write nothing when it fails.
//!
//! yorc-rs spices the XML text before reading it; here the values are
//! appended in the model itself (`Spice`), so every `Text` the model holds
//! is reached, whether the writer puts it in an attribute or in text.
const std = @import("std");
const yorc = @import("yorc");
const fixtures = @import("fixtures");
const support = @import("support.zig");
const legacy = @import("xml_write_legacy.zig");

const testing = std.testing;
const gpa = testing.allocator;
const model = yorc.model;
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const Diagnostic = yorc.Diagnostic;

// ---------------------------------------------------------------- outcomes

/// What a writer produced: bytes (owned), or an error and its Diagnostic.
const Outcome = struct {
    bytes: []u8 = &.{},
    err: ?anyerror = null,
    diag: Diagnostic = .{},

    fn deinit(o: *Outcome) void {
        gpa.free(o.bytes);
    }
};

fn fromOwned(result: anytype, diag: *const Diagnostic) Outcome {
    if (result) |bytes| {
        return .{ .bytes = bytes };
    } else |err| {
        return .{ .err = err, .diag = diag.* };
    }
}

fn firstDifference(a: []const u8, b: []const u8) usize {
    const n = @min(a.len, b.len);
    for (0..n) |i| {
        if (a[i] != b[i]) return i;
    }
    return n;
}

fn describe(o: *const Outcome) []const u8 {
    return if (o.err) |e| @errorName(e) else "bytes";
}

fn expectSameOutcome(what: []const u8, how: []const u8, ours: *const Outcome, reference: *const Outcome) !void {
    if (ours.err == null and reference.err == null) {
        if (std.mem.eql(u8, ours.bytes, reference.bytes)) return;
        const at = firstDifference(ours.bytes, reference.bytes);
        const from = at -| 200;
        const new_part = ours.bytes[from..@min(at + 200, ours.bytes.len)];
        const ref_part = reference.bytes[from..@min(at + 200, reference.bytes.len)];
        std.debug.print("{s} ({s}): output differs from the reference at byte {d} (lengths {d} and {d})\n", .{ what, how, at, ours.bytes.len, reference.bytes.len });
        std.debug.print("--- new ---\n{s}\n--- reference ---\n{s}\n", .{ new_part, ref_part });
        return error.TestOutputDiffers;
    }
    if (ours.err == null or reference.err == null) {
        std.debug.print("{s} ({s}): new gave {s}, the reference {s}\n", .{ what, how, describe(ours), describe(reference) });
        if (ours.err != null) std.debug.print("  new: {f}\n", .{ours.diag});
        if (reference.err != null) std.debug.print("  reference: {f}\n", .{reference.diag});
        return error.TestOutcomeDiffers;
    }
    const same = std.mem.eql(u8, @errorName(ours.err.?), @errorName(reference.err.?)) and
        std.mem.eql(u8, ours.diag.path(), reference.diag.path()) and
        std.mem.eql(u8, ours.diag.message, reference.diag.message) and
        ours.diag.code_point == reference.diag.code_point;
    if (!same) {
        std.debug.print("{s} ({s}): new failed with {s}: {f}\n", .{ what, how, @errorName(ours.err.?), ours.diag });
        std.debug.print("  the reference with {s}: {f}\n", .{ @errorName(reference.err.?), reference.diag });
        return error.TestErrorDiffers;
    }
}

/// `xml.toOwned` and `xml.write` against the reference's `toOwned`.
fn expectSame(what: []const u8, root: *const model.Root) !void {
    var d_ref: Diagnostic = .{};
    const r_ref = legacy.toOwned(gpa, root, &d_ref);
    var reference = fromOwned(r_ref, &d_ref);
    defer reference.deinit();

    var d_new: Diagnostic = .{};
    const r_new = yorc.xml.toOwned(gpa, root, &d_new);
    var ours = fromOwned(r_new, &d_new);
    defer ours.deinit();
    try expectSameOutcome(what, "toOwned", &ours, &reference);

    var aw: Writer.Allocating = .init(gpa);
    defer aw.deinit();
    var d_w: Diagnostic = .{};
    var via: Outcome = if (yorc.xml.write(&aw.writer, root, &d_w)) |_|
        .{ .bytes = try aw.toOwnedSlice() }
    else |err| blk: {
        if (aw.written().len != 0) {
            std.debug.print("{s}: write failed with {s} after writing {d} bytes\n", .{ what, @errorName(err), aw.written().len });
            return error.TestPartialWrite;
        }
        break :blk .{ .err = err, .diag = d_w };
    };
    defer via.deinit();
    try expectSameOutcome(what, "write", &via, &reference);
}

// ---------------------------------------------------------------- spicing

/// A deep copy of a model value with `suffix` appended to every `Text`
/// (`only`: to the text with that index in walk order, the others kept).
const Spice = struct {
    a: Allocator,
    suffix: []const u8,
    only: ?usize = null,
    /// Texts walked so far.
    seen: usize = 0,

    fn text(sp: *Spice, t: []const u8) Allocator.Error![]const u8 {
        const i = sp.seen;
        sp.seen += 1;
        if (sp.only) |o| {
            if (o != i) return t;
        }
        return std.mem.concat(sp.a, u8, &.{ t, sp.suffix });
    }

    fn value(sp: *Spice, v: anytype) Allocator.Error!@TypeOf(v) {
        const T = @TypeOf(v);
        switch (@typeInfo(T)) {
            .optional => return if (v) |x| try sp.value(x) else null,
            .pointer => |p| {
                if (p.size != .slice) @compileError("Spice: unsupported pointer type " ++ @typeName(T));
                // `Text`
                if (p.child == u8) return sp.text(v);
                const out = try sp.a.alloc(p.child, v.len);
                for (v, out) |x, *y| y.* = try sp.value(x);
                return out;
            },
            .@"struct" => |s| {
                var out = v;
                _ = &out;
                inline for (s.field_names) |name| @field(out, name) = try sp.value(@field(v, name));
                return out;
            },
            .@"union" => switch (v) {
                inline else => |x, tag| return @unionInit(T, @tagName(tag), try sp.value(x)),
            },
            else => return v,
        }
    }
};

/// The number of `Text` values in `root`.
fn textCount(a: Allocator, root: *const model.Root) !usize {
    var sp: Spice = .{ .a = a, .suffix = "", .only = std.math.maxInt(usize) };
    _ = try sp.value(root.*);
    return sp.seen;
}

/// Values every writer must write the same way: yorc-rs's spice cases
/// (decoded), plus runs that cross the vector, 16- and 8-byte chunks.
const allowed = [_][]const u8{
    " & <é中😀> \"q\" 'a' \r\t\nx\u{FFFD}&",
    " &<>\"\t\n\ré😀'x",
    "12345678&1234567<\u{FF0C}",
    "\u{FF0C}\u{FFFD}\u{FEFF}\u{EFFFF}" ++ "abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ" ++ "\"&\r",
    "\r\n\t\r\n\t\"\"\"<<<>>>&&&",
};

/// Values no writer may write: yorc-rs's forbidden cases (decoded), and
/// bytes that are not UTF-8 (refused as "not valid UTF-8").
const forbidden = [_][]const u8{
    " a\x01b",
    " a\u{FFFE}b",
    "\u{FFFF}",
    "\x1f",
    "\x00",
    "ok\xff",
    "é\xc3",
    "\xef\xbf",
    "\xed\xa0\x80",
    "\u{FF0C}\x0b",
};

/// The write and read samples and the real record (the XML ones are used).
const all_files = fixtures.write_samples ++ fixtures.read_samples ++
    [_]fixtures.File{.{ .name = "0000-0003-0100-6634.xml", .data = fixtures.real_record }};

fn spiced(what: []const u8, root: *const model.Root, suffix: []const u8, only: ?usize) !void {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var sp: Spice = .{ .a = arena.allocator(), .suffix = suffix, .only = only };
    const copy = try sp.value(root.*);
    try expectSame(what, &copy);
}

// ------------------------------------------------------------------ tests

test "writer matches reference on samples and the record" {
    var n: usize = 0;
    for (all_files) |f| {
        if (!support.isXml(f)) continue;
        var doc = try yorc.xml.parse(gpa, f.data, .{}, null);
        defer doc.deinit();
        try expectSame(f.name, &doc.root);
        n += 1;
    }
    try testing.expectEqual(@as(usize, 21 + 53 + 1), n);
}

test "writer matches reference on spiced documents" {
    var label: [256]u8 = undefined;
    for (all_files) |f| {
        if (!support.isXml(f)) continue;
        var doc = try yorc.xml.parse(gpa, f.data, .{}, null);
        defer doc.deinit();
        for (allowed, 0..) |suffix, i| {
            const what = std.fmt.bufPrint(&label, "{s} allowed case {d}", .{ f.name, i }) catch f.name;
            try spiced(what, &doc.root, suffix, null);
        }
        for (forbidden, 0..) |suffix, i| {
            const what = std.fmt.bufPrint(&label, "{s} forbidden case {d}", .{ f.name, i }) catch f.name;
            try spiced(what, &doc.root, suffix, null);
        }
    }
}

// One value at a time: the forbidden suffix in a single text or attribute
// value, at evenly spaced positions of the walk (every one for small
// documents), so both writers fail at that value's path, and at none if the
// value is not written.
test "writer matches reference with one forbidden value at a time" {
    var label: [256]u8 = undefined;
    for (all_files) |f| {
        if (!support.isXml(f)) continue;
        var doc = try yorc.xml.parse(gpa, f.data, .{}, null);
        defer doc.deinit();
        var arena: std.heap.ArenaAllocator = .init(gpa);
        defer arena.deinit();
        const n = try textCount(arena.allocator(), &doc.root);
        if (n == 0) continue;
        const points: usize = @min(n, if (f.data.len > 200_000) @as(usize, 12) else 48);
        for (0..points) |j| {
            const index = if (points == 1) 0 else j * (n - 1) / (points - 1);
            const suffix = forbidden[j % forbidden.len];
            const what = std.fmt.bufPrint(&label, "{s} text {d} of {d}, forbidden case {d}", .{ f.name, index, n, j % forbidden.len }) catch f.name;
            try spiced(what, &doc.root, suffix, index);
        }
    }
}

test "writer matches reference on bulk documents" {
    var label: [256]u8 = undefined;
    for (fixtures.write_samples) |f| {
        if (!support.isXml(f)) continue;
        var doc = try yorc.xml.parse(gpa, f.data, .{}, null);
        defer doc.deinit();

        // as yorc-rs's writer_matches_reference_on_bulk_works: a work
        // twice in a bulk document, and 100 times
        const w = switch (doc.root) {
            .work => |x| x,
            else => continue,
        };
        var arena: std.heap.ArenaAllocator = .init(gpa);
        defer arena.deinit();
        const items = try arena.allocator().alloc(model.BulkItem, 100);
        @memset(items, .{ .work = w });
        for ([_]usize{ 2, items.len }) |count| {
            const bulk: model.Root = .{ .bulk = .{ .items = items[0..count] } };
            const what = std.fmt.bufPrint(&label, "{s} x{d}", .{ f.name, count }) catch f.name;
            try expectSame(what, &bulk);
        }

        // the work on escapes, multi-byte text and forbidden values
        for (allowed ++ forbidden, 0..) |suffix, i| {
            var sp: Spice = .{ .a = arena.allocator(), .suffix = suffix };
            const copy: model.Root = .{ .work = try sp.value(w) };
            const what = std.fmt.bufPrint(&label, "{s} work case {d}", .{ f.name, i }) catch f.name;
            try expectSame(what, &copy);
        }
    }
}

test "writer matches reference on edge values" {
    const min = std.math.minInt(i64);
    const max = std.math.maxInt(i64);
    const roots = [_]model.Root{
        .{ .work = .{
            .meta = .{ .put_code = min, .display_index = -1, .path = "", .visibility = .{ .other = "secret & \"odd\"" } },
            .title = .{ .title = "", .subtitle = "", .translated_title = .{ .value = "", .language_code = "" } },
            .publication_date = .{ .year = -5, .month = 0, .day = 123 },
            .url = "",
            .country = .{ .value = null },
        } },
        .{ .work = .{
            .meta = .{ .put_code = max, .display_index = 0, .display_index_text = "-1" },
            .publication_date = .{ .year = 12345, .month = -1 },
            .work_type = .{ .other = "a<b" },
        } },
        .{ .work = .{ .publication_date = .{} } },
        .{ .credit_name = null },
        .{ .credit_name = "" },
        .{ .credit_name = "x & y" },
        .{ .credit_name = "x\x02" },
        .{ .unknown = "nonsense" },
        .{ .@"error" = .{ .response_code = 409, .error_code = min, .developer_message = "a\r\nb" } },
        .{ .search = .{ .num_found = 0, .results = &.{ .{ .path = "0000-0002-1825-0097" }, .{} } } },
        .{ .search = .{} },
        .{ .expanded_search = .{ .num_found = -3, .results = &.{.{
            .orcid_id = "0000-0002-1825-0097",
            .other_names = &.{ "a", "", "c&d" },
            .emails = &.{"x@example.org"},
            .institution_names = &.{ "U\u{FFFD}", "\u{FF0C}" },
        }} } },
        .{ .history = .{ .claimed = true, .verified_email = false, .verified_primary_email = true } },
        .{ .email = .{ .verified = true, .primary = false, .email = "\"q\"@x" } },
        .{ .bulk = .{} },
        .{ .funding = .{ .contributors = &.{.{ .attributes = .{ .sequence = .{ .known = .first } } }} } },
        .{ .funding = .{ .contributors = &.{.{ .credit_name = "bad\x03", .attributes = .{ .sequence = .{ .known = .first } } }} } },
        .{ .keyword = .{ .meta = .{ .path = "\t\n\r", .source = .{ .source_name = "\u{FFFE}" } } } },
        .{ .record = .{} },
        .{ .person = .{ .biography = .{ .content = "" } } },
    };
    var label: [64]u8 = undefined;
    for (&roots, 0..) |*r, i| {
        const what = std.fmt.bufPrint(&label, "edge value {d}", .{i}) catch "edge value";
        try expectSame(what, r);
    }
}

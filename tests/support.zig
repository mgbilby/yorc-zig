//! Shared helpers for the integration tests: an XML canonicaliser (namespace
//! URI + local name, sorted attributes, trimmed text, no comments/PIs/
//! `xmlns`/`xsi:*`, data-less elements dropped), a canonical-tree diff, a
//! normalised JSON comparison, and model comparison with a readable path.
//! The same rules as yorc-rs's tests/support.
const std = @import("std");
const yorc = @import("yorc");
const fixtures = @import("fixtures");

const Allocator = std.mem.Allocator;
const scan = yorc.xml.scan;
const utf8 = yorc.utf8;

pub const File = fixtures.File;

pub fn isXml(f: File) bool {
    return std.mem.endsWith(u8, f.name, ".xml");
}

pub fn isJson(f: File) bool {
    return std.mem.endsWith(u8, f.name, ".json");
}

// ============================================================ canonical XML

pub const Attr = struct { key: []const u8, value: []const u8 };

/// Canonical element.
pub const C = struct {
    ns: []const u8,
    name: []const u8,
    attrs: []const Attr,
    text: []const u8,
    kids: []C,
};

const Scope = struct { prefix: []const u8, uri: []const u8 };

const Open = struct {
    prefix: []const u8,
    name: []const u8,
    attrs: std.ArrayList(Attr),
    scope: std.ArrayList(Scope),
    text: std.ArrayList(u8),
    kids: std.ArrayList(C),
};

fn attrLess(_: void, a: Attr, b: Attr) bool {
    return std.mem.lessThan(u8, a.key, b.key);
}

fn resolve(prefix: []const u8, own: []const Scope, stack: []const Open) []const u8 {
    var i = own.len;
    while (i > 0) {
        i -= 1;
        if (std.mem.eql(u8, own[i].prefix, prefix)) return own[i].uri;
    }
    var j = stack.len;
    while (j > 0) {
        j -= 1;
        const sc = stack[j].scope.items;
        var k = sc.len;
        while (k > 0) {
            k -= 1;
            if (std.mem.eql(u8, sc[k].prefix, prefix)) return sc[k].uri;
        }
    }
    return "unbound";
}

fn startOpen(a: Allocator, st: scan.Start) !Open {
    var o: Open = .{
        .prefix = scan.prefixOf(st.name),
        .name = scan.localName(st.name),
        .attrs = .empty,
        .scope = .empty,
        .text = .empty,
        .kids = .empty,
    };
    var it = st.attributes();
    while (try it.next()) |at| {
        var value: std.ArrayList(u8) = .empty;
        try scan.decodeText(&value, a, at.raw_value);
        if (std.mem.eql(u8, at.name, "xmlns")) {
            try o.scope.append(a, .{ .prefix = "", .uri = value.items });
        } else if (std.mem.startsWith(u8, at.name, "xmlns:")) {
            try o.scope.append(a, .{ .prefix = at.name[6..], .uri = value.items });
        } else if (std.mem.startsWith(u8, at.name, "xsi:")) {
            continue;
        } else {
            const v = utf8.trimUnicode(value.items);
            var replaced = false;
            for (o.attrs.items) |*x| {
                if (std.mem.eql(u8, x.key, at.name)) {
                    x.value = v;
                    replaced = true;
                }
            }
            if (!replaced) try o.attrs.append(a, .{ .key = at.name, .value = v });
        }
    }
    return o;
}

fn finish(a: Allocator, o: *Open, stack: []Open, root: *?C) !void {
    const own = o.scope.items;
    const parents = stack;
    const ns = resolve(o.prefix, own, parents);
    var text = utf8.trimUnicode(o.text.items);
    if (o.kids.items.len > 0) text = "";
    std.mem.sort(Attr, o.attrs.items, {}, attrLess);
    const el: C = .{ .ns = ns, .name = o.name, .attrs = o.attrs.items, .text = text, .kids = o.kids.items };
    const keep = !(text.len == 0 and el.attrs.len == 0 and el.kids.len == 0);
    if (stack.len > 0) {
        if (keep) try stack[stack.len - 1].kids.append(a, el);
    } else {
        root.* = el;
    }
}

/// Canonical form of an XML document (memory from `a`, typically an arena).
pub fn canonical(a: Allocator, xml: []const u8) !C {
    var stack: std.ArrayList(Open) = .empty;
    var root: ?C = null;
    var sc: scan.Scanner = .init(xml);
    while (true) {
        switch (try sc.next()) {
            .eof => break,
            .start => |st| {
                var o = try startOpen(a, st);
                if (st.empty) {
                    try finish(a, &o, stack.items, &root);
                } else {
                    try stack.append(a, o);
                }
            },
            .end => {
                var o = stack.pop() orelse return error.Unbalanced;
                try finish(a, &o, stack.items, &root);
            },
            .text => |raw| if (stack.items.len > 0) {
                try scan.decodeText(&stack.items[stack.items.len - 1].text, a, raw);
            },
            .cdata => |raw| if (stack.items.len > 0) {
                try stack.items[stack.items.len - 1].text.appendSlice(a, raw);
            },
        }
    }
    return root orelse error.NoRoot;
}

/// First difference between two canonical trees (a description in `out`),
/// or false if none.
pub fn diff(a: Allocator, x: C, y: C, path: []const u8, out: *[]const u8) Allocator.Error!bool {
    const here = try std.fmt.allocPrint(a, "{s}/{s}", .{ path, x.name });
    if (!std.mem.eql(u8, x.ns, y.ns) or !std.mem.eql(u8, x.name, y.name)) {
        out.* = try std.fmt.allocPrint(a, "{s}: element {{{s}}}{s} vs {{{s}}}{s}", .{ here, x.ns, x.name, y.ns, y.name });
        return true;
    }
    var attrs_equal = x.attrs.len == y.attrs.len;
    if (attrs_equal) {
        for (x.attrs, y.attrs) |p, q| {
            if (!std.mem.eql(u8, p.key, q.key) or !std.mem.eql(u8, p.value, q.value)) attrs_equal = false;
        }
    }
    if (!attrs_equal) {
        out.* = try std.fmt.allocPrint(a, "{s}: attributes differ ({d} vs {d})", .{ here, x.attrs.len, y.attrs.len });
        return true;
    }
    if (!std.mem.eql(u8, x.text, y.text)) {
        out.* = try std.fmt.allocPrint(a, "{s}: text \"{s}\" vs \"{s}\"", .{ here, x.text, y.text });
        return true;
    }
    const n = @min(x.kids.len, y.kids.len);
    for (0..n) |i| {
        const p = try std.fmt.allocPrint(a, "{s}[{d}]", .{ here, i });
        if (try diff(a, x.kids[i], y.kids[i], p, out)) return true;
    }
    if (x.kids.len != y.kids.len) {
        out.* = try std.fmt.allocPrint(a, "{s}: {d} vs {d} children", .{ here, x.kids.len, y.kids.len });
        return true;
    }
    return false;
}

/// Removes every element `{ns}name` from a canonical tree.
pub fn prune(c: *C, ns: []const u8, name: []const u8) void {
    var w: usize = 0;
    for (c.kids) |k| {
        if (std.mem.eql(u8, k.ns, ns) and std.mem.eql(u8, k.name, name)) continue;
        c.kids[w] = k;
        w += 1;
    }
    c.kids = c.kids[0..w];
    for (c.kids) |*k| prune(k, ns, name);
}

/// Fails the test (printing the difference) if the canonical forms differ.
pub fn expectSameXml(gpa: Allocator, expected: C, actual: C, label: []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var msg: []const u8 = "";
    if (try diff(arena.allocator(), expected, actual, "", &msg)) {
        std.debug.print("{s}: XML differs: {s}\n", .{ label, msg });
        return error.TestXmlDiffers;
    }
}

// ========================================================= model comparison

/// Fails the test with the path of the first difference.
pub fn expectSameModel(gpa: Allocator, expected: anytype, actual: @TypeOf(expected), label: []const u8) !void {
    var path: std.ArrayList(u8) = .empty;
    defer path.deinit(gpa);
    if (!try yorc.model.firstDifference(expected, actual, &path, gpa)) {
        std.debug.print("{s}: model differs at {s}\n", .{ label, path.items });
        return error.TestModelDiffers;
    }
}

/// Document equality as yorc-rs's derived `PartialEq`: root name, root
/// path and root.
pub fn expectSameDocument(gpa: Allocator, a: yorc.Document, b: yorc.Document, label: []const u8) !void {
    if (!std.mem.eql(u8, a.root_name, b.root_name)) {
        std.debug.print("{s}: root name {s} vs {s}\n", .{ label, a.root_name, b.root_name });
        return error.TestModelDiffers;
    }
    if (!yorc.model.eql(a.root_path, b.root_path)) {
        std.debug.print("{s}: root path differs\n", .{label});
        return error.TestModelDiffers;
    }
    try expectSameModel(gpa, a.root, b.root, label);
}

// ========================================================= normalised JSON

/// A normalised JSON value: scalars as trimmed text, `{"value": x}`
/// unwrapped, nulls / empty strings / empty arrays / empty objects removed.
pub const N = union(enum) {
    str: []const u8,
    arr: []const N,
    obj: []const NField,
};

pub const NField = struct { key: []const u8, val: N };

fn numberText(a: Allocator, raw: []const u8) Allocator.Error![]const u8 {
    if (std.json.isNumberFormattedLikeAnInteger(raw)) {
        if (std.fmt.parseInt(i64, raw, 10)) |v| return std.fmt.allocPrint(a, "{d}", .{v}) else |_| {}
    }
    return raw;
}

pub fn norm(a: Allocator, v: *const std.json.Value) Allocator.Error!?N {
    switch (v.*) {
        .null => return null,
        .string => |s| {
            const t = utf8.trimUnicode(s);
            return if (t.len == 0) null else .{ .str = t };
        },
        .number_string => |s| return .{ .str = try numberText(a, s) },
        .integer => |i| return .{ .str = try std.fmt.allocPrint(a, "{d}", .{i}) },
        .float => |f| return .{ .str = try std.fmt.allocPrint(a, "{d}", .{f}) },
        .bool => |b| return .{ .str = if (b) "true" else "false" },
        .array => |arr| {
            var items: std.ArrayList(N) = .empty;
            for (arr.items) |*x| if (try norm(a, x)) |n| try items.append(a, n);
            return if (items.items.len == 0) null else .{ .arr = items.items };
        },
        .object => |*o| {
            if (o.count() == 1) {
                if (o.getPtr("value")) |inner| return norm(a, inner);
            }
            var fields: std.ArrayList(NField) = .empty;
            var it = o.iterator();
            while (it.next()) |e| {
                if (try norm(a, e.value_ptr)) |n| try fields.append(a, .{ .key = e.key_ptr.*, .val = n });
            }
            return if (fields.items.len == 0) null else .{ .obj = fields.items };
        },
    }
}

fn field(fields: []const NField, k: []const u8) ?N {
    for (fields) |f| if (std.mem.eql(u8, f.key, k)) return f.val;
    return null;
}

/// First difference between two normalised values, as a description.
pub fn firstJsonDifference(a: Allocator, x: N, y: N, path: []const u8) Allocator.Error!?[]const u8 {
    switch (x) {
        .obj => |xo| switch (y) {
            .obj => |yo| {
                for ([_][]const NField{ xo, yo }) |side| {
                    for (side) |f| {
                        const p = field(xo, f.key);
                        const q = field(yo, f.key);
                        const here = try std.fmt.allocPrint(a, "{s}/{s}", .{ path, f.key });
                        if (p == null or q == null) return try std.fmt.allocPrint(a, "{s}: present on one side only", .{here});
                        if (try firstJsonDifference(a, p.?, q.?, here)) |d| return d;
                    }
                }
                return null;
            },
            else => return try std.fmt.allocPrint(a, "{s}: object vs non-object", .{path}),
        },
        .arr => |xa| switch (y) {
            .arr => |ya| {
                for (xa[0..@min(xa.len, ya.len)], ya[0..@min(xa.len, ya.len)], 0..) |p, q, i| {
                    if (try firstJsonDifference(a, p, q, try std.fmt.allocPrint(a, "{s}[{d}]", .{ path, i }))) |d| return d;
                }
                if (xa.len != ya.len) return try std.fmt.allocPrint(a, "{s}: {d} vs {d} items", .{ path, xa.len, ya.len });
                return null;
            },
            else => return try std.fmt.allocPrint(a, "{s}: array vs non-array", .{path}),
        },
        .str => |xs| switch (y) {
            .str => |ys| return if (std.mem.eql(u8, xs, ys)) null else try std.fmt.allocPrint(a, "{s}: \"{s}\" vs \"{s}\"", .{ path, xs, ys }),
            else => return try std.fmt.allocPrint(a, "{s}: scalar vs container", .{path}),
        },
    }
}

/// Parses JSON text with numbers kept as text.
pub fn parseJson(a: Allocator, text: []const u8) !std.json.Value {
    return std.json.parseFromSliceLeaky(std.json.Value, a, text, .{ .parse_numbers = false, .duplicate_field_behavior = .use_last });
}

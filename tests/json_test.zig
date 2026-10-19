//! ORCID JSON: every JSON sample round-trips and matches the original
//! (normalised), JSON → XML → model gives the same model, and every XML
//! sample → JSON → model gives the same model (timestamps compare as
//! instants). yorc-rs's tests/json_roundtrip.rs, minus xmllint.
const std = @import("std");
const yorc = @import("yorc");
const fixtures = @import("fixtures");
const support = @import("support.zig");

const testing = std.testing;
const gpa = testing.allocator;

/// Document kind of a JSON sample, from its file name; null for the one
/// sample outside the record model.
fn kindOfSample(name: []const u8) ?[]const u8 {
    const kinds = [_][2][]const u8{
        .{ "record-full", "record" },
        .{ "address", "address" },
        .{ "bulk-", "bulk" },
        .{ "distinction", "distinction" },
        .{ "education", "education" },
        .{ "employment", "employment" },
        .{ "external-identifier", "external-identifier" },
        .{ "funding", "funding" },
        .{ "invited-position", "invited-position" },
        .{ "keywords", "keyword" }, // a single keyword despite the name
        .{ "membership", "membership" },
        .{ "other-names", "other-name" }, // a single other name
        .{ "peer-review-group-id", "" }, // group-id-3.0, not a record document
        .{ "peer-review", "peer-review" },
        .{ "qualification", "qualification" },
        .{ "research-resource", "research-resource" },
        .{ "researcher-url", "researcher-url" },
        .{ "service", "service" },
        .{ "work", "work" },
    };
    for (kinds) |k| {
        if (std.mem.startsWith(u8, name, k[0])) return if (k[1].len == 0) null else k[1];
    }
    std.debug.panic("no kind for {s}", .{name});
}

const Sample = struct { file: fixtures.File, kind: []const u8 };

fn jsonSamples(out: *std.ArrayList(Sample)) !void {
    for ([_][]const fixtures.File{ &fixtures.read_samples, &fixtures.write_samples }) |set| {
        for (set) |f| {
            if (!support.isJson(f)) continue;
            if (kindOfSample(f.name)) |k| try out.append(gpa, .{ .file = f, .kind = k });
        }
    }
}

test "JSON samples round-trip and match the original" {
    var samples: std.ArrayList(Sample) = .empty;
    defer samples.deinit(gpa);
    try jsonSamples(&samples);
    try testing.expectEqual(@as(usize, 27), samples.items.len);
    for (samples.items) |s| {
        var diag: yorc.Diagnostic = .{};
        var doc = yorc.json.parse(gpa, s.kind, s.file.data, &diag) catch |err| {
            std.debug.print("{s}: {s}\n", .{ s.file.name, diag.message });
            return err;
        };
        defer doc.deinit();
        const written = try yorc.json.toOwned(gpa, &doc.root, null);
        defer gpa.free(written);
        var again = try yorc.json.parse(gpa, s.kind, written, null);
        defer again.deinit();
        try support.expectSameModel(gpa, doc.root, again.root, s.file.name);
        const rewritten = try yorc.json.toOwned(gpa, &again.root, null);
        defer gpa.free(rewritten);
        try testing.expectEqualStrings(written, rewritten);

        // same content as the original, up to wrapping, nulls and number/string form
        var arena: std.heap.ArenaAllocator = .init(gpa);
        defer arena.deinit();
        const a = arena.allocator();
        const original_value = try support.parseJson(a, s.file.data);
        const ours_value = try support.parseJson(a, written);
        const original = try support.norm(a, &original_value);
        const ours = try support.norm(a, &ours_value);
        if (try support.firstJsonDifference(a, original.?, ours.?, s.kind)) |d| {
            std.debug.print("{s}: written JSON differs from the original: {s}\n", .{ s.file.name, d });
            return error.TestJsonDiffers;
        }
    }
}

test "JSON samples through XML give the same model" {
    var samples: std.ArrayList(Sample) = .empty;
    defer samples.deinit(gpa);
    try jsonSamples(&samples);
    for (samples.items) |s| {
        var doc = try yorc.json.parse(gpa, s.kind, s.file.data, null);
        defer doc.deinit();
        var diag: yorc.Diagnostic = .{};
        const x = yorc.xml.toOwned(gpa, &doc.root, &diag) catch |err| {
            std.debug.print("{s}: {f}\n", .{ s.file.name, diag });
            return err;
        };
        defer gpa.free(x);
        var back = try yorc.xml.parse(gpa, x, .{}, null);
        defer back.deinit();
        const j1 = try yorc.json.toOwned(gpa, &doc.root, null);
        defer gpa.free(j1);
        const j2 = try yorc.json.toOwned(gpa, &back.root, null);
        defer gpa.free(j2);
        if (!std.mem.eql(u8, j1, j2)) {
            std.debug.print("{s}: JSON -> XML -> model differs\n", .{s.file.name});
            return error.TestJsonXmlDiffers;
        }
    }
}

const time_elements = [_][]const u8{ "created-date", "last-modified-date", "completion-date", "submission-date", "deactivation-date" };

/// Replaces the text of timestamp elements by epoch milliseconds.
fn stripTimes(a: std.mem.Allocator, c: *support.C) std.mem.Allocator.Error!void {
    if (c.kids.len == 0) {
        for (time_elements) |t| {
            if (std.mem.eql(u8, c.name, t)) {
                if (yorc.json.datetimeToMillis(c.text)) |ms| c.text = try std.fmt.allocPrint(a, "{d}", .{ms});
            }
        }
    }
    for (c.kids) |*k| try stripTimes(a, k);
}

/// Removes the `visibility` attribute of `history` elements: XML-only, the
/// JSON writer leaves it out (src/json.zig module docs).
fn stripHistoryVisibility(a: std.mem.Allocator, c: *support.C) std.mem.Allocator.Error!void {
    if (std.mem.eql(u8, c.name, "history") or std.mem.eql(u8, c.name, "country")) {
        var kept: std.ArrayList(support.Attr) = .empty;
        for (c.attrs) |at| {
            if (!std.mem.eql(u8, at.key, "visibility")) try kept.append(a, at);
        }
        c.attrs = kept.items;
    }
    for (c.kids) |*k| try stripHistoryVisibility(a, k);
}

test "history visibility is XML-only" {
    var doc = try yorc.xml.parse(gpa,
        \\<history:history xmlns:history="http://www.orcid.org/ns/history" visibility="private"><history:creation-method>API</history:creation-method><history:claimed>true</history:claimed></history:history>
    , .{}, null);
    defer doc.deinit();
    const j = try yorc.json.toOwned(gpa, &doc.root, null);
    defer gpa.free(j);
    try testing.expectEqualStrings("{\n  \"claimed\": true,\n  \"creation-method\": \"API\"\n}\n", j);
    // the reader still takes the member
    var back = try yorc.json.parse(gpa, "history",
        \\{"visibility": "private", "creation-method": "DIRECT"}
    , null);
    defer back.deinit();
    try testing.expect(back.root.history.visibility != null);
    try testing.expect(back.root.history.creation_method != null);
}

test "XML samples through JSON give the same model" {
    var n: usize = 0;
    var files: std.ArrayList(fixtures.File) = .empty;
    defer files.deinit(gpa);
    for (fixtures.read_samples) |f| if (support.isXml(f)) try files.append(gpa, f);
    for (fixtures.write_samples) |f| if (support.isXml(f)) try files.append(gpa, f);
    try files.append(gpa, .{ .name = "0000-0003-0100-6634.xml", .data = fixtures.real_record });
    for (files.items) |f| {
        var doc = try yorc.xml.parse(gpa, f.data, .{}, null);
        defer doc.deinit();
        const kind = doc.root.kind().?;
        var diag: yorc.Diagnostic = .{};
        const j = yorc.json.toOwned(gpa, &doc.root, &diag) catch |err| {
            std.debug.print("{s}: {f}\n", .{ f.name, diag });
            return err;
        };
        defer gpa.free(j);
        var back = try yorc.json.parse(gpa, kind, j, null);
        defer back.deinit();
        const j2 = try yorc.json.toOwned(gpa, &back.root, null);
        defer gpa.free(j2);
        if (!std.mem.eql(u8, j, j2)) {
            std.debug.print("{s}: XML -> JSON -> model differs\n", .{f.name});
            return error.TestXmlJsonDiffers;
        }
        // the XML written from the JSON-read model is the same document
        // except for the timestamp spelling and history/@visibility, which
        // the JSON writer leaves out (ORCID's JSON has no such member)
        var arena: std.heap.ArenaAllocator = .init(gpa);
        defer arena.deinit();
        const a = arena.allocator();
        const x1 = try yorc.xml.toOwned(a, &doc.root, null);
        const x2 = try yorc.xml.toOwned(a, &back.root, null);
        var c1 = try support.canonical(a, x1);
        var c2 = try support.canonical(a, x2);
        try stripHistoryVisibility(a, &c1);
        try stripTimes(a, &c1);
        try stripTimes(a, &c2);
        try support.expectSameXml(gpa, c1, c2, f.name);
        n += 1;
    }
    try testing.expectEqual(@as(usize, 75), n);
}

test "bulk JSON shape" {
    const items = [_]yorc.model.BulkItem{
        .{ .work = .{ .title = .{ .title = "A" }, .work_type = .{ .known = .book } } },
        .{ .work = .{ .title = .{ .title = "B" }, .work_type = .{ .known = .book } } },
    };
    const root: yorc.model.Root = .{ .bulk = .{ .items = &items } };
    const out = try yorc.json.toOwned(gpa, &root, null);
    defer gpa.free(out);
    var doc = try yorc.json.parse(gpa, "bulk", out, null);
    defer doc.deinit();
    try testing.expectEqual(@as(usize, 2), doc.root.bulk.items.len);
    try testing.expectEqualStrings("B", doc.root.bulk.items[1].work.title.?.title.?);
}

test "hostile JSON never panics" {
    const inputs = [_][]const u8{
        "",                                                      "null",                                            "{\"put-code\": 1e400}",
        "{\"title\": {\"title\": []}}",                          "{\"external-ids\": {\"external-id\": 5}}",        "{\"created-date\": {\"value\": 1.5}}",
        "{\"created-date\": {\"value\": 99999999999999999999}}", "{\"display-index\": true}",                       "{\"a\": \"\\ud800\"}",
        "\xEF\xBB\xBF{}",                                        "{\"x\": {\"y\": {\"z\": [[[[[[[[[[]]]]]]]]]]}}}",
    };
    for (yorc.model.kinds) |kind| {
        for (inputs) |in| {
            var doc = yorc.json.parse(gpa, kind, in, null) catch continue;
            if (yorc.json.toOwned(gpa, &doc.root, null)) |out| gpa.free(out) else |_| {}
            doc.deinit();
        }
    }
}

// ===================================================== the streaming reader
// json_legacy.zig is the std.json.Value reader json.zig had before; the
// streaming reader must give the same document on every input, or the same
// error and diagnostic.

const legacy = @import("json_legacy.zig");

test "streaming reader: every JSON sample, as its kind and as every kind" {
    for ([_][]const fixtures.File{ &fixtures.read_samples, &fixtures.write_samples }) |set| {
        for (set) |f| {
            if (!support.isJson(f)) continue;
            if (kindOfSample(f.name)) |k| {
                try legacy.expectSameRead(k, f.data, f.name);
                try legacy.expectSameFromValue(k, f.data, false, f.name);
                try legacy.expectSameFromValue(k, f.data, true, f.name);
            }
            // the other kinds read it as a document of the wrong shape
            if (f.data.len > 64 * 1024) continue;
            for (yorc.model.kinds) |kind| try legacy.expectSameRead(kind, f.data, f.name);
        }
    }
}

test "streaming reader: the JSON of every XML sample and the real record" {
    var files: std.ArrayList(fixtures.File) = .empty;
    defer files.deinit(gpa);
    for (fixtures.read_samples) |f| if (support.isXml(f)) try files.append(gpa, f);
    for (fixtures.write_samples) |f| if (support.isXml(f)) try files.append(gpa, f);
    try files.append(gpa, .{ .name = "0000-0003-0100-6634.xml", .data = fixtures.real_record });
    for (files.items) |f| {
        var doc = try yorc.xml.parse(gpa, f.data, .{}, null);
        defer doc.deinit();
        const kind = doc.root.kind().?;
        const j = try yorc.json.toOwned(gpa, &doc.root, null);
        defer gpa.free(j);
        try legacy.expectSameRead(kind, j, f.name);
        try legacy.expectSameFromValue(kind, j, false, f.name);
    }
}

/// Inputs for the lenient-read rules and for syntax errors; each is read as
/// every document kind by both readers.
const lenient_inputs = [_][]const u8{
    // a work with every shape: wrapped and bare text, epoch-ms, lists of one
    \\{"put-code": "12", "display-index": -1, "visibility": "public", "path": "/0000-0002-1825-0097/work/12",
    \\ "created-date": {"value": 1540896558250}, "last-modified-date": 1540896558538,
    \\ "source": {"source-orcid": {"uri": "u", "path": "p", "host": "h"}, "source-name": {"value": " S "}, "source-client-id": null},
    \\ "title": {"title": {"value": "T"}, "subtitle": "S", "translated-title": {"value": "TT", "language-code": "fr"}},
    \\ "journal-title": {"value": "J"}, "short-description": "d", "citation": {"citation-type": "bibtex", "citation-value": "@x"},
    \\ "type": "journal-article", "publication-date": {"year": {"value": "2022"}, "month": "05", "day": 7},
    \\ "external-ids": {"external-id": [{"external-id-type": "doi", "external-id-value": "10.1/X",
    \\   "external-id-normalized": {"value": "10.1/x", "transient": true}, "external-id-url": {"value": "https://doi.org/10.1/X"},
    \\   "external-id-relationship": "self"}, 5, null, {"external-id-type": "isbn", "external-id-normalized": "plain",
    \\   "external-id-normalized-error": {"error-code": "E", "error-message": "m", "transient": "1"}}]},
    \\ "url": "https://bare", "contributors": {"contributor": {"credit-name": "One", "contributor-orcid": {"path": "x"},
    \\   "contributor-attributes": {"contributor-sequence": "first", "contributor-role": "https://credit.niso.org/contributor-roles/x/"}}},
    \\ "language-code": "en", "country": {"value": "NZ", "visibility": "public"}, "unknown": {"deep": [1, {"x": [true, false, null]}]}}
    ,
    // nulls are absent
    \\{"title": null, "external-ids": null, "contributors": null, "country": null, "put-code": null, "created-date": null,
    \\ "amount": null, "organization": null, "path": null, "source": null, "external-id-normalized": null}
    ,
    // duplicate keys: the last one counts, also when it is null
    \\{"title": {"title": "A"}, "title": {"title": "B"}, "url": "u", "url": null, "put-code": 1, "put-code": "2",
    \\ "external-ids": {"external-id": [{"external-id-value": "a"}]},
    \\ "external-ids": {"external-id": {"external-id-value": "b"}, "external-id": []}, "path": "/a", "path": "/b"}
    ,
    // values of the wrong shape
    \\{"title": "plain", "external-ids": [1], "contributors": "x", "publication-date": [2020], "country": [1],
    \\ "amount": ["x"], "source": "s", "url": ["u"], "type": {"value": "book"}, "put-code": {"value": {"value": 7}},
    \\ "external-id-normalized": [1], "organization": "o", "display-index": true, "visibility": 3}
    ,
    // timestamps in every form
    \\{"created-date": {"value": "2018-10-30T10:49:18.250Z"}, "last-modified-date": {"value": 1.5},
    \\ "submission-date": -1, "completion-date": {"value": 99999999999999999999}, "deactivation-date": {"value": {"value": 12}}}
    ,
    \\{"last-modified-date": {"value": null}, "created-date": {"other": 1}, "submission-date": true,
    \\ "completion-date": -0, "deactivation-date": "  "}
    ,
    \\{"last-modified-date": {"value": 1, "value": "text"}, "created-date": [1], "submission-date": {"value": [1]},
    \\ "completion-date": 1e3, "deactivation-date": {"value": -9223372036854775808}}
    ,
    // history: Java enum names, booleans as text
    \\{"creation-method": "MEMBER_REFERRED", "claimed": "true", "verified-email": 1, "verified-primary-email": {"value": false},
    \\ "visibility": "limited", "path": "/p", "locale": "en", "source": {"assertion-origin-name": "a"}}
    ,
    \\{"creation-method": "Member-referred", "claimed": "yes", "verified-email": "0", "verified-primary-email": null}
    ,
    \\{"creation-method": "NEW_THING"}
    ,
    \\{"creation-method": {"value": " API "}}
    ,
    // affiliation groups: summaries wrappers in any order, lists of one, junk
    \\{"path": "/x/employments", "last-modified-date": {"value": 0}, "affiliation-group": [
    \\  {"last-modified-date": {"value": 1}, "external-ids": {"external-id": []},
    \\   "summaries": [{"service-summary": {"put-code": 3}, "employment-summary": [{"put-code": 1}, {"put-code": 2}], "x": 1},
    \\                 {"education-summary": {"department-name": "D", "organization": {"name": "O"}}}, 7, null]},
    \\  {"summaries": {"employment-summary": {"role-title": "R", "start-date": {"year": "1999"}}}},
    \\  {"summaries": {"employment-summary": [{"put-code": 1}], "employment-summary": [{"put-code": 9}]}},
    \\  {"summaries": "none"}, 3]}
    ,
    // activities: every section
    \\{"employments": {"affiliation-group": []}, "educations": null, "services": "x",
    \\ "works": {"group": {"work-summary": {"put-code": 1, "external-ids": {"external-id": {"external-id-value": "w"}}}}},
    \\ "fundings": {"group": [{"funding-summary": [{"title": {"title": {"value": "F"}}, "amount": {"value": "10", "currency-code": "NZD"},
    \\   "organization": {"name": "O", "address": {"city": "C", "region": "R", "country": "NZ"},
    \\   "disambiguated-organization": {"disambiguated-organization-identifier": "1", "disambiguation-source": "ROR"}}}]}]},
    \\ "peer-reviews": {"group": [{"peer-review-group": [{"peer-review-summary": [{"reviewer-role": "reviewer", "review-type": "review",
    \\   "completion-date": {"year": "2019"}, "convening-organization": {"name": "C"}, "review-group-id": "g"}]}]}]},
    \\ "research-resources": {"group": {"research-resource-summary": {"proposal": {"title": {"title": "P"},
    \\   "hosts": {"organization": [{"name": "H"}]}}}}}}
    ,
    // research resources: `resource-item` and `resource-items` both count
    \\{"put-code": 1, "proposal": {"hosts": {"organization": {"name": "H1"}}, "url": {"value": "u"}, "start-date": {"year": 2001}},
    \\ "resource-item": [{"resource-name": "A", "resource-type": "equipment"}],
    \\ "resource-items": {"resource-item": [{"resource-name": "B", "resource-type": "new-type", "hosts": {"organization": {"name": "H2"}}}]}}
    ,
    \\{"resource-items": {"resource-item": {"resource-name": "only wrapped"}}}
    ,
    // bulk: work, error, both, neither
    \\{"bulk": [{"work": {"title": {"title": "W"}}}, {"error": {"response-code": 400, "developer-message": "d", "error-code": "9001"}},
    \\ {"work": "x", "error": {"user-message": "u"}}, {"work": {}, "error": {}}, {}, 3], "path": "/b"}
    ,
    \\{"bulk": {"work": {"put-code": 5}}}
    ,
    // search and expanded search
    \\{"num-found": "2", "result": [{"orcid-identifier": {"path": "0000-0002-1825-0097"}}, {"orcid-identifier": null}, {}]}
    ,
    \\{"num-found": 1, "expanded-result": [{"orcid-id": "x", "given-names": "g", "family-names": {"value": "f"},
    \\ "other-name": ["a", null, {"value": "b"}, [1], 3, " "], "email": "e@x", "institution-name": null}]}
    ,
    // person
    \\{"path": "/0000-0002-1825-0097/person", "last-modified-date": {"value": 5},
    \\ "name": {"given-names": {"value": "G"}, "family-name": "F", "credit-name": {"value": null}, "visibility": "public", "path": "n"},
    \\ "other-names": {"other-name": [{"content": "O", "display-index": 1}, {"content": "P", "display-index": "01"}]},
    \\ "biography": {"content": "B", "visibility": "private"},
    \\ "researcher-urls": {"researcher-url": {"url-name": "n", "url": {"value": "https://x"}}},
    \\ "emails": {"email": [{"email": "e@x", "verified": true, "primary": "0"}]}, "addresses": {"address": {"country": {"value": "NZ"}}},
    \\ "keywords": {"keyword": [{"content": "k"}]},
    \\ "external-identifiers": {"external-identifier": [{"external-id-type": "t", "external-id-value": "v", "external-id-url": "u"}]}}
    ,
    // credit-name documents
    \\{"value": "  C  ", "path": "/p"}
    ,
    \\{"value": {"value": "inner", "x": 1}}
    ,
    \\{"value": {"x": 1}}
    ,
    \\{}
    ,
    // error documents
    \\{"response-code": "-5", "error-code": 9001, "developer-message": "d", "more-info": {"value": "m"}, "path": "/e"}
    ,
    \\{"response-code": 99999999999999999999, "error-code": "+7", "user-message": ["x"]}
    ,
    // a record
    \\{"path": "/0000-0002-1825-0097", "orcid-identifier": {"path": "0000-0002-1825-0097"}, "preferences": {"locale": "en"},
    \\ "history": {"claimed": true, "path": "/h"}, "person": {}, "activities-summary": {}}
    ,
    // escapes, also in keys (an escaped key is the same key)
    \\{"title": {"title": "caf\u00e9 \ud83d\ude00 \"q\" \\ \/ \b\f\n\r\t."}, "ti\u0074le": {"subtitle": "via escaped key"},
    \\ "path": "\u0020/x\u0020", "content": "\u00e9", "\u0063ontent": " \n\t ", "value": "a\u0000b"}
    ,
    // numbers
    \\{"put-code": 12, "display-index": 0, "response-code": -0, "num-found": 1e2, "year": 2.0, "month": 12, "day": 1E1,
    \\ "error-code": 123456789012345678901, "content": -1.5e-3, "url": 0.0}
    ,
    \\{"put-code": 123456789012345678901, "display-index": 2147483648, "publication-date": {"year": 999999999, "month": 1000000000}}
    ,
    " \t\r\n{ \"put-code\" \n:\t1 , \"path\":\"p\"} \n",
    // syntax errors and truncation
    "",
    " ",
    "{",
    "}",
    "[]",
    "1",
    "\"s\"",
    "null",
    "{\"a\"}",
    "{\"a\":}",
    "{\"a\":1,}",
    "{,}",
    "{\"a\":[1,]}",
    "{\"a\":[}",
    "{\"a\":{]}",
    "{\"a\": tru}",
    "{\"a\": nul",
    "{\"a\": 01}",
    "{\"a\": -}",
    "{\"a\": 1.}",
    "{\"a\": 1e}",
    "{\"a\": 1e+}",
    "{\"a\": .5}",
    "{\"a\": +1}",
    "{\"a\": 1",
    "{\"a\": 1.5",
    "{\"a\": -",
    "{\"a\": t",
    "{\"a\": \"\\x\"}",
    "{\"a\": \"\\u12\"}",
    "{\"a\": \"\\u12G4\"}",
    "{\"a\": \"\\ud800\"}",
    "{\"a\": \"\\ud800\\u0041\"}",
    "{\"a\": \"\\udc00\"}",
    "{\"a\": \"\\ud800\\udb00\"}",
    "{\"a\": \"\\ud800\\udc0\"}",
    "{\"a\": \"\\ud800\\",
    "{\"a\": \"\\ud800\\u",
    "{\"a\": \"\\ud800\\uD",
    "{\"a\": \"\\",
    "{\"a\": \"\\u",
    "{\"a\": \"\x01\"}",
    "{\"a\": \"tab\there\"}",
    "{\"a\": \"\x7f\"}",
    "{} x",
    "{}}",
    "{\"a\": 1} {\"b\": 2}",
    "\xEF\xBB\xBF{\"path\": \"bom\"}",
    "{\"a\": \"\xff\"}",
    "{\"a\": \"ok\"} \xc3",
    "{\"a\": #\"1\"}",
    "{\"a\": ~\"1\"}",
    "{\"a\": [1 2]}",
    "{\"a\" : 1 \"b\": 2}",
    "{\"a\": \"x\" , }",
    "[",
    "{\"a\":{\"b\":{\"c\":[[[",
    "\"unterminated",
    "{\"title\": {\"title\": \"T\"}, \"x\": [1, {\"y\": }]}",
    "{\"title\": {\"title\": \"T\"}} trailing",
    "{\"put-code\": 1}\x00",
    "{\"a\": [{}, [], {\"b\": [{}]}], \"c\": {\"d\": [true, false, null, 1, -2.5e+3, \"s\"]}}",
};

test "streaming reader: lenient rules and syntax errors, as every kind" {
    for (lenient_inputs, 0..) |in, i| {
        var label_buf: [32]u8 = undefined;
        const label = try std.fmt.bufPrint(&label_buf, "lenient input {d}", .{i});
        for (yorc.model.kinds) |kind| {
            try legacy.expectSameRead(kind, in, label);
            try legacy.expectSameFromValue(kind, in, false, label);
            try legacy.expectSameFromValue(kind, in, true, label);
        }
        try legacy.expectSameRead("nonsense", in, label);
    }
}

test "streaming reader: fromValue keeps std.json.Value numbers apart" {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var obj: std.json.ObjectMap = .empty;
    try obj.put(a, "put-code", .{ .number_string = "007" });
    try obj.put(a, "display-index", .{ .float = 3.0 });
    try obj.put(a, "created-date", .{ .float = 1.5e12 });
    try obj.put(a, "last-modified-date", .{ .integer = 1_540_896_558_250 });
    try obj.put(a, "path", .{ .number_string = "1.2.3" });
    try obj.put(a, "journal-title", .{ .string = "a\x00b \"q\" \\ \xff" });
    try obj.put(a, "url", .{ .number_string = "-0" });
    var nested: std.json.ObjectMap = .empty;
    try nested.put(a, "value", .{ .float = -0.0 });
    try obj.put(a, "short-description", .{ .object = nested });
    const v: std.json.Value = .{ .object = obj };
    for (yorc.model.kinds) |kind| try legacy.expectSameValue(kind, &v, "hand-built value");

    var doc = try yorc.json.fromValue(gpa, "work", &v, null);
    defer doc.deinit();
    const w = doc.root.work;
    try testing.expectEqual(@as(?i64, 7), w.meta.put_code);
    try testing.expectEqual(@as(?[]const u8, null), w.meta.created_date);
    try testing.expectEqualStrings("2018-10-30T10:49:18.250Z", w.meta.last_modified_date.?);
    try testing.expectEqualStrings("1.2.3", w.meta.path.?);
    try testing.expectEqualStrings("a\x00b \"q\" \\ \xff", w.journal_title.?);
    try testing.expectEqualStrings("-0", w.url.?);
    const one: std.json.Value = .{ .integer = 1 };
    try testing.expectError(error.MalformedJson, yorc.json.fromValue(gpa, "work", &one, null));
}

test "streaming reader: escapes" {
    var doc = try yorc.json.parse(gpa, "keyword",
        \\{"con\u0074ent": "caf\u00e9 \u20AC \ud83d\ude00 \"q\" \\ \/ \b\f\n\r\t."}
    , null);
    defer doc.deinit();
    try testing.expectEqualStrings("café € 😀 \"q\" \\ / \x08\x0c\n\r\t.", doc.root.keyword.content.?);

    const bad = [_]struct { []const u8, []const u8 }{
        .{ "{\"content\": \"\\x\"}", "SyntaxError" },
        .{ "{\"content\": \"\\u12G4\"}", "SyntaxError" },
        .{ "{\"content\": \"\\ud800\"}", "SyntaxError" }, // a high surrogate alone
        .{ "{\"content\": \"\\ud800\\u0041\"}", "SyntaxError" },
        .{ "{\"content\": \"\\ud800\\ud800\"}", "SyntaxError" },
        .{ "{\"content\": \"\\udc00\"}", "SyntaxError" }, // a low surrogate alone
        .{ "{\"content\": \"a\x01b\"}", "SyntaxError" }, // a raw control character
        .{ "{\"content\": \"\\u12", "UnexpectedEndOfInput" },
        .{ "{\"content\": \"\\ud800\\", "UnexpectedEndOfInput" },
        .{ "{\"content\": \"abc", "UnexpectedEndOfInput" },
    };
    for (bad) |c| {
        var d: yorc.Diagnostic = .{};
        try testing.expectError(error.MalformedJson, yorc.json.parse(gpa, "keyword", c[0], &d));
        try testing.expectEqualStrings(c[1], d.message);
    }
}

test "streaming reader: strings across vector widths and indentation" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    for (1..150) |n| {
        buf.clearRetainingCapacity();
        try buf.append(gpa, '{');
        try buf.appendNTimes(gpa, ' ', n);
        try buf.appendSlice(gpa, "\"content\":\"");
        try buf.appendNTimes(gpa, 'x', n);
        try buf.appendSlice(gpa, "\\n");
        try buf.appendNTimes(gpa, 'y', n);
        try buf.appendSlice(gpa, ".\"");
        try buf.appendNTimes(gpa, '\n', n % 3);
        try buf.appendNTimes(gpa, ' ', n);
        try buf.append(gpa, '}');
        var doc = try yorc.json.parse(gpa, "keyword", buf.items, null);
        defer doc.deinit();
        const content = doc.root.keyword.content.?;
        try testing.expectEqual(2 * n + 2, content.len);
        try testing.expectEqual(@as(u8, '\n'), content[n]);
        try legacy.expectSameRead("keyword", buf.items, "vector widths");
    }
}

test "streaming reader: deep nesting reads in bounded native stack" {
    const depth = 100_000;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);

    // skipped: arrays and objects under an unknown key
    try buf.appendSlice(gpa, "{\"unknown\": ");
    for (0..depth) |_| try buf.appendSlice(gpa, "[{\"k\":");
    try buf.appendSlice(gpa, "null");
    for (0..depth) |_| try buf.appendSlice(gpa, "}]");
    try buf.appendSlice(gpa, ", \"put-code\": 7}");
    {
        var doc = try yorc.json.parse(gpa, "work", buf.items, null);
        defer doc.deinit();
        try testing.expectEqual(@as(?i64, 7), doc.root.work.meta.put_code);
    }
    try legacy.expectSameRead("work", buf.items, "deep arrays");

    // the same, truncated, or with a bracket that does not match
    var d: yorc.Diagnostic = .{};
    try testing.expectError(error.MalformedJson, yorc.json.parse(gpa, "work", buf.items[0 .. buf.items.len / 2], &d));
    try testing.expectEqualStrings("UnexpectedEndOfInput", d.message);
    const mid = 12 + 6 * depth + 4; // the `null` ends here; then `}]` repeated
    buf.items[mid + 1] = '}';
    try testing.expectError(error.MalformedJson, yorc.json.parse(gpa, "work", buf.items, &d));
    try testing.expectEqualStrings("SyntaxError", d.message);

    // `{"value": {"value": ...}}` chains, followed iteratively
    buf.clearRetainingCapacity();
    for (0..depth) |_| try buf.appendSlice(gpa, "{\"x\": 1, \"value\": ");
    try buf.appendSlice(gpa, "\"deep\"");
    for (0..depth) |_| try buf.appendSlice(gpa, ", \"y\": [2]}");
    {
        var doc = try yorc.json.parse(gpa, "credit-name", buf.items, null);
        defer doc.deinit();
        try testing.expectEqualStrings("deep", doc.root.credit_name.?);
    }
}

test "streaming reader: unknown keys and their nested values are skipped" {
    var doc = try yorc.json.parse(gpa, "work",
        \\{"x": {"title": {"title": "no"}, "url": ["no", {"a": [1, 2.5e-3, true, null, "s\"]}"]}]},
        \\ "title": {"x": [{"title": "no"}], "title": {"value": "yes", "x": {"value": "no"}}},
        \\ "y": "}", "z": [[[], {}], {"": {}}], "url": "u", "": 0}
    , null);
    defer doc.deinit();
    try testing.expectEqualStrings("yes", doc.root.work.title.?.title.?);
    try testing.expectEqualStrings("u", doc.root.work.url.?);
    try testing.expectEqual(@as(?yorc.model.Country, null), doc.root.work.country);
}

test "streaming reader: a duplicate key keeps its last value" {
    var doc = try yorc.json.parse(gpa, "work",
        \\{"title": {"title": "A"}, "title": {"title": "B"}, "url": "u", "url": null,
        \\ "put-code": 1, "put-code": "2", "type": "book", "type": "nonsense",
        \\ "external-ids": {"external-id": [{"external-id-value": "a"}, {"external-id-value": "b"}]},
        \\ "external-ids": {"external-id": {"external-id-value": "c"}}}
    , null);
    defer doc.deinit();
    const w = doc.root.work;
    try testing.expectEqualStrings("B", w.title.?.title.?);
    try testing.expectEqual(@as(?[]const u8, null), w.url);
    try testing.expectEqual(@as(?i64, 2), w.meta.put_code);
    try testing.expectEqualStrings("nonsense", w.work_type.?.other);
    try testing.expectEqual(@as(usize, 1), w.external_ids.len);
    try testing.expectEqualStrings("c", w.external_ids[0].value.?);
}

test "streaming reader: numbers as strings and as numbers" {
    var doc = try yorc.json.parse(gpa, "work",
        \\{"put-code": "12", "display-index": 3, "publication-date": {"year": 2020, "month": "07", "day": {"value": 9}},
        \\ "created-date": {"value": 1540896558250}, "last-modified-date": {"value": "1540896558250"},
        \\ "journal-title": 1.50, "language-code": -0, "short-description": 12345678901234567890}
    , null);
    defer doc.deinit();
    const w = doc.root.work;
    try testing.expectEqual(@as(?i64, 12), w.meta.put_code);
    try testing.expectEqual(@as(?i32, 3), w.meta.display_index);
    try testing.expectEqual(@as(?[]const u8, null), w.meta.display_index_text);
    try testing.expectEqual(@as(?i32, 2020), w.publication_date.?.year);
    try testing.expectEqual(@as(?i32, 7), w.publication_date.?.month);
    try testing.expectEqual(@as(?i32, 9), w.publication_date.?.day);
    // epoch milliseconds become xs:dateTime; a string stays as it is
    try testing.expectEqualStrings("2018-10-30T10:49:18.250Z", w.meta.created_date.?);
    try testing.expectEqualStrings("1540896558250", w.meta.last_modified_date.?);
    // numbers where the model keeps text: as written
    try testing.expectEqualStrings("1.50", w.journal_title.?);
    try testing.expectEqualStrings("-0", w.language_code.?);
    try testing.expectEqualStrings("12345678901234567890", w.short_description.?);

    // timestamps that are not i64 milliseconds are absent
    var odd = try yorc.json.parse(gpa, "work", "{\"created-date\": 1.5e3, \"last-modified-date\": {\"value\": 99999999999999999999}}", null);
    defer odd.deinit();
    try testing.expectEqual(@as(?[]const u8, null), odd.root.work.meta.created_date);
    try testing.expectEqual(@as(?[]const u8, null), odd.root.work.meta.last_modified_date);
}

//! Fuzz entry points (`zig build test --fuzz`): the XML reader (and writing
//! back what was read), the iD normaliser, and the JSON reader for every
//! document kind (the first byte picks the kind), checked against the
//! std.json reader it replaced (json_legacy.zig). Under plain `zig build
//! test` each runs once. Mirrors yorc-rs's XML and JSON fuzz targets.
const std = @import("std");
const yorc = @import("yorc");
const legacy = @import("json_legacy.zig");

const testing = std.testing;

const Xml = struct {
    fn testOne(_: Xml, smith: *testing.Smith) anyerror!void {
        var buf: [4096]u8 = undefined;
        const bytes = buf[0..smith.slice(&buf)];
        const gpa = testing.allocator;
        if (yorc.xml.parse(gpa, bytes, .{}, null)) |doc_val| {
            var doc = doc_val;
            defer doc.deinit();
            // whatever was read can be written, or is refused cleanly
            if (yorc.xml.toOwned(gpa, &doc.root, null)) |out| gpa.free(out) else |_| {}
        } else |_| {}
        if (yorc.id.normalize(bytes)) |id| {
            try testing.expect(yorc.id.isValid(&id));
            const again = yorc.id.normalize(&id).?;
            try testing.expectEqualSlices(u8, &id, &again);
        }
    }
};

const Json = struct {
    fn testOne(_: Json, smith: *testing.Smith) anyerror!void {
        var buf: [4096]u8 = undefined;
        const bytes = buf[0..smith.slice(&buf)];
        if (bytes.len == 0) return;
        const gpa = testing.allocator;
        const kind = yorc.model.kinds[bytes[0] % yorc.model.kinds.len];
        // the streaming reader reads what the std.json reader it replaced read
        try legacy.expectSameRead(kind, bytes[1..], "fuzz input");
        if (yorc.json.parse(gpa, kind, bytes[1..], null)) |doc_val| {
            var doc = doc_val;
            defer doc.deinit();
            // what was read can be written again
            if (yorc.json.toOwned(gpa, &doc.root, null)) |out| gpa.free(out) else |_| {}
        } else |_| {}
    }
};

test "fuzz the XML reader and the iD normaliser" {
    try testing.fuzz(Xml{}, Xml.testOne, .{});
}

test "fuzz the JSON reader" {
    try testing.fuzz(Json{}, Json.testOne, .{});
}

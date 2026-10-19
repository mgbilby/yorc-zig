//! The client against a local mock server (std.Io.net on 127.0.0.1, one
//! thread, one connection per request): methods, paths, headers and bodies
//! are asserted; canned responses include 429 + Retry-After, 5xx, error-3.0
//! bodies, a 301 that must not be followed and the `/read-public` token
//! endpoint. The client reads ORCID's Public API only (no Member API, no
//! Sandbox). The cases of yorc-rs's tests/blocking_client.rs.
//!
//! Mock servers are local, so every client here is `.custom` with a fast
//! limiter of its own (not paced by the 45 s ORCID limiter). The `.public`
//! host set, forged URLs, token checks and the 45 s clamp are tested as
//! pure functions in src/client.zig.
const std = @import("std");
const yorc = @import("yorc");
const client = @import("yorc_client");
const fixtures = @import("fixtures");

const testing = std.testing;
const gpa = testing.allocator;
const Io = std.Io;

const ID = "0000-0002-1825-0097";

const Reply = struct {
    status: u16,
    content_type: []const u8 = "application/vnd.orcid+xml",
    headers: []const [2][]const u8 = &.{},
    body: []const u8,
};

fn json(status: u16, body: []const u8) Reply {
    return .{ .status = status, .content_type = "application/json", .body = body };
}

const Header = struct { name: []const u8, value: []const u8 };

const Seen = struct {
    method: []const u8,
    path: []const u8,
    headers: []const Header,
    body: []const u8,
    at_ns: i96,

    fn header(s: *const Seen, name: []const u8) ?[]const u8 {
        for (s.headers) |h| if (std.ascii.eqlIgnoreCase(h.name, name)) return h.value;
        return null;
    }
};

/// Serves `script` in order, one connection per request (`Connection: close`).
const Mock = struct {
    server: Io.net.Server,
    base: []const u8,
    script: []const Reply,
    /// Used by the server thread only (page_allocator: thread-safe).
    arena: std.heap.ArenaAllocator,
    seen: std.ArrayList(Seen) = .empty,
    thread: std.Thread,
    joined: bool = false,
    failure: ?anyerror = null,

    fn start(script: []const Reply) !*Mock {
        const io = testing.io;
        const m = try std.heap.page_allocator.create(Mock);
        errdefer std.heap.page_allocator.destroy(m);
        var addr: Io.net.IpAddress = .{ .ip4 = .loopback(0) };
        m.* = .{
            .server = try addr.listen(io, .{ .reuse_address = true }),
            .base = undefined,
            .script = script,
            .arena = .init(std.heap.page_allocator),
            .thread = undefined,
        };
        m.base = try std.fmt.allocPrint(m.arena.allocator(), "http://127.0.0.1:{d}", .{m.server.socket.address.getPort()});
        m.thread = try std.Thread.spawn(.{}, serve, .{m});
        return m;
    }

    fn serve(m: *Mock) void {
        for (m.script) |reply| {
            m.serveOne(reply) catch |err| {
                m.failure = err;
                return;
            };
        }
    }

    fn serveOne(m: *Mock, reply: Reply) !void {
        const io = testing.io;
        const a = m.arena.allocator();
        const stream = try m.server.accept(io);
        defer stream.close(io);
        var rbuf: [16 * 1024]u8 = undefined;
        var sr = stream.reader(io, &rbuf);
        const r = &sr.interface;
        const line = std.mem.trimEnd(u8, try r.takeDelimiterInclusive('\n'), "\r\n");
        var parts = std.mem.tokenizeScalar(u8, line, ' ');
        const method = try a.dupe(u8, parts.next() orelse "");
        const path = try a.dupe(u8, parts.next() orelse "");
        var headers: std.ArrayList(Header) = .empty;
        var length: usize = 0;
        while (true) {
            const h = std.mem.trimEnd(u8, try r.takeDelimiterInclusive('\n'), "\r\n");
            if (h.len == 0) break;
            const colon = std.mem.indexOfScalar(u8, h, ':') orelse continue;
            const k = std.mem.trim(u8, h[0..colon], " ");
            const v = std.mem.trim(u8, h[colon + 1 ..], " ");
            if (std.ascii.eqlIgnoreCase(k, "content-length")) length = try std.fmt.parseInt(usize, v, 10);
            try headers.append(a, .{ .name = try a.dupe(u8, k), .value = try a.dupe(u8, v) });
        }
        const body = try a.alloc(u8, length);
        try r.readSliceAll(body);
        try m.seen.append(a, .{
            .method = method,
            .path = path,
            .headers = headers.items,
            .body = body,
            .at_ns = Io.Timestamp.now(io, .awake).nanoseconds,
        });
        var wbuf: [4096]u8 = undefined;
        var sw = stream.writer(io, &wbuf);
        const w = &sw.interface;
        try w.print("HTTP/1.1 {d} X\r\nContent-Length: {d}\r\nConnection: close\r\nContent-Type: {s}\r\n", .{ reply.status, reply.body.len, reply.content_type });
        for (reply.headers) |h| try w.print("{s}: {s}\r\n", .{ h[0], h[1] });
        try w.writeAll("\r\n");
        try w.writeAll(reply.body);
        try w.flush();
    }

    /// A `.custom` access to this server.
    fn access(m: *const Mock) !client.Access {
        const a = @constCast(&m.arena).allocator();
        return .{ .custom = .{
            .api = try std.fmt.allocPrint(a, "{s}/v3.0", .{m.base}),
            .oauth = try std.fmt.allocPrint(a, "{s}/oauth", .{m.base}),
        } };
    }

    /// What the server saw so far.
    fn seenNow(m: *Mock) usize {
        return m.seen.items.len;
    }

    /// Waits for the script to finish and returns what the server saw. The
    /// Mock is freed by `deinit`.
    fn finish(m: *Mock) ![]const Seen {
        m.thread.join();
        m.joined = true;
        if (m.failure) |e| return e;
        return m.seen.items;
    }

    /// After a failed test the server thread may still wait for a
    /// connection; the Mock is then left alone (leaked) rather than freed
    /// under it.
    fn deinit(m: *Mock) void {
        if (!m.joined) return;
        m.server.deinit(testing.io);
        m.arena.deinit();
        std.heap.page_allocator.destroy(m);
    }
};

const Fixture = struct {
    mock: *Mock,
    limiter: *client.RateLimiter,
    token: ?*client.Token,
    c: client.Client,

    /// A client of the mock; `scope` non-null: `Config.token` is "tok" of
    /// the custom realm with that scope.
    fn init(script: []const Reply, scope: ?[]const u8) !Fixture {
        const m = try Mock.start(script);
        const lim = try gpa.create(client.RateLimiter);
        lim.* = .init(testing.io, 1000.0);
        var tok: ?*client.Token = null;
        if (scope) |sc| {
            const t = try gpa.create(client.Token);
            t.* = try client.Token.init(gpa, .custom, "tok", sc);
            tok = t;
        }
        return .{
            .mock = m,
            .limiter = lim,
            .token = tok,
            .c = try client.Client.init(gpa, testing.io, .{
                .access = try m.access(),
                .token = tok,
                .backoff_base_ms = 10,
                .max_retries = 3,
            }, lim),
        };
    }

    fn finish(f: *Fixture) ![]const Seen {
        f.c.deinit();
        gpa.destroy(f.limiter);
        if (f.token) |t| {
            t.deinit();
            gpa.destroy(t);
        }
        return f.mock.finish();
    }
};

fn expectGet(s: Seen, path: []const u8, accept: []const u8, auth: ?[]const u8) !void {
    try testing.expectEqualStrings("GET", s.method);
    try testing.expectEqualStrings(path, s.path);
    try testing.expectEqualStrings(accept, s.header("accept").?);
    if (auth) |want| {
        try testing.expectEqualStrings(want, s.header("authorization").?);
    } else {
        try testing.expect(s.header("authorization") == null);
    }
    try testing.expectEqual(@as(usize, 0), s.body.len);
}

const xml_type = client.xml_media_type;
const read_public = "/read-public";

// ======================================================================= reads

test "reads of any record" {
    const script = [_]Reply{
        .{ .status = 200, .body = fixtures.readSample("record-3.0.xml") },
        .{ .status = 200, .body = fixtures.readSample("person-3.0.xml") },
        .{ .status = 200, .body = fixtures.readSample("works-3.0.xml") },
        .{ .status = 200, .body = fixtures.readSample("work-full-3.0.xml") },
        .{ .status = 200, .body = fixtures.readSample("bulk-work-err.xml") },
        .{ .status = 200, .body = fixtures.readSample("educations-3.0.xml") },
    };
    var f = try Fixture.init(&script, read_public);
    defer f.mock.deinit();
    const c = &f.c;
    {
        var d = try c.record(ID, .xml, null);
        defer d.deinit();
        try testing.expect(d.record().?.person != null);
    }
    {
        var d = try c.person("https://orcid.org/" ++ ID, .xml, null);
        defer d.deinit();
        try testing.expect(d.root.person.name != null);
    }
    {
        var d = try c.works(ID, .xml, null);
        defer d.deinit();
        try testing.expect(d.root.works.groups.len > 0);
    }
    {
        var d = try c.work(ID, 123, .xml, null);
        defer d.deinit();
        try testing.expect(d.root.work.title != null);
    }
    {
        var d = try c.worksBulk(ID, &.{ 1, 2, 3 }, .xml, null);
        defer d.deinit();
        var errors: usize = 0;
        for (d.root.bulk.items) |it| {
            if (it == .@"error") errors += 1;
        }
        try testing.expect(errors > 0);
    }
    {
        var d = try c.section(ID, "educations", .xml, null);
        defer d.deinit();
        try testing.expect(d.root == .affiliations);
    }
    const seen = try f.finish();
    try testing.expectEqual(@as(usize, 6), seen.len);
    const auth = "Bearer tok";
    try expectGet(seen[0], "/v3.0/" ++ ID ++ "/record", xml_type, auth);
    try expectGet(seen[1], "/v3.0/" ++ ID ++ "/person", xml_type, auth);
    try expectGet(seen[2], "/v3.0/" ++ ID ++ "/works", xml_type, auth);
    try expectGet(seen[3], "/v3.0/" ++ ID ++ "/work/123", xml_type, auth);
    try expectGet(seen[4], "/v3.0/" ++ ID ++ "/works/1,2,3", xml_type, auth);
    try expectGet(seen[5], "/v3.0/" ++ ID ++ "/educations", xml_type, auth);
}

test "JSON reads, anonymously" {
    const script = [_]Reply{
        .{ .status = 200, .content_type = client.json_media_type, .body = fixtures.readSample("record-full-3.0.json") },
    };
    var f = try Fixture.init(&script, null);
    defer f.mock.deinit();
    var d = try f.c.record(ID, .json, null);
    defer d.deinit();
    try testing.expect(d.record().?.activities_summary != null);
    const seen = try f.finish();
    try testing.expectEqual(@as(usize, 1), seen.len);
    try expectGet(seen[0], "/v3.0/" ++ ID ++ "/record", client.json_media_type, null);
}

test "bad arguments send nothing" {
    var f = try Fixture.init(&.{}, read_public);
    defer f.mock.deinit();
    const c = &f.c;
    try testing.expectError(error.InvalidOrcidId, c.record("garbage", .xml, null));
    try testing.expectError(error.InvalidOrcidId, c.recordRaw("0000-0002-1825-0098", .xml, null));
    try testing.expectError(error.Usage, c.section(ID, "../0000-0001-5109-3700/record", .xml, null));
    try testing.expectError(error.Usage, c.worksBulk(ID, &.{}, .xml, null));
    var many: [101]yorc.model.PutCode = undefined;
    @memset(&many, 1);
    try testing.expectError(error.Usage, c.worksBulk(ID, &many, .xml, null));
    const seen = try f.finish();
    try testing.expectEqual(@as(usize, 0), seen.len);
}

test "reads retry 5xx, honouring Retry-After" {
    const script = [_]Reply{
        .{ .status = 500, .body = "oops" },
        .{ .status = 503, .headers = &.{.{ "Retry-After", "1" }}, .body = "busy" },
        .{ .status = 200, .body = fixtures.readSample("record-3.0.xml") },
    };
    var f = try Fixture.init(&script, read_public);
    defer f.mock.deinit();
    var d = try f.c.record(ID, .xml, null);
    d.deinit();
    const seen = try f.finish();
    try testing.expectEqual(@as(usize, 3), seen.len);
    const gap = seen[2].at_ns - seen[1].at_ns;
    try testing.expect(gap >= 950 * std.time.ns_per_ms);
}

test "a 429 stops and pauses until Retry-After" {
    const script = [_]Reply{
        .{ .status = 429, .headers = &.{.{ "Retry-After", "1" }}, .body = "" },
        .{ .status = 200, .body = fixtures.readSample("record-3.0.xml") },
    };
    var f = try Fixture.init(&script, read_public);
    defer f.mock.deinit();
    var fail: client.Failure = .{};
    defer fail.deinit(gpa);
    try testing.expectError(error.Api, f.c.record(ID, .xml, &fail));
    try testing.expectEqual(@as(u16, 429), fail.status);
    try testing.expectEqual(@as(usize, 1), f.mock.seenNow()); // not retried
    var d = try f.c.record(ID, .xml, null); // waits for Retry-After
    d.deinit();
    const seen = try f.finish();
    try testing.expectEqual(@as(usize, 2), seen.len);
    try testing.expect(seen[1].at_ns - seen[0].at_ns >= 950 * std.time.ns_per_ms);
}

test "reads give up after max_retries and parse error-3.0" {
    {
        const script = [_]Reply{ .{ .status = 500, .body = "" }, .{ .status = 500, .body = "" }, .{ .status = 500, .body = "" }, .{ .status = 500, .body = "" } };
        var f = try Fixture.init(&script, read_public);
        defer f.mock.deinit();
        var fail: client.Failure = .{};
        defer fail.deinit(gpa);
        try testing.expectError(error.Api, f.c.record(ID, .xml, &fail));
        try testing.expectEqual(@as(u16, 500), fail.status);
        const seen = try f.finish();
        try testing.expectEqual(@as(usize, 4), seen.len); // 1 attempt + 3 retries
    }
    {
        const script = [_]Reply{.{ .status = 404, .body = fixtures.readSample("error-3.0.xml") }};
        var f = try Fixture.init(&script, read_public);
        defer f.mock.deinit();
        var fail: client.Failure = .{};
        defer fail.deinit(gpa);
        try testing.expectError(error.Api, f.c.work(ID, 9, .xml, &fail));
        try testing.expectEqual(@as(u16, 404), fail.status);
        const e = fail.orcidError().?;
        try testing.expectEqualStrings("error:developer-message", e.developer_message.?);
        try testing.expectEqualStrings("http://tempuri.org", e.more_info.?);
        _ = try f.finish();
    }
    {
        const script = [_]Reply{.{ .status = 200, .body = fixtures.readSample("person-3.0.xml") }};
        var f = try Fixture.init(&script, read_public);
        defer f.mock.deinit();
        try testing.expectError(error.Decode, f.c.record(ID, .xml, null));
        _ = try f.finish();
    }
}

test "the optional /read-public token" {
    const script = [_]Reply{
        json(200,
            \\{"access_token":"rp-token","token_type":"bearer","refresh_token":"rp-refresh",
            \\ "expires_in":631138518,"scope":"/read-public","name":null,"orcid":null}
        ),
        json(401,
            \\{"error":"invalid_client","error_description":"Client not found: APP-1234567890ABCDEF"}
        ),
    };
    var f = try Fixture.init(&script, null);
    defer f.mock.deinit();

    var rp = try f.c.readPublicToken("APP-1234567890ABCDEF", "s3cret", null);
    defer rp.deinit();
    try testing.expectEqualStrings("rp-token", rp.access_token);
    try testing.expectEqualStrings("/read-public", rp.scope);
    try testing.expectEqual(client.Realm.custom, rp.realm);
    try testing.expectEqual(@as(?u64, 631_138_518), rp.expires_in);

    var fail: client.Failure = .{};
    defer fail.deinit(gpa);
    try testing.expectError(error.OAuth, f.c.readPublicToken("APP-1234567890ABCDEF", "wrong", &fail));
    try testing.expectEqual(@as(u16, 401), fail.status);
    try testing.expectEqualStrings("invalid_client", fail.oauth_error.?);
    try testing.expectEqualStrings("Client not found: APP-1234567890ABCDEF", fail.oauth_description.?);

    const seen = try f.finish();
    try testing.expectEqual(@as(usize, 2), seen.len);
    for (seen) |t| {
        try testing.expectEqualStrings("POST", t.method);
        try testing.expectEqualStrings("/oauth/token", t.path);
        try testing.expectEqualStrings("application/json", t.header("accept").?);
        try testing.expectEqualStrings("application/x-www-form-urlencoded", t.header("content-type").?);
        try testing.expect(t.header("authorization") == null);
    }
    try testing.expectEqualStrings(
        "client_id=APP-1234567890ABCDEF&client_secret=s3cret&grant_type=client_credentials&scope=%2Fread-public",
        seen[0].body,
    );
}

test "a token request is not retried" {
    // one answer scripted: a retry would find no server
    const script = [_]Reply{json(503, "{}")};
    var f = try Fixture.init(&script, null);
    defer f.mock.deinit();
    try testing.expectError(error.OAuth, f.c.readPublicToken("APP-1", "s", null));
    const seen = try f.finish();
    try testing.expectEqual(@as(usize, 1), seen.len);
}

test "a limiter shared by two clients paces both" {
    const body = fixtures.readSample("record-3.0.xml");
    const script = [_]Reply{ .{ .status = 200, .body = body }, .{ .status = 200, .body = body }, .{ .status = 200, .body = body }, .{ .status = 200, .body = body } };
    const m = try Mock.start(&script);
    defer m.deinit();
    var lim: client.RateLimiter = .init(testing.io, 20.0); // 50 ms apart
    var a = try client.Client.init(gpa, testing.io, .{ .access = try m.access() }, &lim);
    var b = try client.Client.init(gpa, testing.io, .{ .access = try m.access() }, &lim);
    const start = Io.Timestamp.now(testing.io, .awake);
    for ([_]*client.Client{ &a, &b, &a, &b }) |c| {
        var d = try c.record(ID, .xml, null);
        d.deinit();
    }
    const elapsed = start.durationTo(Io.Timestamp.now(testing.io, .awake)).nanoseconds;
    try testing.expect(elapsed >= 140 * std.time.ns_per_ms);
    a.deinit();
    b.deinit();
    _ = try m.finish();
}

test "recordRaw returns the exact bytes and the error documents" {
    // odd but valid bytes: a BOM, CRLF line ends, trailing spaces, non-ASCII
    const exact = "\u{feff}<?xml version=\"1.0\" encoding=\"UTF-8\"?>\r\n<record:record xmlns:record=\"http://www.orcid.org/ns/record\" path=\"/0000-0002-1825-0097\">\u{dc}n\u{ef}code  </record:record>\r\n";
    const deprecated = fixtures.readSample("error-3.0.xml");
    const script = [_]Reply{
        .{ .status = 200, .body = exact },
        .{ .status = 301, .headers = &.{.{ "Location", "https://pub.orcid.org/v3.0/0000-0001-5109-3700/record" }}, .body = deprecated },
        .{ .status = 409, .body = deprecated },
        .{ .status = 404, .body = deprecated },
    };
    var f = try Fixture.init(&script, read_public);
    defer f.mock.deinit();
    const c = &f.c;
    {
        var ans = try c.recordRaw(ID, .xml, null);
        defer ans.deinit(gpa);
        try testing.expectEqual(@as(u16, 200), ans.status);
        try testing.expectEqualSlices(u8, exact, ans.body);
    }
    {
        var ans = try c.recordRaw("https://orcid.org/" ++ ID, .xml, null);
        defer ans.deinit(gpa);
        try testing.expectEqual(@as(u16, 301), ans.status); // not followed
        try testing.expectEqualSlices(u8, deprecated, ans.body);
    }
    {
        var ans = try c.recordRaw(ID, .xml, null);
        defer ans.deinit(gpa);
        try testing.expectEqual(@as(u16, 409), ans.status);
    }
    {
        var fail: client.Failure = .{};
        defer fail.deinit(gpa);
        try testing.expectError(error.Api, c.recordRaw(ID, .xml, &fail));
        try testing.expectEqual(@as(u16, 404), fail.status);
        try testing.expect(fail.orcidError() != null);
    }
    const seen = try f.finish();
    try testing.expectEqual(@as(usize, 4), seen.len);
    for (seen) |s| try expectGet(s, "/v3.0/" ++ ID ++ "/record", xml_type, "Bearer tok");
}

// ====================================================================== tokens

test "tokens other than /read-public of the client's realm are refused without a request" {
    const m = try Mock.start(&.{});
    defer m.deinit();
    var lim: client.RateLimiter = .init(testing.io, 1000.0);
    const Bad = struct { realm: client.Realm, scope: []const u8, text: []const u8 };
    const bad = [_]Bad{
        // another realm
        .{ .realm = .production, .scope = read_public, .text = "tok" },
        // not a /read-public token
        .{ .realm = .custom, .scope = "/read-limited", .text = "tok" },
        .{ .realm = .custom, .scope = "/authenticate", .text = "tok" },
        // blank
        .{ .realm = .custom, .scope = read_public, .text = " " },
    };
    for (bad) |x| {
        var t = try client.Token.init(gpa, x.realm, x.text, x.scope);
        defer t.deinit();
        var c = try client.Client.init(gpa, testing.io, .{ .access = try m.access(), .token = &t }, &lim);
        defer c.deinit();
        var fail: client.Failure = .{};
        defer fail.deinit(gpa);
        try testing.expectError(error.Usage, c.record(ID, .xml, &fail));
        try testing.expect(fail.message.len > 0);
    }
    const seen = try m.finish();
    try testing.expectEqual(@as(usize, 0), seen.len);
}

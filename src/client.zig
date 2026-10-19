//! A blocking ORCID Public API reader over `std.http.Client` (module
//! `yorc_client`; it imports module `yorc`) for **occasional
//! single-record retrieval**. It reads only ORCID's Public API
//! (`https://pub.orcid.org/v3.0`): it does not provide access to the ORCID
//! Sandbox or the ORCID Member API, and it writes nothing. yorc-zig is an
//! independent open-source project, not affiliated with, endorsed by or
//! sponsored by ORCID, Inc. yorc-rs's `blocking` with Zig names
//! (PARITY.md).
//!
//! For anything more than a few records, use ORCID's Public Data File and
//! `yorc.dump`: it works on local files and is not throttled. There are no
//! crawling, paging-through-everyone or parallel-fetching helpers.
//!
//! Access (`Access`, fixed when the client is built; each a closed set of
//! base URLs):
//!
//! | access | API base | OAuth base | reads |
//! |---|---|---|---|
//! | `.public` | `https://pub.orcid.org/v3.0` | `https://orcid.org/oauth` | public, anonymous or with a `/read-public` token |
//! | `.custom` (tests) | as given | as given | the same, against a mock server |
//!
//! The OAuth base serves one call only: the optional 2-legged
//! `/read-public` token (`Client.readPublicToken`). Reads need no token.
//!
//! Enforcement: every request URL (the token call included) is checked
//! against the base URLs (`Access.permits`) just before it is sent; tokens
//! carry the `Realm` they were issued for, and a token of another realm, or
//! one without the `/read-public` scope, is refused before anything is
//! sent; redirects are never followed.
//!
//! Pacing: every request of a `.public` client (reads, the token call and
//! retries) goes through one process-wide limiter (`RateLimiter.global`):
//! one request every 45 s, strictly one at a time. A client's own limiter
//! can only make it slower (a faster rate is clamped silently;
//! `Client.minInterval` is the effective spacing). Only `.custom` (mock
//! servers) may go faster, and not when its base URL is an ORCID host. The
//! cap is for ORCID's own hosts; Public Data File downloads and `yorc.dump`
//! are not throttled.
//!
//! Retries: GET on 5xx and transport errors, at most 3 attempts to ORCID,
//! waiting `Retry-After` when given; POST (the token call) never; a 429 is
//! never retried: the limiters are paused for its `Retry-After` and
//! `error.Api` is returned. Non-2xx answers are `error.Api` with the
//! `error-3.0` body parsed into the `Failure`.
//!
//! Errors carry no payload; pass a `*Failure` to get status, body, the parsed
//! ORCID error, the transport error or the OAuth error (call `deinit`).
const std = @import("std");
const yorc = @import("yorc");

const Io = std.Io;
const Allocator = std.mem.Allocator;
const model = yorc.model;

pub const xml_media_type = "application/vnd.orcid+xml";
pub const json_media_type = "application/vnd.orcid+json";
/// ORCID's limit on put-codes per bulk read (`Client.worksBulk`).
pub const max_bulk = 100;
/// The scope of the optional 2-legged token, the only one this client uses.
pub const scope_read_public = "/read-public";

/// ORCID's Public API, the only API this client reads.
pub const public_api = "https://pub.orcid.org/v3.0";
/// ORCID's OAuth base, for the `/read-public` token call only.
pub const oauth = "https://orcid.org/oauth";

/// The spacing of requests to ORCID's hosts: one every 45 s, the maximum
/// rate (a cap: slower is allowed, faster is clamped).
pub const orcid_interval_ns: u64 = 45 * std.time.ns_per_s;
/// Attempts per request to ORCID's hosts, retries included.
pub const orcid_max_attempts: u32 = 3;

/// Where a token was issued, so which clients may send it.
pub const Realm = enum { production, custom };

/// What a URL is used for (`Access.permits`).
pub const Purpose = enum { read, oauth };

fn trimBase(s: []const u8) []const u8 {
    return std.mem.trimEnd(u8, s, "/");
}

/// `url` is `base` or below it (`base/...`, `base?...`).
fn under(url: []const u8, base: []const u8) bool {
    if (base.len == 0 or !std.mem.startsWith(u8, url, base)) return false;
    const rest = url[base.len..];
    return rest.len == 0 or rest[0] == '/' or rest[0] == '?';
}

/// The host of `url` is `orcid.org` or a subdomain of it.
pub fn isOrcidHost(url: []const u8) bool {
    const rest = if (std.mem.indexOf(u8, url, "://")) |i| url[i + 3 ..] else url;
    const auth_end = std.mem.indexOfAny(u8, rest, "/?#") orelse rest.len;
    const authority = rest[0..auth_end];
    const host_port = if (std.mem.lastIndexOfScalar(u8, authority, '@')) |i| authority[i + 1 ..] else authority;
    const host_end = std.mem.indexOfScalar(u8, host_port, ':') orelse host_port.len;
    const host = std.mem.trimEnd(u8, host_port[0..host_end], ".");
    const suffix = ".orcid.org";
    if (std.ascii.eqlIgnoreCase(host, "orcid.org")) return true;
    return host.len > suffix.len and std.ascii.eqlIgnoreCase(host[host.len - suffix.len ..], suffix);
}

/// The access of a client: which hosts it talks to.
pub const Access = union(enum) {
    /// ORCID's Public API (`pub.orcid.org`), public reads only.
    public,
    /// Explicit base URLs, for mock servers in tests: the same reads, every
    /// request to `api` (or `oauth`).
    custom: Custom,

    pub const Custom = struct {
        /// API base, ending in `/v3.0`.
        api: []const u8,
        /// OAuth base, ending in `/oauth`.
        oauth: []const u8,
    };

    pub fn realm(a: Access) Realm {
        return switch (a) {
            .public => .production,
            .custom => .custom,
        };
    }

    /// Whether requests go to ORCID's hosts (and so through the 45 s
    /// limiter): `.public`, and a `.custom` whose `api` or `oauth` is an
    /// ORCID host.
    pub fn isOrcid(a: Access) bool {
        return switch (a) {
            .public => true,
            .custom => |x| isOrcidHost(x.api) or isOrcidHost(x.oauth),
        };
    }

    /// The API base, no trailing slash.
    pub fn apiBase(a: Access) []const u8 {
        return switch (a) {
            .public => public_api,
            .custom => |x| trimBase(x.api),
        };
    }

    /// OAuth base (`/token`), no trailing slash.
    pub fn oauthBase(a: Access) []const u8 {
        return switch (a) {
            .public => oauth,
            .custom => |x| trimBase(x.oauth),
        };
    }

    /// The host allowlist: `url` is inside the base URL for `purpose`
    /// (reads: the API base; OAuth: the OAuth base). The URL must start with
    /// the base followed by `/`, `?` or nothing; whitespace, control
    /// characters and `\` are refused anywhere.
    pub fn permits(a: Access, purpose: Purpose, url: []const u8) bool {
        for (url) |b| {
            if (b <= ' ' or b == 0x7f or b == '\\') return false;
        }
        return switch (purpose) {
            .read => under(url, a.apiBase()),
            .oauth => under(url, a.oauthBase()),
        };
    }

    /// Refuses an empty token, a token of another realm and a token without
    /// the `/read-public` scope.
    pub fn checkToken(a: Access, t: *const Token, failure: ?*Failure) Error!void {
        if (std.mem.trim(u8, t.access_token, " \t\r\n").len == 0) return usage(failure, "empty access token");
        if (t.realm != a.realm()) return usage(failure, "the token was issued for another realm (production or a test server) than this client's; nothing was sent");
        if (!t.hasScope(scope_read_public)) return usage(failure, "the Public API client sends only /read-public tokens; nothing was sent");
    }
};

pub const Format = enum {
    xml,
    json,

    pub fn mediaType(f: Format) []const u8 {
        return switch (f) {
            .xml => xml_media_type,
            .json => json_media_type,
        };
    }
};

pub const Config = struct {
    /// The access. Read once, at `Client.init`; do not change it
    /// afterwards (Zig has no private fields).
    access: Access = .public,
    /// Optional `/read-public` bearer token sent with every read (its realm
    /// must be the client's); null reads anonymously. Must outlive the
    /// client.
    token: ?*const Token = null,
    /// Retries after the first attempt (GET only; for ORCID's
    /// hosts at most `orcid_max_attempts` attempts in all).
    max_retries: u32 = orcid_max_attempts - 1,
    /// Upper bound for one `Retry-After` wait.
    max_retry_after_ms: u64 = 3_600_000,
    /// First exponential-backoff wait (doubles per attempt, capped at 30 s).
    backoff_base_ms: u64 = 500,
    /// Largest response body accepted.
    max_body: usize = 256 * 1024 * 1024,
    user_agent: []const u8 = "yorc-zig/" ++ yorc.version,
};

// ============================================================ rate limiter

/// Request pacing shared by every client and thread holding a pointer to it:
/// one request every interval, no bursts; the process-wide ORCID limiter
/// (`global`) also serialises requests (one at a time).
pub const RateLimiter = struct {
    io: Io,
    mutex: Io.Mutex = .init,
    /// Held across one request to ORCID by every client using `global()`.
    serial: Io.Mutex = .init,
    interval_ns: u64,
    /// Next free slot (awake clock, nanoseconds).
    next_ns: i96,

    /// The default spacing: one request per 45 s (`orcid_interval_ns`).
    pub const default_interval_ns: u64 = orcid_interval_ns;

    /// `rate` requests per second; non-positive or non-finite → one per 45 s.
    pub fn init(io: Io, rate: f64) RateLimiter {
        if (!(std.math.isFinite(rate) and rate > 0)) return initInterval(io, default_interval_ns);
        const ns: f64 = @as(f64, std.time.ns_per_s) / rate;
        return initInterval(io, @intFromFloat(@ceil(ns)));
    }

    /// One request per `interval_ns`.
    pub fn initInterval(io: Io, interval_ns: u64) RateLimiter {
        return .{ .io = io, .interval_ns = interval_ns, .next_ns = Io.Timestamp.now(io, .awake).nanoseconds };
    }

    var orcid_global: RateLimiter = .{ .io = undefined, .interval_ns = orcid_interval_ns, .next_ns = 0 };
    var orcid_ready: std.atomic.Value(bool) = .init(false);

    /// The process-wide limiter of ORCID's hosts: one request per 45 s, one
    /// at a time, shared by every client. The first `io` given is kept for
    /// `acquire`/`pause` called on it directly; clients use their own.
    pub fn global(io: Io) *RateLimiter {
        if (orcid_ready.cmpxchgStrong(false, true, .acq_rel, .acquire) == null) orcid_global.io = io;
        return &orcid_global;
    }

    /// Reserves the next slot and sleeps until it arrives.
    pub fn acquire(l: *RateLimiter) Io.Cancelable!void {
        return l.acquireSpaced(l.io, 0);
    }

    /// Reserves the next slot, at least `min_ns` after the one before.
    fn acquireSpaced(l: *RateLimiter, io: Io, min_ns: u64) Io.Cancelable!void {
        try l.mutex.lock(io);
        const now = Io.Timestamp.now(io, .awake).nanoseconds;
        const slot = @max(now, l.next_ns);
        l.next_ns = slot + @max(l.interval_ns, min_ns);
        l.mutex.unlock(io);
        const wait = slot - now;
        if (wait > 0) try io.sleep(.fromNanoseconds(wait), .awake);
    }

    /// No slot before `now + ns`.
    pub fn pause(l: *RateLimiter, ns: u64) Io.Cancelable!void {
        return l.pauseIo(l.io, ns);
    }

    fn pauseIo(l: *RateLimiter, io: Io, ns: u64) Io.Cancelable!void {
        try l.mutex.lock(io);
        defer l.mutex.unlock(io);
        const until = Io.Timestamp.now(io, .awake).nanoseconds + ns;
        if (until > l.next_ns) l.next_ns = until;
    }
};

// ================================================================ failures

pub const Error = error{
    /// The iD is not a valid ORCID iD; nothing was sent.
    InvalidOrcidId,
    /// Bad arguments (section path, bulk size), or a URL or token the
    /// access does not allow (`Failure.message`); nothing was sent.
    Usage,
    /// Connection, TLS, timeout or body-read failure, after retries
    /// (`Failure.transport`).
    Transport,
    /// A non-2xx answer after retries (`Failure.status`, `.body`, `.orcid_error`).
    Api,
    /// The answer is not the document expected (`Failure.message`).
    Decode,
    /// ORCID's OAuth token endpoint refused (`Failure.oauth_error`, `.oauth_description`).
    OAuth,
    OutOfMemory,
    Canceled,
};

/// Details of a failed call. Owns its strings; call `deinit`.
pub const Failure = struct {
    status: u16 = 0,
    /// The response body as received.
    body: []u8 = &.{},
    /// The `error-3.0` document of the body, if it parsed as one.
    error_doc: ?yorc.Document = null,
    transport: ?anyerror = null,
    oauth_error: ?[]u8 = null,
    oauth_description: ?[]u8 = null,
    message: []const u8 = "",

    /// The parsed ORCID error, if any.
    pub fn orcidError(f: *const Failure) ?*const model.OrcidError {
        const d = if (f.error_doc) |*x| x else return null;
        return switch (d.root) {
            .@"error" => |*e| e,
            else => null,
        };
    }

    pub fn deinit(f: *Failure, gpa: Allocator) void {
        gpa.free(f.body);
        if (f.error_doc) |*d| d.deinit();
        if (f.oauth_error) |s| gpa.free(s);
        if (f.oauth_description) |s| gpa.free(s);
        f.* = .{};
    }
};

// ========================================== URL encoding, /read-public token

/// Percent-encodes a form value (RFC 3986 unreserved kept).
pub fn encodeComponent(out: *std.ArrayList(u8), gpa: Allocator, s: []const u8) Allocator.Error!void {
    const hex = "0123456789ABCDEF";
    for (s) |b| {
        if (std.ascii.isAlphanumeric(b) or b == '-' or b == '.' or b == '_' or b == '~') {
            try out.append(gpa, b);
        } else {
            try out.appendSlice(gpa, &.{ '%', hex[b >> 4], hex[b & 0xF] });
        }
    }
}

fn usage(failure: ?*Failure, message: []const u8) Error {
    if (failure) |f| f.message = message;
    return error.Usage;
}

/// A 2-legged `/read-public` access token (`access_token`, `token_type`,
/// `refresh_token`, `expires_in`, `scope`), with the realm it was issued
/// for. Optional: Public API reads work without one. Owns its strings;
/// call `deinit`.
pub const Token = struct {
    arena: std.heap.ArenaAllocator,
    access_token: []const u8,
    refresh_token: ?[]const u8 = null,
    scope: []const u8,
    /// Where it was issued: only clients of that realm send it.
    realm: Realm,
    /// Seconds.
    expires_in: ?u64 = null,

    /// A token obtained elsewhere (e.g. an environment variable), for
    /// `realm`, with the scopes it was granted (copied). Clients send it only
    /// if it has `/read-public` (`Access.checkToken`).
    pub fn init(gpa: Allocator, realm: Realm, access_token: []const u8, scope: []const u8) Allocator.Error!Token {
        var t: Token = .{ .arena = .init(gpa), .access_token = "", .scope = "", .realm = realm };
        errdefer t.arena.deinit();
        const a = t.arena.allocator();
        t.access_token = try a.dupe(u8, access_token);
        t.scope = try a.dupe(u8, scope);
        return t;
    }

    pub fn deinit(t: *Token) void {
        t.arena.deinit();
        t.* = undefined;
    }

    /// Whether `scope` is among the granted scopes.
    pub fn hasScope(t: *const Token, scope: []const u8) bool {
        var it = std.mem.tokenizeAny(u8, t.scope, " \t");
        while (it.next()) |s| {
            if (std.mem.eql(u8, s, scope)) return true;
        }
        return false;
    }

    /// `Authorization` header value (caller frees).
    pub fn bearer(t: *const Token, gpa: Allocator) Allocator.Error![]u8 {
        return std.fmt.allocPrint(gpa, "Bearer {s}", .{t.access_token});
    }
};

/// Maps ORCID's token response JSON onto a `Token` of `realm` (scope
/// `/read-public` when the response names none).
pub fn tokenFromJson(gpa: Allocator, body: []const u8, realm: Realm, failure: ?*Failure) Error!Token {
    var t: Token = .{ .arena = .init(gpa), .access_token = "", .scope = "", .realm = realm };
    errdefer t.arena.deinit();
    const a = t.arena.allocator();
    const v = std.json.parseFromSliceLeaky(std.json.Value, a, body, .{ .duplicate_field_behavior = .use_last }) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return decode(failure, "token response is not JSON");
    };
    if (v != .object) return decode(failure, "token response is not a JSON object");
    const obj = &v.object;
    const text = struct {
        fn f(o: *const std.json.ObjectMap, k: []const u8) ?[]const u8 {
            const x = o.getPtr(k) orelse return null;
            const str = switch (x.*) {
                .string => |s| s,
                else => return null,
            };
            const tr = std.mem.trim(u8, str, " \t\r\n");
            return if (tr.len == 0) null else tr;
        }
    }.f;
    t.access_token = text(obj, "access_token") orelse return decode(failure, "token response has no access_token");
    if (text(obj, "token_type")) |tt| {
        if (!std.ascii.eqlIgnoreCase(tt, "bearer")) return decode(failure, "token_type is not bearer");
    }
    t.refresh_token = text(obj, "refresh_token");
    t.scope = text(obj, "scope") orelse scope_read_public;
    if (obj.getPtr("expires_in")) |x| {
        t.expires_in = switch (x.*) {
            .integer => |i| if (i >= 0) @as(u64, @intCast(i)) else null,
            .string => |s| digits(s),
            .number_string => |s| digits(s),
            else => null,
        };
    }
    return t;
}

fn decode(failure: ?*Failure, message: []const u8) Error {
    if (failure) |f| f.message = message;
    return error.Decode;
}

/// Rust `u64::from_str`: optional `+`, ASCII digits.
fn digits(s: []const u8) ?u64 {
    var t = s;
    if (t.len > 0 and t[0] == '+') t = t[1..];
    if (t.len == 0) return null;
    var v: u64 = 0;
    for (t) |c| {
        if (c < '0' or c > '9') return null;
        v = std.math.mul(u64, v, 10) catch return null;
        v = std.math.add(u64, v, c - '0') catch return null;
    }
    return v;
}

/// Delta-seconds `Retry-After` → milliseconds, capped; null for an HTTP-date.
pub fn retryAfterMs(value: ?[]const u8, cap_ms: u64) ?u64 {
    const secs = digits(std.mem.trim(u8, value orelse return null, " \t")) orelse return null;
    const ms = std.math.mul(u64, secs, 1000) catch return cap_ms;
    return @min(ms, cap_ms);
}

// ================================================================== client

/// An HTTP answer: status, the body exactly as received and the `Location`
/// header (owned).
pub const Answer = struct {
    status: u16,
    body: []u8,
    location: ?[]u8 = null,

    pub fn deinit(a: *Answer, gpa: Allocator) void {
        gpa.free(a.body);
        if (a.location) |l| gpa.free(l);
        a.* = undefined;
    }
};

const Request = struct {
    method: std.http.Method,
    purpose: Purpose,
    url: []const u8,
    accept: []const u8,
    content_type: ?[]const u8 = null,
    authorization: ?[]const u8 = null,
    body: ?[]const u8 = null,
};

/// The ORCID Public API client. Not thread-safe itself (one per thread); limiters
/// are shared, and ORCID's hosts always go through `RateLimiter.global`.
pub const Client = struct {
    gpa: Allocator,
    io: Io,
    http: std.http.Client,
    config: Config,
    limiter: *RateLimiter,
    own_limiter: ?*RateLimiter = null,
    /// The process-wide ORCID limiter, for `.public` (and a `.custom` at an
    /// ORCID host).
    orcid_limiter: ?*RateLimiter = null,

    /// A client using `limiter` (which can only make it slower for ORCID's
    /// hosts); without one, ORCID clients use the process-wide limiter and a
    /// `.custom` client gets its own at the default interval (45 s; pass a
    /// fast limiter in tests).
    pub fn init(gpa: Allocator, io: Io, config: Config, limiter: ?*RateLimiter) Allocator.Error!Client {
        const shared: ?*RateLimiter = if (config.access.isOrcid()) RateLimiter.global(io) else null;
        var own: ?*RateLimiter = null;
        const lim = limiter orelse shared orelse blk: {
            const l = try gpa.create(RateLimiter);
            l.* = .initInterval(io, RateLimiter.default_interval_ns);
            own = l;
            break :blk l;
        };
        return .{
            .gpa = gpa,
            .io = io,
            .http = .{ .allocator = gpa, .io = io },
            .config = config,
            .limiter = lim,
            .own_limiter = own,
            .orcid_limiter = shared,
        };
    }

    pub fn deinit(c: *Client) void {
        c.http.deinit();
        if (c.own_limiter) |l| c.gpa.destroy(l);
        c.* = undefined;
    }

    /// The effective spacing of this client's requests (at least 45 s for
    /// ORCID's hosts).
    pub fn minInterval(c: *const Client) u64 {
        if (c.orcid_limiter != null) return @max(c.limiter.interval_ns, orcid_interval_ns);
        return c.limiter.interval_ns;
    }

    fn maxAttempts(c: *const Client) u32 {
        const wanted = c.config.max_retries +| 1;
        return if (c.orcid_limiter != null) @min(wanted, orcid_max_attempts) else wanted;
    }

    fn backoffMs(c: *const Client, attempt: u32) u64 {
        const shift: u6 = @intCast(@min(attempt, 16));
        const ms = std.math.mul(u64, c.config.backoff_base_ms, @as(u64, 1) << shift) catch 30_000;
        return @min(ms, 30_000);
    }

    fn sleepMs(c: *Client, ms: u64) Io.Cancelable!void {
        if (ms == 0) return;
        try c.io.sleep(.fromMilliseconds(@intCast(@min(ms, std.math.maxInt(i64)))), .awake);
    }

    fn pauseAll(c: *Client, ns: u64) Io.Cancelable!void {
        if (c.orcid_limiter) |o| try o.pauseIo(c.io, ns);
        try c.limiter.pauseIo(c.io, ns);
    }

    const Raw = struct { answer: Answer, retry_after: ?u64 };

    /// One request, sent as given.
    fn sendOnce(c: *Client, rq: Request) !Raw {
        const uri = try std.Uri.parse(rq.url);
        var hreq = try c.http.request(rq.method, uri, .{
            // never follow a redirect: a deprecated record answers 301 with
            // an error document, and following it would read another record
            .redirect_behavior = .unhandled,
            .headers = .{
                .user_agent = .{ .override = c.config.user_agent },
                .accept_encoding = .{ .override = "identity" },
                .authorization = if (rq.authorization) |v| .{ .override = v } else .default,
                .content_type = if (rq.content_type) |v| .{ .override = v } else .default,
            },
            .extra_headers = &.{.{ .name = "Accept", .value = rq.accept }},
        });
        defer hreq.deinit();
        if (rq.body) |body| {
            const copy = try c.gpa.dupe(u8, body);
            defer c.gpa.free(copy);
            try hreq.sendBodyComplete(copy);
        } else {
            try hreq.sendBodiless();
        }
        // redirects are not followed, so no redirect buffer is needed
        var no_redirects: [0]u8 = undefined;
        var response = try hreq.receiveHead(&no_redirects);
        const status: u16 = @backingInt(response.head.status);
        var retry: ?u64 = null;
        var location: ?[]u8 = null;
        errdefer if (location) |l| c.gpa.free(l);
        var hit = response.head.iterateHeaders();
        while (hit.next()) |h| {
            if (std.ascii.eqlIgnoreCase(h.name, "retry-after")) {
                retry = retryAfterMs(h.value, c.config.max_retry_after_ms);
            } else if (std.ascii.eqlIgnoreCase(h.name, "location") and location == null) {
                location = try c.gpa.dupe(u8, h.value);
            }
        }
        if (response.head.content_encoding != .identity) return error.UnexpectedContentEncoding;
        var transfer_buf: [16 * 1024]u8 = undefined;
        const body_reader = response.reader(&transfer_buf);
        const body = body_reader.allocRemaining(c.gpa, .limited(c.config.max_body)) catch |err| switch (err) {
            error.ReadFailed => return response.bodyErr() orelse error.ReadFailed,
            else => |e| return e,
        };
        return .{ .answer = .{ .status = status, .body = body, .location = location }, .retry_after = retry };
    }

    /// One request with the host check, pacing and retries: the URL must be
    /// inside the access's base URLs (checked before every attempt); ORCID's
    /// hosts go through the process-wide limiter (45 s, one at a time) with
    /// at most `orcid_max_attempts` attempts; GET is retried on 5xx and
    /// transport errors, never POST; a 429 is never
    /// retried (the limiters are paused for its `Retry-After`).
    fn exchange(c: *Client, rq: Request, failure: ?*Failure) Error!Answer {
        const idempotent = rq.method != .POST;
        const attempts = c.maxAttempts();
        var attempt: u32 = 0;
        while (true) {
            if (!c.config.access.permits(rq.purpose, rq.url))
                return usage(failure, "refused: the URL is outside the hosts of this client's access; nothing was sent");
            const sent = blk: {
                if (c.orcid_limiter) |o| try o.serial.lock(c.io);
                defer if (c.orcid_limiter) |o| o.serial.unlock(c.io);
                if (c.orcid_limiter) |o| {
                    try o.acquireSpaced(c.io, orcid_interval_ns);
                    if (o != c.limiter) try c.limiter.acquireSpaced(c.io, 0);
                } else {
                    try c.limiter.acquireSpaced(c.io, 0);
                }
                break :blk c.sendOnce(rq);
            };
            attempt += 1;
            const last = attempt >= attempts;
            if (sent) |raw| {
                var ans = raw.answer;
                if (ans.status == 429) {
                    // stop; nothing reaches the host before Retry-After
                    if (raw.retry_after) |ms| {
                        c.pauseAll(ms * std.time.ns_per_ms) catch |e| {
                            ans.deinit(c.gpa);
                            return e;
                        };
                    }
                    return ans;
                }
                const retryable = idempotent and ans.status >= 500 and ans.status <= 599;
                if (!retryable or last) return ans;
                ans.deinit(c.gpa);
                if (raw.retry_after) |ms| {
                    try c.pauseAll(ms * std.time.ns_per_ms);
                } else {
                    try c.sleepMs(c.backoffMs(attempt - 1));
                }
            } else |err| {
                const e: anyerror = err;
                if (e == error.OutOfMemory) return error.OutOfMemory;
                if (e == error.Canceled) return error.Canceled;
                if (!idempotent or last) {
                    if (failure) |f| f.transport = e;
                    return error.Transport;
                }
                try c.sleepMs(c.backoffMs(attempt - 1));
            }
        }
    }

    /// Fills `failure` from a non-2xx answer (taking the body) and returns
    /// error.Api.
    fn apiError(c: *Client, ans: *Answer, failure: ?*Failure) Error {
        if (ans.location) |l| c.gpa.free(l);
        ans.location = null;
        const f = failure orelse {
            ans.deinit(c.gpa);
            return error.Api;
        };
        f.status = ans.status;
        f.body = ans.body;
        const trimmed = std.mem.trimStart(u8, ans.body, " \t\r\n\xEF\xBB\xBF");
        const doc: ?yorc.Document = if (std.mem.startsWith(u8, trimmed, "{"))
            yorc.json.parse(c.gpa, "error", ans.body, null) catch null
        else
            yorc.xml.parse(c.gpa, ans.body, .{}, null) catch null;
        if (doc) |d| {
            var dd = d;
            if (dd.root == .@"error") f.error_doc = dd else dd.deinit();
        }
        return error.Api;
    }

    fn authHeader(c: *Client, buf: []u8) ?[]const u8 {
        const t = c.config.token orelse return null;
        if (t.access_token.len == 0) return null;
        return std.fmt.bufPrint(buf, "Bearer {s}", .{t.access_token}) catch null;
    }

    /// `GET {api}/{rest}` with `Config.token` (checked by
    /// `Access.checkToken` first).
    fn read(c: *Client, rest: []const u8, format: Format, failure: ?*Failure) Error!Answer {
        if (c.config.token) |t| {
            if (t.access_token.len > 0) try c.config.access.checkToken(t, failure);
        }
        const url = try std.fmt.allocPrint(c.gpa, "{s}{s}", .{ c.config.access.apiBase(), rest });
        defer c.gpa.free(url);
        var abuf: [4096]u8 = undefined;
        return c.exchange(.{ .method = .GET, .purpose = .read, .url = url, .accept = format.mediaType(), .authorization = c.authHeader(&abuf) }, failure);
    }

    /// `GET {api}/{iD}{rest}`; the iD may be in any form `OrcidId.parse`
    /// accepts. Returns the raw answer (any status) after retries.
    fn getRaw(c: *Client, orcid_id: []const u8, rest: []const u8, format: Format, failure: ?*Failure) Error!Answer {
        const id = yorc.OrcidId.parse(orcid_id) catch return error.InvalidOrcidId;
        const path = try std.fmt.allocPrint(c.gpa, "/{s}{s}", .{ id.slice(), rest });
        defer c.gpa.free(path);
        return c.read(path, format, failure);
    }

    fn parseDoc(c: *Client, body: []const u8, format: Format, json_kind: []const u8, failure: ?*Failure) Error!yorc.Document {
        switch (format) {
            .xml => return yorc.xml.parse(c.gpa, body, .{}, null) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return decode(failure, "the response is not ORCID XML"),
            },
            .json => return yorc.json.parse(c.gpa, json_kind, body, null) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return decode(failure, "the response is not ORCID JSON"),
            },
        }
    }

    fn getDoc(c: *Client, orcid_id: []const u8, rest: []const u8, format: Format, json_kind: []const u8, failure: ?*Failure) Error!yorc.Document {
        var ans = try c.getRaw(orcid_id, rest, format, failure);
        if (ans.status < 200 or ans.status > 299) return c.apiError(&ans, failure);
        defer ans.deinit(c.gpa);
        return c.parseDoc(ans.body, format, json_kind, failure);
    }

    /// The document if its root is `want`, else error.Decode.
    fn expect(doc: yorc.Document, want: std.meta.Tag(model.Root), failure: ?*Failure) Error!yorc.Document {
        if (doc.root == want) return doc;
        var d = doc;
        d.deinit();
        return decode(failure, "the response is not the document expected");
    }

    /// `GET /{iD}/record`, exactly as received (so a caller can hash and
    /// store the bytes): 2xx, and the error documents of a deprecated (301)
    /// or locked (409) record, which are answers about the record; any other
    /// status is error.Api. Caller deinits the Answer.
    pub fn recordRaw(c: *Client, orcid_id: []const u8, format: Format, failure: ?*Failure) Error!Answer {
        var ans = try c.getRaw(orcid_id, "/record", format, failure);
        switch (ans.status) {
            200...299, 301, 409 => return ans,
            else => return c.apiError(&ans, failure),
        }
    }

    /// `GET /{iD}/record`.
    pub fn record(c: *Client, orcid_id: []const u8, format: Format, failure: ?*Failure) Error!yorc.Document {
        return expect(try c.getDoc(orcid_id, "/record", format, "record", failure), .record, failure);
    }

    /// `GET /{iD}/person`.
    pub fn person(c: *Client, orcid_id: []const u8, format: Format, failure: ?*Failure) Error!yorc.Document {
        return expect(try c.getDoc(orcid_id, "/person", format, "person", failure), .person, failure);
    }

    /// `GET /{iD}/works` (grouped summaries).
    pub fn works(c: *Client, orcid_id: []const u8, format: Format, failure: ?*Failure) Error!yorc.Document {
        return expect(try c.getDoc(orcid_id, "/works", format, "works", failure), .works, failure);
    }

    /// `GET /{iD}/work/{put-code}` (a full work).
    pub fn work(c: *Client, orcid_id: []const u8, put_code: model.PutCode, format: Format, failure: ?*Failure) Error!yorc.Document {
        var buf: [32]u8 = undefined;
        const rest = std.fmt.bufPrint(&buf, "/work/{d}", .{put_code}) catch unreachable;
        return expect(try c.getDoc(orcid_id, rest, format, "work", failure), .work, failure);
    }

    /// `GET /{iD}/works/{pc,pc,...}`: 1..=100 full works; missing ones come
    /// back as `.error` bulk items.
    pub fn worksBulk(c: *Client, orcid_id: []const u8, put_codes: []const model.PutCode, format: Format, failure: ?*Failure) Error!yorc.Document {
        if (put_codes.len == 0 or put_codes.len > max_bulk) return usage(failure, "a bulk read takes 1..=100 put-codes");
        var rest: std.ArrayList(u8) = .empty;
        defer rest.deinit(c.gpa);
        try rest.appendSlice(c.gpa, "/works/");
        for (put_codes, 0..) |pc, i| {
            if (i > 0) try rest.append(c.gpa, ',');
            try rest.print(c.gpa, "{d}", .{pc});
        }
        return expect(try c.getDoc(orcid_id, rest.items, format, "bulk", failure), .bulk, failure);
    }

    /// `GET /{iD}/{section}` for any other section path (`educations`,
    /// `fundings`, `keywords`, `education/123`, ...).
    pub fn section(c: *Client, orcid_id: []const u8, path: []const u8, format: Format, failure: ?*Failure) Error!yorc.Document {
        if (!isSectionPath(path)) return usage(failure, "not a section path");
        var buf: [512]u8 = undefined;
        const rest = std.fmt.bufPrint(&buf, "/{s}", .{path}) catch return usage(failure, "section path too long");
        return c.getDoc(orcid_id, rest, format, jsonKindForPath(path), failure);
    }

    // ------------------------------------------------- the /read-public token

    /// An optional 2-legged `client_credentials` token of scope
    /// `/read-public` (`POST {oauth}/token`; never retried), with the
    /// client's realm. Public API reads work without one.
    pub fn readPublicToken(c: *Client, client_id: []const u8, client_secret: []const u8, failure: ?*Failure) Error!Token {
        var form: std.ArrayList(u8) = .empty;
        defer form.deinit(c.gpa);
        try form.appendSlice(c.gpa, "client_id=");
        try encodeComponent(&form, c.gpa, client_id);
        try form.appendSlice(c.gpa, "&client_secret=");
        try encodeComponent(&form, c.gpa, client_secret);
        try form.appendSlice(c.gpa, "&grant_type=client_credentials&scope=");
        try encodeComponent(&form, c.gpa, scope_read_public);
        return c.tokenRequest(form.items, failure);
    }

    fn tokenRequest(c: *Client, form: []const u8, failure: ?*Failure) Error!Token {
        const url = try std.fmt.allocPrint(c.gpa, "{s}/token", .{c.config.access.oauthBase()});
        defer c.gpa.free(url);
        var ans = try c.exchange(.{
            .method = .POST,
            .purpose = .oauth,
            .url = url,
            .accept = "application/json",
            .content_type = "application/x-www-form-urlencoded",
            .body = form,
        }, failure);
        if (ans.status >= 200 and ans.status <= 299) {
            defer ans.deinit(c.gpa);
            return tokenFromJson(c.gpa, ans.body, c.config.access.realm(), failure);
        }
        // An OAuth error answer: {"error": ..., "error_description": ...}.
        var tmp: std.heap.ArenaAllocator = .init(c.gpa);
        defer tmp.deinit();
        const v = std.json.parseFromSliceLeaky(std.json.Value, tmp.allocator(), ans.body, .{}) catch {
            return c.apiError(&ans, failure);
        };
        defer ans.deinit(c.gpa);
        if (failure) |f| {
            f.status = ans.status;
            if (v == .object) {
                if (v.object.get("error")) |e| if (e == .string) {
                    f.oauth_error = try c.gpa.dupe(u8, e.string);
                };
                if (v.object.get("error_description")) |e| if (e == .string) {
                    f.oauth_description = try c.gpa.dupe(u8, e.string);
                };
            }
            if (f.oauth_error == null) f.oauth_error = try std.fmt.allocPrint(c.gpa, "HTTP {d}", .{ans.status});
        }
        return error.OAuth;
    }
};

/// A section path: `[A-Za-z0-9-/,]+` without `..`.
pub fn isSectionPath(path: []const u8) bool {
    if (path.len == 0 or std.mem.indexOf(u8, path, "..") != null) return false;
    for (path) |b| {
        if (!(std.ascii.isAlphanumeric(b) or b == '-' or b == '/' or b == ',')) return false;
    }
    return true;
}

/// The JSON document kind of a Public API section path.
pub fn jsonKindForPath(path: []const u8) []const u8 {
    const first = if (std.mem.indexOfScalar(u8, path, '/')) |i| path[0..i] else path;
    const has_item = std.mem.indexOfScalar(u8, path, '/') != null;
    const Map = struct { []const u8, []const u8, []const u8 }; // section, list kind, item kind
    const table = [_]Map{
        .{ "activities", "activities-summary", "activities-summary" },
        .{ "address", "addresses", "address" },
        .{ "email", "emails", "email" },
        .{ "external-identifiers", "external-identifiers", "external-identifier" },
        .{ "keywords", "keywords", "keyword" },
        .{ "other-names", "other-names", "other-name" },
        .{ "researcher-urls", "researcher-urls", "researcher-url" },
        .{ "works", "works", "bulk" },
    };
    for (table) |m| {
        if (std.mem.eql(u8, first, m[0])) return if (has_item) m[2] else m[1];
    }
    return first;
}

// =================================================================== tests

const testing = std.testing;

fn testCustom() Access {
    return .{ .custom = .{ .api = "http://127.0.0.1:9/v3.0/", .oauth = "http://127.0.0.1:9/oauth" } };
}

test "urls" {
    const public_access: Access = .public;
    try testing.expectEqualStrings("https://pub.orcid.org/v3.0", public_access.apiBase());
    try testing.expectEqualStrings("https://orcid.org/oauth", public_access.oauthBase());
    try testing.expectEqualStrings("http://127.0.0.1:9/v3.0", testCustom().apiBase());
    try testing.expectEqual(Realm.production, public_access.realm());
    try testing.expectEqual(Realm.custom, testCustom().realm());
}

test "the host set is closed" {
    const public_access: Access = .public;
    try testing.expect(public_access.permits(.read, "https://pub.orcid.org/v3.0/x"));
    try testing.expect(public_access.permits(.read, "https://pub.orcid.org/v3.0?x=1"));
    try testing.expect(public_access.permits(.oauth, "https://orcid.org/oauth/token"));
    // the Member API, the Sandbox and the record pages are never reached
    const outside = [_][]const u8{
        "https://api.orcid.org/v3.0/x",
        "https://pub.sandbox.orcid.org/v3.0/x",
        "https://api.sandbox.orcid.org/v3.0/x",
        "https://sandbox.orcid.org/oauth/token",
        "https://orcid.org/0000-0002-1825-0097",
    };
    for (outside) |u| {
        try testing.expect(!public_access.permits(.read, u));
        try testing.expect(!public_access.permits(.oauth, u));
    }
    // reads and the token call do not cross over
    try testing.expect(!public_access.permits(.oauth, "https://pub.orcid.org/v3.0/x"));
    try testing.expect(!public_access.permits(.read, "https://orcid.org/oauth/token"));
}

test "forged urls are refused" {
    const public_access: Access = .public;
    const forged = [_][]const u8{
        "https://pub.orcid.org.evil.example/v3.0/x",
        "https://pub.orcid.org@evil.example/v3.0/x",
        "https://pub.orcid.org:8443/v3.0/x",
        "http://pub.orcid.org/v3.0/x",
        "https://pub.orcid.org/v3.0evil/x",
        "https://PUB.orcid.org/v3.0/x",
        "https://pub.orcid.org/v3.0/x y",
        "https://pub.orcid.org/v3.0/x\r\nHost: api.orcid.org",
        "https://pub.orcid.org/v3.0\\@api.orcid.org/",
        "https://orcid.org/oauth/token\r\nHost: sandbox.orcid.org",
        "",
    };
    for (forged) |u| {
        try testing.expect(!public_access.permits(.read, u));
        try testing.expect(!public_access.permits(.oauth, u));
    }
    const c = testCustom();
    try testing.expect(c.permits(.read, "http://127.0.0.1:9/v3.0/x"));
    try testing.expect(!c.permits(.read, "http://127.0.0.1:90/v3.0/x"));
    try testing.expect(!c.permits(.read, "https://pub.orcid.org/v3.0/x"));
}

test "a forged url is refused by the send path" {
    // the check sits in `exchange`, under every request: nothing is sent,
    // so no listener is needed
    var lim: RateLimiter = .init(testing.io, 1000.0);
    var c = try Client.init(testing.allocator, testing.io, .{ .access = testCustom() }, &lim);
    defer c.deinit();
    const forged = [_]Request{
        .{ .method = .GET, .purpose = .read, .url = "https://pub.orcid.org/v3.0/x/record", .accept = xml_media_type },
        .{ .method = .GET, .purpose = .read, .url = "https://api.orcid.org/v3.0/x/works", .accept = xml_media_type },
        .{ .method = .POST, .purpose = .oauth, .url = "https://orcid.org/oauth/token", .accept = "application/json" },
        .{ .method = .GET, .purpose = .read, .url = "http://127.0.0.1:9/oauth/token", .accept = xml_media_type },
    };
    for (forged) |rq| try testing.expectError(error.Usage, c.exchange(rq, null));
}

test "tokens: /read-public of the client's realm only" {
    const gpa = testing.allocator;
    var prod_public = try Token.init(gpa, .production, "t", "/read-public");
    defer prod_public.deinit();
    var custom_public = try Token.init(gpa, .custom, "t", "/read-public");
    defer custom_public.deinit();
    var prod_limited = try Token.init(gpa, .production, "t", "/read-limited");
    defer prod_limited.deinit();
    var prod_auth = try Token.init(gpa, .production, "t", "/authenticate");
    defer prod_auth.deinit();
    var blank = try Token.init(gpa, .production, " ", "/read-public");
    defer blank.deinit();
    const public_access: Access = .public;
    try public_access.checkToken(&prod_public, null);
    try testing.expectError(error.Usage, public_access.checkToken(&custom_public, null));
    try testing.expectError(error.Usage, public_access.checkToken(&prod_limited, null));
    try testing.expectError(error.Usage, public_access.checkToken(&prod_auth, null));
    try testing.expectError(error.Usage, public_access.checkToken(&blank, null));
    try testCustom().checkToken(&custom_public, null);
    try testing.expectError(error.Usage, testCustom().checkToken(&prod_public, null));
}

test "public access clamps to 45 seconds" {
    try testing.expectEqual(@as(u64, 45_000_000_000), orcid_interval_ns);
    const def: RateLimiter = .init(testing.io, std.math.nan(f64));
    try testing.expectEqual(@as(u64, 45_000_000_000), def.interval_ns);
    try testing.expectEqual(@as(u64, 45_000_000_000), RateLimiter.default_interval_ns);
    {
        var fast: RateLimiter = .init(testing.io, 1000.0);
        var c = try Client.init(testing.allocator, testing.io, .{ .access = .public, .max_retries = 10 }, &fast);
        defer c.deinit();
        try testing.expectEqual(orcid_interval_ns, c.minInterval());
        try testing.expectEqual(@as(u32, 3), c.maxAttempts());
        try testing.expect(c.orcid_limiter.? == RateLimiter.global(testing.io));
        var slow: RateLimiter = .initInterval(testing.io, 60 * std.time.ns_per_s);
        var d = try Client.init(testing.allocator, testing.io, .{ .access = .public }, &slow);
        defer d.deinit();
        try testing.expectEqual(@as(u64, 60 * std.time.ns_per_s), d.minInterval());
    }
    var quick: RateLimiter = .init(testing.io, 1000.0);
    var custom = try Client.init(testing.allocator, testing.io, .{ .access = testCustom() }, &quick);
    defer custom.deinit();
    try testing.expect(custom.minInterval() < 2 * std.time.ns_per_ms);
    try testing.expect(custom.orcid_limiter == null);
    // a custom pointed at an ORCID host is paced like `.public`
    const orcid_bases = [_][]const u8{ "https://pub.orcid.org/v3.0", "https://PUB.Orcid.org:443/v3.0", "http://user@orcid.org./v3.0" };
    for (orcid_bases) |b| {
        const a: Access = .{ .custom = .{ .api = b, .oauth = "http://127.0.0.1:9/oauth" } };
        try testing.expect(a.isOrcid());
        var e = try Client.init(testing.allocator, testing.io, .{ .access = a }, &quick);
        defer e.deinit();
        try testing.expectEqual(orcid_interval_ns, e.minInterval());
    }
    try testing.expect(!isOrcidHost("http://127.0.0.1:9/v3.0"));
    try testing.expect(!isOrcidHost("https://notorcid.org/v3.0"));
    try testing.expect(!isOrcidHost("https://figshare.com/orcid.org"));
}

test "token response" {
    const gpa = testing.allocator;
    var t = try tokenFromJson(gpa,
        \\{"access_token":"f5af9f51-07e6-4332-8f1a-c0c11c1e3728","token_type":"bearer",
        \\ "refresh_token":"f725f747-3a65-49f6-a231-3e8944ce464d","expires_in":631138518,
        \\ "scope":"/read-public","name":null,"orcid":null}
    , .production, null);
    defer t.deinit();
    try testing.expectEqualStrings("f5af9f51-07e6-4332-8f1a-c0c11c1e3728", t.access_token);
    try testing.expectEqualStrings("f725f747-3a65-49f6-a231-3e8944ce464d", t.refresh_token.?);
    try testing.expectEqualStrings("/read-public", t.scope);
    try testing.expectEqual(Realm.production, t.realm);
    try testing.expectEqual(@as(?u64, 631_138_518), t.expires_in);
    try testing.expectError(error.Decode, tokenFromJson(gpa, "{\"token_type\":\"bearer\"}", .production, null));
    try testing.expectError(error.Decode, tokenFromJson(gpa, "{\"access_token\":\"x\",\"token_type\":\"mac\"}", .production, null));
    var bare = try tokenFromJson(gpa, "{\"access_token\":\"x\",\"expires_in\":\"20\"}", .custom, null);
    defer bare.deinit();
    try testing.expectEqualStrings("/read-public", bare.scope);
    try testing.expectEqual(@as(?u64, 20), bare.expires_in);
    try testing.expect(bare.hasScope("/read-public"));
    try testing.expect(!bare.hasScope("/read-limited"));
}

test "limiter paces" {
    var lim: RateLimiter = .init(testing.io, 100.0);
    const start = Io.Timestamp.now(testing.io, .awake);
    for (0..6) |_| try lim.acquire();
    const elapsed = start.durationTo(Io.Timestamp.now(testing.io, .awake)).nanoseconds;
    try testing.expect(elapsed >= 45 * std.time.ns_per_ms);
    // a minimum spacing larger than the interval wins
    var fast: RateLimiter = .init(testing.io, 1000.0);
    const t0 = Io.Timestamp.now(testing.io, .awake);
    for (0..3) |_| try fast.acquireSpaced(testing.io, 30 * std.time.ns_per_ms);
    const spaced = t0.durationTo(Io.Timestamp.now(testing.io, .awake)).nanoseconds;
    try testing.expect(spaced >= 55 * std.time.ns_per_ms);
}

test "retry-after and section paths" {
    try testing.expectEqual(@as(?u64, 3000), retryAfterMs("3", 300_000));
    try testing.expectEqual(@as(?u64, 120_000), retryAfterMs(" 120 ", 300_000));
    try testing.expectEqual(@as(?u64, 300_000), retryAfterMs("100000", 300_000));
    try testing.expectEqual(@as(?u64, null), retryAfterMs("Wed, 21 Oct 2015 07:28:00 GMT", 300_000));
    try testing.expect(isSectionPath("educations"));
    try testing.expect(isSectionPath("works/1,2,3"));
    try testing.expect(!isSectionPath("../0000-0001-5109-3700/record"));
    try testing.expect(!isSectionPath(""));
    try testing.expectEqualStrings("activities-summary", jsonKindForPath("activities"));
    try testing.expectEqualStrings("bulk", jsonKindForPath("works/1,2"));
    try testing.expectEqualStrings("education", jsonKindForPath("education/12"));
    try testing.expectEqualStrings("emails", jsonKindForPath("email"));
}

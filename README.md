# yorc-zig: Cultivate your research identity and networks

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Zig](https://img.shields.io/badge/Zig-0.18.0--dev.131-f7a41d)](#zig-version)
[![CI](https://github.com/mgbilby/yorc-zig/actions/workflows/ci.yml/badge.svg)](https://github.com/mgbilby/yorc-zig/actions/workflows/ci.yml)
[![vs yorc-rs](https://img.shields.io/badge/vs%20yorc--rs-byte--identical-brightgreen.svg)](BENCHMARKS.md#parity)

## Not affiliated with ORCID

yorc-zig is an independent open-source project. It is not affiliated with,
endorsed by or sponsored by ORCID, Inc. It does not provide access to the
ORCID Sandbox or the ORCID Member API: its client module (`yorc_client`)
reads only ORCID's Public API (`pub.orcid.org`). It reads and converts data
in ORCID's published formats.

## About

The [ORCID](https://orcid.org/) message schema v3.0 for Zig. It covers:

- a typed model of the whole record schema
- ORCID XML and JSON, read and write
- iD checks
- the [ORCID Public Data File](https://info.orcid.org/documentation/integration-guide/orcid-public-data-file/), streamed from its `.tar.gz` archives
- a blocking ORCID Public API reader for occasional single-record
  retrieval (one request every 45 s to ORCID; for anything more, use the
  Public Data File and `yorc.dump`)

**Walkthrough:** [WALKTHROUGH.md](WALKTHROUGH.md), nine use cases and a setup cell as
runnable cells over the files shipped in `testdata/`, with their expected
output (`zig build walkthrough`; nothing else to install).

It does the same job as the Rust crate
[yorc-rs](https://github.com/mgbilby/yorc-rs). PARITY.md maps each
of that crate's items to its Zig counterpart and lists the gaps.

- **Schema-derived.** Every data-bearing element and attribute of the v3.0
  record XSDs has a field, and a test walks the XSDs to keep it that way.
- **Round-trip tested.** Every ORCID sample document reads, writes and
  reads back to the same model, in XML and in JSON.
- **Lenient reads, exact writes.** Reads skip unknown elements and keep
  unknown vocabulary values as `.other`. Writes are exact and deterministic.
  Malformed data returns an error, never a panic.
- **No dependencies beyond the Zig standard library:** no C, no TLS library
  of its own (`std.http.Client` provides TLS).
- **General purpose, no policy.** What you read, and why, is up to you.
- **Fast, and byte-identical with yorc-rs.** In a cross-check of ORCID's
  samples its written XML and JSON and its rows are the same bytes as
  yorc-rs's. On the same allocator it takes about half yorc-rs's time on
  average (0.52) and 0.46 of the time of ORCID's Java library. See
  [BENCHMARKS.md](BENCHMARKS.md), reproducible with the public harness
  [yorc-bench](https://github.com/mgbilby/yorc-bench).

## Zig version

**yorc-zig requires a Zig development snapshot:
`0.18.0-dev.131+41f885830`** (`minimum_zig_version` in build.zig.zon). It
uses the std of that snapshot, including `std.Io`, `std.Io.Reader`/`Writer`,
`std.http.Client` over `Io`, `@backingInt` and `std.process.Init`. Older
releases such as 0.14 and 0.15 will not build it.

We plan to move to the next stable Zig release once it ships. Until then,
use exactly this snapshot (from ziglang.org/builds or a pinned toolchain).

## Install

```sh
zig fetch --save git+https://github.com/mgbilby/yorc-zig#v0.1.0
```

In `build.zig`:

```zig
const yorc_dep = b.dependency("yorc", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("yorc", yorc_dep.module("yorc"));
// only if you read ORCID's Public API:
exe.root_module.addImport("yorc_client", yorc_dep.module("yorc_client"));
```

| module | contents |
|---|---|
| `yorc` | `id`, `model`, `xml`, `json`, `rows`, `hash`, `dump`, `reservoir` (no network code). `rows` also has, opt-in: `rows.Extra` (yorc-duckdb's `timeline` and `group_ids`), `rows.changes` (its `orcid_changes`, the field-level diff of two snapshots), `Tables.take` and `rows.sectionRows`; `model` has the peer-review group ids of group-id-3.0 (`GroupIdRecord`, `GroupIdRecords`) |
| `yorc_client` | blocking ORCID Public API v3.0 reader (`pub.orcid.org` only; optional `/read-public` token) (imports `yorc`) |

## Quick start

These examples run inside `pub fn main(init: std.process.Init) !void`, with
`const gpa = init.gpa;` and `const io = init.io;`.

### Read an ORCID XML record

The input can be a saved `/record` response, a Public Data File member, or
any other v3.0 document:

```zig
const yorc = @import("yorc");

const bytes = try std.Io.Dir.cwd().readFileAlloc(io, "0000-0002-1825-0097.xml", gpa, .limited(64 << 20));
defer gpa.free(bytes);

var diag: yorc.Diagnostic = .{};
var doc = yorc.xml.parse(gpa, bytes, .{}, &diag) catch |err| {
    std.debug.print("{f}\n", .{diag}); // position, element path, message
    return err;
};
defer doc.deinit();

std.debug.print("iD: {?s}\n", .{doc.orcid()});
if (doc.record()) |r| if (r.person) |p| if (p.name) |n|
    std.debug.print("{?s} {?s}\n", .{ n.given_names, n.family_name });
if (doc.activitiesSummary()) |a| {
    var it = a.workSummaries();
    while (it.next()) |w| std.debug.print("- {?s}\n", .{if (w.title) |t| t.title else null});
}
```

`Document` owns all of its memory in an arena; `deinit` frees it. Model
values are plain slices into that arena.

### Write XML or JSON

```zig
const xml = try yorc.xml.toOwned(gpa, &doc.root, null); // exact, ORCID's prefixes
defer gpa.free(xml);
const json = try yorc.json.toOwned(gpa, &doc.root, null); // ORCID's JSON form
defer gpa.free(json);
var again = try yorc.json.parse(gpa, "record", json, null); // kind = root element name
defer again.deinit();
```

### Section tables (yorc-duckdb's layout)

```zig
const hash = yorc.hash.sha256Hex(bytes);
var tables = try yorc.rows.Tables.fromDocument(gpa, &doc, &hash);
defer tables.deinit();
for (tables.get(.works), 0..) |_, i|
    std.debug.print("{f}\n", .{tables.cell(.works, i, "title").?});
```

There are fourteen sections (`works`, `fundings`, `affiliations`,
`peer_reviews`, `research_resources`, `research_resource_items`,
`contributors`, `external_ids`, `person`, `person_items`, `history`,
`search_results` and `errors` for API messages, and
`research_resource_hosts` with every host) with 300 columns in all. Names, order and types match the
[yorc-duckdb](https://github.com/mgbilby/yorc-duckdb) extension.

### Stream a Public Data File

```zig
const fa = try yorc.dump.FileArchive.open(gpa, io, "ORCID_2025_10_summaries.tar.gz");
defer fa.deinit();
while (try fa.archive.nextXml()) |m| {
    const xml_bytes = try fa.archive.read(m, 64 << 20); // valid until the next member
    var d = try yorc.xml.parse(gpa, xml_bytes, .{}, null);
    defer d.deinit();
    // ...
}
```

Members are read in archive order without unpacking. A member you never
`read` is skipped. `yorc.dump.Archive.init(gpa, reader)` works over any
`*std.Io.Reader` of gzip bytes.

### Sample reproducibly

`yorc.reservoir.Reservoir(T)` is a seeded reservoir sampler (SplitMix64).
For a given seed it picks exactly what yorc-rs's `dump::Reservoir`
picks. `offer()` decides an item's fate before its content is read, so
skipped members cost nothing:

```zig
var res: yorc.reservoir.Reservoir([19]u8) = .init(1000, 42);
defer res.deinit(gpa);
while (try fa.archive.nextXml()) |m| {
    const id = yorc.OrcidId.parse(yorc.dump.xmlEntryStem(m.name).?) catch continue;
    const slot = res.offer();
    if (slot == .skip) continue;
    _ = try res.put(gpa, slot, id.text);
}
```

### Read from ORCID's Public API

The client reads ORCID's Public API (`https://pub.orcid.org/v3.0`) only; it
has no access to the ORCID Sandbox or the ORCID Member API. It is for
**occasional single-record retrieval**. Every request to ORCID's hosts
(`orcid.org` and its subdomains), the optional token call and retries
included, goes through one process-wide limiter at **one request every
45 s**, strictly one at a time; a faster limiter is clamped. For bulk data
use the Public Data File and `yorc.dump`, which reads local files and is
not throttled (nor are dump downloads from Figshare or ORCID's S3/CDN
mirrors). There are no crawling or parallel-fetching helpers.

```zig
const client = @import("yorc_client");

var c = try client.Client.init(gpa, io, .{ .access = .public }, null);
defer c.deinit();
var fail: client.Failure = .{};
defer fail.deinit(gpa);
var rec = c.record("0000-0002-1825-0097", .xml, &fail) catch |err| {
    if (fail.orcidError()) |e| std.debug.print("{?s}\n", .{e.developer_message});
    return err;
};
defer rec.deinit();
```

- **Access**, fixed at `init`: `.public` (`pub.orcid.org`, public reads;
  the token call goes to `orcid.org/oauth/token`); `.custom` is for mock
  servers. Every request URL is checked against these hosts before it is
  sent; redirects are never followed.
- **Reads.** `record`, `person`, `works`, `work` (one put-code),
  `worksBulk` (up to 100 put-codes) and `section` (any v3.0 section path)
  return a `Document`. `recordRaw` returns the status and the exact bytes.
  Every read accepts `.xml` or `.json`. Reads are anonymous unless
  `Config.token` (a `*const Token`) is set; it is sent as
  `Authorization: Bearer`, and only a `/read-public` token of the client's
  `Realm` is accepted.
- **Rate limit.** One request every 45 s to ORCID, process-wide
  (`RateLimiter.global`); a limiter passed to `init` can only slow a client
  further. Only `.custom` may go faster.
- **Retries.** GET is retried on 5xx and transport
  errors, at most 3 attempts in all, honouring `Retry-After`. POST is
  never retried; a 429 is not retried and pauses the limiter for its
  `Retry-After`.
- **Errors.** API errors come back as `error.Api`, with the status, the
  body and the parsed error-3.0 document in `Failure`; refused operations
  as `error.Usage` with `Failure.message`.
- **Optional token.** `Client.readPublicToken(client_id, client_secret,
  &fail)` returns a 2-legged `/read-public` token (ORCID's
  `client_credentials` grant for Public API credentials). There is no
  sign-in (3-legged) OAuth and no member-scoped token.

Following the ORCID terms of service and the record holders' visibility
choices is your responsibility.

## Building and testing

```sh
zig build test                        # library, client and integration tests
zig build test -Dtest-filter=json     # only tests whose name contains "json"
zig build test --fuzz                 # also fuzz the XML, JSON and iD readers
zig build walkthrough                 # WALKTHROUGH.md, cells 0 to 8
zig fmt --check build.zig build.zig.zon src tests examples testdata/fixtures.zig
```

The tests need no network access. The client tests run against a local
mock server on 127.0.0.1, and the fixtures are embedded from `testdata/`.
ORCID's schemas and samples there are MIT-style licensed, and the real
records are CC0. See NOTICE for details. `testdata/` and `tests/` are not
part of the package.

## Performance

yorc-zig never allocates on its own: every call that allocates takes an
`std.mem.Allocator`, and the choice matters. Writing a record, building its
rows, the timeline and the diff allocate and free sizeable blocks; with
Zig's default `std.heap.smp_allocator`, which hands large blocks back to the
operating system, each call faults in fresh pages. On the maintainer's
machine (2026-10-19) the same code ran 1.3x to 3.2x faster on those
workloads with libc's malloc, and no slower anywhere
([BENCHMARKS.md](BENCHMARKS.md); the benchmark programs are in
[yorc-bench](https://github.com/mgbilby/yorc-bench), whose Zig program
is built both ways).

For throughput:

- link libc and pass `std.heap.c_allocator` (in `build.zig`,
  `.link_libc = true` on your module; `std.process.Init.gpa` is then malloc),
  or
- give each batch of documents an `std.heap.ArenaAllocator` and reset it
  between batches, so its pages are reused.

## Documentation

- ARCHITECTURE.md: module layout, memory ownership, reader and writer
  design, client internals.
- PARITY.md: yorc-rs items next to their yorc-zig counterparts, with
  the gaps.
- BENCHMARKS.md: timings against yorc-rs, yorc-duckdb and ORCID's Java
  library, and the cross-check of their outputs; the harness is
  [yorc-bench](https://github.com/mgbilby/yorc-bench).
- CHANGELOG.md: release notes.

## Contributing

Bug reports and pull requests are welcome.

- Every change in behaviour comes with a test; run `zig fmt` and
  `zig build test` (also with `-Doptimize=ReleaseSafe`) before opening a
  pull request.
- Written XML and JSON must stay byte-identical with yorc-rs for the same
  model: a change to the output format is a change to both libraries.
- New model fields follow the v3.0 XSDs; `tests/schema_test.zig` walks them.
- Code is written from the specifications, not copied from other ORCID
  software (NOTICE).

## License

MIT, see LICENSE. Third-party material and trademarks: NOTICE. ORCID is a
trademark of ORCID, Inc. This library is not affiliated with or endorsed by
ORCID, Inc.

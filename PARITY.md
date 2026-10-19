# Parity with yorc-rs

This table maps the public items of the Rust crate
[yorc-rs](https://github.com/mgbilby/yorc-rs) 0.1.0 to their
yorc-zig 0.1.0 counterparts. The aim is the same behaviour on the same
input: the same documents read, the same bytes written, the same rows and
the same reservoir picks. Names follow Zig conventions: `snake_case`
functions become `camelCase`, `Result` becomes an error union, `Option`
becomes `?T`, and owned values take an allocator and have a `deinit`.
The byte-for-byte cross-check of the two (and of yorc-duckdb and ORCID's
Java library) on the same inputs is in
[yorc-bench](https://github.com/mgbilby/yorc-bench), with a feature
comparison of the three packages (its `PARITY.md`) and a static review of
the rules on which they differ (its `CROSSCHECK.md`).

Status:

- **same**: same behaviour, tested on the same fixtures.
- **adapted**: same capability with a different shape; the difference is
  noted.
- **gap**: not in yorc-zig 0.1.0.

## id

| yorc-rs | yorc-zig | status |
|---|---|---|
| `id::check_char` | `id.checkChar` | same |
| `id::normalize` | `id.normalize` → `?[19]u8` (no allocation) | same |
| `id::is_valid` | `id.isValid` | same |
| `OrcidId::parse`, `as_str`, `uri`, `Display` | `OrcidId.parse`, `slice`, `uri` (→ `[37]u8`), `format` (`{f}`) | same |
| `OrcidId::into_string` | `id.text` (a `[19]u8` value) | adapted |
| `InvalidOrcidId` | `error.InvalidOrcidId` | adapted (no payload) |

## model

| yorc-rs | yorc-zig | status |
|---|---|---|
| every struct/enum of `model::{common, activities, person, record}` | the same names in `model` (`Work`, `Funding`, `Affiliation`, `PeerReview`, `ResearchResource`, `Person`, `Record`, ...) | same fields, `snake_case` |
| closed enums with `Other(String)` | `Vocab(E)`: `.known` / `.other`, `@tagName` = the XML text | adapted |
| `AffiliationKind` | `model.AffiliationKind` (`element`, `summaryElement`, `containerElement`, `from*`) | same |
| `Root`, `Document` (`orcid`, `record`, `activities_summary`) | `model.Root` (snake_case tags, `.@"error"`, `.unknown`), `Document` (`orcid`, `record`, `activitiesSummary`, `deinit`) | same |
| `ActivitiesSummary::work_summaries` | `ActivitiesSummary.workSummaries` (iterator) | same |
| `#[derive(PartialEq, Debug)]` | `model.eql`, `model.firstDifference` (path of the first difference) | adapted |
| `json::KINDS`, `json::kind_of` | `model.kinds`, `Root.kind()` | same |
| `GroupIdRecord`, `GroupIdRecords`, `GroupType`, `Root::GroupIdRecord`, `Root::GroupIdRecords` (group-id-3.0) | `model.GroupIdRecord`, `GroupIdRecords`, `GroupType`, `Root.group_id_record`, `.group_id_records` | same (2026-10-18): XML read and write (written by a small emitter of its own, as yorc-rs's `xml/write/group_id.rs`, so `Ns` is unchanged), JSON read and write |

## xml

| yorc-rs | yorc-zig | status |
|---|---|---|
| `xml::from_str`, `from_slice` | `xml.parse(gpa, bytes, .{}, ?*Diagnostic)` | same reads. Adds a depth limit (`Options.max_depth`) and a `Diagnostic` with the position and element path. |
| `xml::to_string`, `document_to_string` | `xml.write(*Writer, root, diag)`, `xml.toOwned` | same bytes. Both write in one pass (one pre-sized buffer, namespaces as a bit set inserted after the root's name, one escape-and-check scan, no formatting machinery). `toOwned` is the one-pass path; `write` into any writer, which has no allocator to buffer with, adds a dry run into a discarding writer for the namespaces, and writes nothing on `error.Unwritable`. |
| `xml::Ns` (`prefix`, `uri`, `of_affiliation`) | `xml.Ns` (`prefix`, `uri_base`, `ofAffiliation`) | same |
| quick-xml | own scanner `xml.scan` (exposed for raw tokens) | adapted. **Gap:** attribute syntax errors, such as a missing `=` or quote, make `parse` fail with `MalformedXml`. quick-xml-based reading skips the broken attribute. |

## json

| yorc-rs | yorc-zig | status |
|---|---|---|
| `json::from_str`, `from_slice` (with kind) | `json.parse(gpa, kind, bytes, diag)` | same |
| `json::from_value(serde_json::Value)` | `json.fromValue(gpa, kind, *const std.json.Value, diag)` | adapted (std.json). The value is written out as text and read by the streaming reader; the result is the reader's on that text. |
| `json::to_string` | `json.write`, `json.toOwned` | same bytes (sorted keys, serde pretty layout) |
| `json::to_value` | none | **gap:** write to a string and parse it with `std.json` instead |
| `millis_to_datetime`, `datetime_to_millis` | `json.millisToDatetime(buf, ms)`, `json.datetimeToMillis` | same |
| float numbers | kept as their source text | adapted. serde parses them to `f64`, which may reformat a non-integer number. yorc-zig keeps the text, which only matters for values that are not ORCID integers. |

## rows and hash

| yorc-rs | yorc-zig | status |
|---|---|---|
| `Section` (`name`, `from_name`, `columns`, `column_index`), `Column`, `ColType` | the same, camelCase | same: 14 sections and 300 columns, including the columns after `source_hash` (`peer_reviews.subject_translated_name_language`, `errors.primary_orcid` and the 21 appended on 2026-10-18) |
| `Cell` (`is_null`, `as_str`, `as_i64`, `as_bool`) | `rows.Cell` (`isNull`, `asStr`, `asInt`, `asBool`, `format`) | same |
| `Tables::from_document`, `from_xml`, `get`, `cell` | `rows.Tables.fromDocument(gpa, doc, hash)`, `fromXml`, `get`, `cell`, `count`, `deinit` | same |
| `Tables::take`, `section_rows` | `Tables.take` (the rows stay in the tables' memory, valid until `deinit`), `rows.sectionRows` → `SectionRows` (`rows`, `tables`, `deinit`) | adapted (2026-10-18): the memory stays with the tables |
| `rows::Extra` (`Timeline`, `GroupIds`; `name`, `from_name`, `columns`, `column_index`, `rows`), `timeline`, `group_ids`, `Tables::extra_from_xml` | `rows.Extra` (`.timeline`, `.group_ids`; `name`, `fromName`, `columns`, `columnIndex`), `rows.extraRows`, `timeline`, `groupIds`, `extraFromXml` → `ExtraRows` (`rows`, `cell`, `deinit`) | same rows (2026-10-18): yorc-duckdb's `orcid_timeline` and `orcid_group_ids`, outside `Section.all` and `Tables` |
| `rows::changes`, `Change` (`to_row`), `ChangeKind`, `CHANGE_COLUMNS`, `DIFF_SECTIONS` | `rows.changes(gpa, ?old, ?new)` → `Changes` (`items`, `deinit`), `Change` (`cells`), `ChangeKind`, `change_columns`, `diff_sections` | same (2026-10-18): yorc-duckdb's `orcid_changes` |
| `hash::sha256_hex` | `hash.sha256Hex` → `[64]u8` | same |

## dump and reservoir

| yorc-rs | yorc-zig | status |
|---|---|---|
| `dump::open(path)` | `dump.FileArchive.open(gpa, io, path)`, `openAt(gpa, io, dir, sub_path)` | same |
| tar over any `Read` | `dump.Archive.init(gpa, *std.Io.Reader)`, `next`, `nextXml` | same |
| `dump::read_entry` | `Archive.read(member, limit)` | same (limit → `CorruptArchive` with `detail = StreamTooLong`) |
| `is_dump_path`, `xml_entry_stem` | `isDumpPath`, `xmlEntryStem` | same |
| flate2 `MultiGzDecoder` | `std.compress.flate.Decompress` (`.gzip`), a fresh one per member (`Archive.gzip_members`) | same: concatenated members are read as one stream; input after a member that is not a gzip header is an error (`CorruptArchive`, `detail = BadGzipHeader`), as in flate2 |
| `SplitMix64` (`new`, `next_u64`, `below`) | `reservoir.SplitMix64` (`init`, `next`, `below`) | same output |
| `Reservoir` (`new`, `offer`, `put`, `seen`, `into_items`), `Slot` | `reservoir.Reservoir(T)` (`init`, `offer`, `put` → evicted item, `seen`, `slice`, `deinit`), `Slot` | same picks (contract vectors tested) |

## blocking → yorc_client

Both read ORCID's Public API only (`https://pub.orcid.org/v3.0`), for
occasional single-record retrieval: one process-wide limiter for ORCID's
hosts, one request every 45 s, one at a time, the optional `/read-public`
token call and retries included (only `Custom` / `.custom` mock servers may
go faster). Neither provides access to the ORCID Sandbox or the ORCID
Member API, nor sign-in (3-legged) OAuth: that is out of scope for the
public packages. Bulk data comes from the Public Data File (`dump`), which
is not throttled.

| yorc-rs | yorc-zig | status |
|---|---|---|
| `Access` (`Public`, `Custom { api, oauth }`; `realm`, `is_orcid`, `api_base`, `oauth_base`, `permits`, `check_token`) | `client.Access` (`.public`, `.custom`; `realm`, `isOrcid`, `apiBase`, `oauthBase`, `permits`, `checkToken`) | same |
| `Realm` (`Production`, `Custom`), `Purpose` | `client.Realm` (`.production`, `.custom`), `Purpose` | same |
| `PUBLIC_API`, `OAUTH`, `SCOPE_READ_PUBLIC` | `public_api`, `oauth`, `scope_read_public` | same |
| `Config::new` | `client.Config` (defaults) | same fields, plus `max_body`; reads take a per-call `Format` (XML or JSON) |
| `ORCID_INTERVAL`, `ORCID_MAX_ATTEMPTS` | `orcid_interval_ns`, `orcid_max_attempts` | same (45 s, 3) |
| `RateLimiter::new`, `with_interval`, `orcid`, `interval`, `acquire`, `pause` | `client.RateLimiter.init(io, rate)`, `initInterval`, `global(io)` (Zig: `orcid` would shadow the module import), `interval_ns`, `acquire`, `pause` | adapted; the same default, one request per 45 s (`default_interval_ns`) |
| `Client::new`, `with_limiter`, `config`, `access`, `min_interval` | `Client.init(gpa, io, config, ?*RateLimiter)`, `config`, `minInterval` | adapted. Zig has no private fields: do not change `c.config` after `init`. |
| per-call `token: Option<&Token>` on reads | `Config.token: ?*const Token`, one per client | adapted. Use one client per token; clients can share a limiter. |
| `record`, `person`, `works`, `work`, `works_bulk`, `section` (typed results) | the same names, returning a `Document` (check `.root`), XML or JSON (`Format`) | adapted. Adds JSON reads. |
| `record_raw` | `Client.recordRaw` → `Answer{status, body, location}` | same (2xx, 301 and 409 are answers) |
| `search`, `expanded_search` | none | **gap** (see below) |
| `read_public_token` (optional) | `readPublicToken(client_id, client_secret, failure)` | same (scope `/read-public`); the token carries the client's realm |
| `encode_component` | `encodeComponent` | same |
| `Token` (`new`, `is_expired`, `has_scope`, `realm`) | `client.Token` (`init`, `hasScope`, `realm`, `expires_in`, `bearer`, `deinit`) | **gap:** no `is_expired`; the caller records the time of issue |
| `ClientError` (`Usage`, `Api`, ...) | `client.Error` (`Usage`, `Api`, ...; and `InvalidOrcidId` for a bad iD, Rust: `Usage`) and `Failure` (status, body, error-3.0 doc, transport error, token-endpoint OAuth error, message) | adapted |
| ureq + rustls | `std.http.Client` (std TLS) | adapted. No automatic proxy: call `c.http.initDefaultProxies(arena, init.environ_map)` yourself. |
| async `client` (not implemented in yorc-rs either) | none | gap in both |

## Tests

| yorc-rs test | yorc-zig test | status |
|---|---|---|
| `write_roundtrip.rs` | `tests/xml_test.zig` | same samples. **Gap:** no xmllint XSD validation of written documents. |
| `write_roundtrip.rs` `writer_matches_reference_*`, `tests/reference_writer` | `tests/xml_write_test.zig`, `tests/xml_write_legacy.zig` | adapted: the values are appended in the model (every `Text`, and one at a time) rather than in the XML text; adds invalid UTF-8, edge values and 100-work bulk documents |
| `json_roundtrip.rs` | `tests/json_test.zig` | same |
| `samples.rs` | `tests/rows_test.zig` | same expectations |
| `extra_sections.rs` | `tests/extra_test.zig` | same expectations |
| `schema_coverage.rs`, `xsd_uncovered.txt` | `tests/schema_test.zig`, `testdata/xsd_uncovered.txt` | same list |
| `blocking_client.rs` and the unit tests of `blocking.rs` | `tests/client_test.zig` (mock `std.Io.net` server) and the unit tests of `client.zig` | same cases (Zig has no search test: no search) |
| the maintainer's cargo-fuzz targets over yorc-rs's XML and JSON readers (not in yorc-rs's repository) | `tests/fuzz_test.zig` (`zig build test --fuzz`) | adapted |

## Not in either library (by design)

- consent, tier and retention policy
- access to the ORCID Sandbox or the ORCID Member API (reads or writes),
  and sign-in (3-legged) OAuth: out of scope for the public packages
- crawling, paging-through-everyone and parallel-fetching helpers

## In yorc-rs only (gap)

- `Client::search` and `Client::expanded_search` (paged, `MAX_SEARCH_ROWS` 1000), added in yorc-rs's pre-release pass
- `dump::records` / `DumpRecord` (yorc-zig has `FileArchive.nextXml` instead)
- a per-request timeout setting and `Token::is_expired`

These belong to applications, not to this library.

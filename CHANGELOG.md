# Changelog

All notable changes to yorc-zig are listed here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project uses
[Semantic Versioning](https://semver.org/) (pre-1.0: minor versions may break
the API).

## Unreleased

Additive (2026-10-18). The fourteen sections, their 300 columns and the record writer
are unchanged.

### Added

- Peer-review group ids (group-id-3.0): `model.GroupIdRecord`,
  `GroupIdRecords`, `GroupType`, `Root.group_id_record` and
  `.group_id_records`; `model.kinds` gains `group-id-record` and
  `group-id-records`. XML read (the XSD's inline source fields read into
  `source`) and write (`common:source`, ORCID's `propOrder`; a small
  emitter of its own, so `Ns` keeps its 28 namespaces), JSON read and
  write (the record's dates are XML-only, as in ORCID's JSON). The same
  bytes as yorc-rs.
- `rows.Extra` (`.timeline`, `.group_ids`), `rows.extraRows`, `timeline`,
  `groupIds`, `extraFromXml` → `ExtraRows`: yorc-duckdb's `orcid_timeline`
  and `orcid_group_ids`, as yorc-rs's `rows::Extra`.
- `rows.changes(gpa, old, new)` → `Changes` (`Change`, `ChangeKind`,
  `change_columns`, `diff_sections`): yorc-duckdb's `orcid_changes`, as
  yorc-rs's `rows::changes`.
- `Tables.take` and `rows.sectionRows` (yorc-rs's `Tables::take` and
  `section_rows`; the rows stay in the tables' memory).
- `tests/extra_test.zig` and the fixtures `testdata/group-id-3.0/`,
  `testdata/changes/`.

### Fixed

- XML: an `&` looks for its `;` no further than a reference name can reach
  (11 bytes in attribute values), and text with no `;` after an `&` is
  copied as it is, so a run of `&` decodes in linear time instead of
  quadratic. The decoded text does not change.

## 0.1.0 (unreleased)

First release. Requires Zig `0.18.0-dev.131+41f885830` (a development
snapshot; see README, "Zig version").

Developed as orcid-zig (now yorc; package and module `yorc`, repository
`yorc-zig`), renamed on 2026-10-18 to stay clear of ORCID's trademark.

### Added

- Scope: yorc-zig does not provide access to the ORCID Sandbox or the
  ORCID Member API (no member reads or writes, no payload validation, no
  payload writers). It is an independent open-source project, not
  affiliated with, endorsed by or sponsored by ORCID, Inc.
- `yorc.id`: `OrcidId` (parse, normalise URL forms, missing hyphens and a
  lowercase `x`; ISO 7064 MOD 11-2), `normalize`, `isValid`, `checkChar`.
- `yorc.model`: types for every data-bearing element and attribute of the
  ORCID v3.0 record XSDs, open vocabularies (`Vocab(E)`: `.known` or
  `.other`), `Document` / `Root` for every root element, deep `eql` and
  `firstDifference`.
- `yorc.xml`: lenient reader (own pull scanner, UTF-8 and XML character
  checks, depth limit, entity and character references) and an exact,
  deterministic writer with ORCID's namespace prefixes.
- `yorc.json`: ORCID's JSON form, read and write, over the same model
  (timestamps as epoch milliseconds, ORCID's Java enum names where the API
  uses them). `history/@visibility` is XML-only: the JSON writer leaves it
  out, as ORCID's own JSON does (ORCID's Java model refuses the unknown
  member); the reader still accepts it. Same bytes as yorc-rs
  (cross-implementation review #16).
- `yorc.rows`: the section tables of yorc-duckdb (14 sections, 300
  columns, same names, order and types as yorc-rs; `search_results` and
  `errors` from search, expanded-search, error and bulk documents;
  `research_resource_hosts` with every host; the assertion origin,
  normalization error code, contributor host and the record's
  `orcid-identifier` URI and host columns appended on 2026-10-18), `yorc.hash.sha256Hex` for `source_hash`.
- `yorc.dump`: streaming access to Public Data File `.tar.gz` archives
  (`Archive` over any `*std.Io.Reader`, `FileArchive` by path), and
  `yorc.reservoir`: the seeded SplitMix64 reservoir sampler, bit-compatible
  with yorc-rs's.
- `yorc_client`: a blocking ORCID Public API v3.0 reader over
  `std.http.Client` for occasional single-record retrieval, against
  `https://pub.orcid.org/v3.0` only (`Access.public`; `.custom` for mock
  servers). Reads (record, person, works, work, bulk works, any section,
  raw bytes), XML or JSON, anonymous or with an optional `/read-public`
  `Config.token` that carries its `Realm`; every URL checked against the
  client's hosts (`Access.permits`); one process-wide
  limiter for ORCID's hosts, one request every 45 s, one at a time
  (`RateLimiter.global`; a faster limiter is clamped, only `.custom` may go
  faster); retries of GET only, at most 3 attempts, none after
  a 429; error-3.0 bodies parsed into `Failure`; the optional 2-legged
  `/read-public` token (`Client.readPublicToken`). No Member API, no
  Sandbox, no sign-in (3-legged) OAuth.
- `yorc.json` reading is a single-pass streaming reader straight onto the
  model (no `std.json.Value` tree, no map per object): keys dispatched by
  length and vector compare, strings borrowed until kept and decoded only
  when escaped, vectorised string and whitespace scans, list items on one
  scratch stack, document memory bump-allocated from its arena. Same
  documents, errors and `Diagnostic` messages as the `std.json` reader it
  replaces (kept in `tests/json_legacy.zig` as the test oracle); no
  recursion on the input's nesting.
- `yorc.rows`: columns resolved at compile time, rows counted first so row
  lists and cells are allocated once per section, static text not copied,
  document text copied into a bump area.
- `yorc.xml` writing is one pass, with yorc-rs's one-pass techniques:
  `toOwned` writes straight into one buffer pre-sized from
  the model's shape; the namespaces in use are a bit set whose declarations
  are inserted after the root's name at the end (one memmove); escaping and
  the XML 1.0 character check (control characters, U+FFFE/U+FFFF, invalid
  UTF-8) are one `@Vector` scan that copies plain runs in bulk; integers and
  padded dates without `std.fmt`; indentation as a slice of a constant.
  Same API, bytes, errors and `Diagnostic`s as the two-pass writer it
  replaces (kept in `tests/xml_write_legacy.zig` as the test oracle).
  `write` into any writer now writes nothing when the model
  is unwritable (they did write a partial document).
- `yorc.dump` reads concatenated gzip members (RFC 1952 multi-member
  files, `cat a.gz b.gz`) as one stream, as flate2's `MultiGzDecoder` and
  DuckDB do; `Archive.gzip_members` counts them. Input after a member that
  is not a gzip header is `CorruptArchive` (`detail = BadGzipHeader`).
- Tests: every ORCID read and write sample round-trips in XML, every JSON
  sample in JSON, XML ↔ JSON equivalence, an XSD coverage walk,
  section rows (ported from yorc-rs), dump streaming and sampling,
  a mock-server client suite, and fuzz entry points for the readers.
- Tests: the XML writer against the writer it replaced (samples, the real
  record, escapes, multi-byte text, forbidden characters and invalid UTF-8
  in every value, bulk documents, edge values), the escape scan
  at every chunk offset, and concatenated gzip members (a Python-built
  two-member fixture, stored members built at test time).

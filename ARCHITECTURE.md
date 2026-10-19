# yorc-zig architecture

yorc-zig ports the Rust crate yorc-rs to Zig. Both read the same
documents the same way and write the same bytes. They also produce the same
rows and the same reservoir picks. Where the two differ, PARITY.md says so.

## Layout

```
build.zig            modules `yorc` and `yorc_client`; `zig build test`
src/root.zig         module `yorc`: re-exports
  id.zig             OrcidId, MOD 11-2, normalisation
  model.zig          v3.0 types, Vocab(E), Root, Document, eql/firstDifference
  utf8.zig           UTF-8 decoding, XML Char production, Unicode whitespace
  diag.zig           Diagnostic (position, element path, message)
  xml.zig            public XML API over:
    xml_scan.zig       pull scanner (tags, attributes, text, CDATA; skips PI,
                       comments, DOCTYPE), entity/character reference decoding
    xml_read.zig       element tree + mapping onto the model
    xml_write.zig      exact writer, namespace table (Ns)
  json.zig           ORCID JSON read (streaming, straight onto the model) and
                     write (own tree)
  rows.zig           yorc-duckdb's section tables
  rows_extra.zig     the opt-in timeline and group_ids sections, the snapshot
                     diff (changes) and sectionRows
  bump.zig           non-atomic bump allocation over an arena (json, rows)
  hash.zig           sha256Hex
  dump.zig           tar.gz streaming (std.compress.flate + std.tar)
  reservoir.zig      SplitMix64 + reservoir sampler
src/client.zig       module `yorc_client`: std.http.Client ORCID Public API reader
testdata/            ORCID XSDs and samples, a real record, a dump archive;
  fixtures.zig       embeds them (@embedFile) as the `fixtures` test module
tests/               integration tests (imports orcid, yorc_client, fixtures)
```

## Memory

- **Documents.** A `Document` holds an `ArenaAllocator`. Everything the
  reader produces lives in that arena: strings, slices of items, nested
  structs. The model uses plain `[]const u8` (`Text`) and slices, with no
  per-node ownership, and `Document.deinit` frees everything.
- **Model values you build.** These can point anywhere, such as string
  literals or your own buffers. The writers only read them.
- **Writers.** They take a `*std.Io.Writer`. The `toOwned` variants return a
  slice allocated with the allocator you pass.
- **Tables.** A `rows.Tables` copies every string into its own arena, so it
  outlives the `Document` it came from.
- **Archives.** `dump.Archive` is heap-allocated so the reader chain (gzip
  window, tar iterator, name buffers) keeps stable addresses. The bytes
  returned by `read` stay valid until the next member.
- **Allocators.** No function allocates behind your back; each one takes an
  allocator. The library has no global state. The only shared mutable
  object is the client's `RateLimiter`, which is guarded by `std.Io.Mutex`.

## Errors and diagnostics

Every fallible function returns a small explicit error set, such as
`xml.ParseError`, `json.ParseError`, `xml.WriteError`, `dump.Error` and
`client.Error`. Details go to an optional caller-owned `*Diagnostic`, which
records:

- the byte position
- the element path, e.g. `record/person/name/given-names`
- a message
- the offending code point, where there is one

The client uses `*Failure` for the same role and also records the HTTP
status, the body and the parsed error-3.0 document. Passing `null` skips
the details. The library never panics on input data, and the fuzz tests
check this.

## XML reading

1. **Pre-checks.** `parse` strips a UTF-8 BOM and rejects invalid UTF-8.
2. **Scanning.** `xml_scan.Scanner` walks the bytes and yields start tags,
   end tags, text and CDATA. Processing instructions, comments and the
   DOCTYPE, including an internal subset, are skipped. Nothing is resolved
   from outside the document.
3. **Building the tree.** `buildTree` assembles a lightweight element tree
   in a scratch arena. It checks:
   - that tags match
   - duplicate attributes
   - the XML `Char` production
   - entity and character references
   - the depth limit (`Options.max_depth`, 256 by default)

   Elements are matched by local name, as yorc-rs does. Namespace
   prefixes are kept for the writer and for the schema test.
4. **Mapping.** The mapping functions in `xml_read.zig` mirror yorc-rs's
   `xml.rs` one for one:
   - unknown elements are skipped
   - unknown vocabulary values become `.other`
   - malformed numbers become null
   - a text-only element with child elements keeps its concatenated text

   The root element picks the `Root` variant. Unknown roots map to
   `.unknown`.

## XML writing

`xml_write.zig` writes in one pass, with the techniques of yorc-rs's
one-pass writer:

- **One buffer, pre-sized.** `toOwned` writes straight
  from the model into one `Writer.Allocating`, sized from the model's shape
  (`estimate`: counts of items and ids, yorc-rs's figures). Start tags
  stay open until the first child or the end, so an empty element is
  `<x/>`.
- **Namespaces as a bit set.** Each element sets its namespace's bit. When
  the document is complete, the declarations of the namespaces used
  (ORCID's prefixes, `Ns`, 28 entries, in `Ns` order) are inserted after
  the root's name with one memmove; room for all 28 is reserved up front.
- **One scan for escaping and the XML 1.0 check.** `escape` finds the next
  byte that needs attention with `@Vector` compares
  (`std.simd.suggestVectorLength`, then 16 and 8 bytes, then byte by byte):
  control bytes, `&`, `<`, `>`, `"` in attributes, and every byte from
  0x80. Plain runs between them are copied in bulk. yorc-rs flags only
  0xEF among the non-ASCII bytes (the lead byte of U+FFFE/U+FFFF) because a
  Rust `&str` is valid UTF-8 already; a Zig slice is not, so each
  non-ASCII run is decoded sequence by sequence, which also refuses
  invalid UTF-8.
- **No formatting machinery.** Integers and zero-padded dates are written
  digit by digit (`padInt`, Rust's `{:0N}`); indentation is a slice of a
  constant; a tag's markup is one bounds check and plain copies (`put`).
- **Errors.** The element path of an `error.Unwritable` is built from the
  stack of open elements only when it is needed.

`write` takes any `*std.Io.Writer` and no allocator, so it cannot insert
into what it has already written. It runs the same
emitter twice: first into a `Writer.Discarding`, which yields the
namespaces in use (and any `error.Unwritable`, so nothing reaches the
writer on error), then into the writer, declaring the namespaces as the
root is written.

The writer it replaced (two passes, `std.fmt`, a separate character check)
is kept as `tests/xml_write_legacy.zig`, the oracle of the differential
tests in `tests/xml_write_test.zig`.

The output is deterministic, and it matches yorc-rs byte for byte on
the samples:

- element order follows the XSD
- empty optional fields are omitted
- text and attributes are escaped minimally
- zero-padded dates follow Rust's `{:0N}`

Some values are rejected with `error.Unwritable`, not written invalid. An
example is a funding contributor's `contributor-sequence`, which the
funding schema does not have.

## JSON

- **Reading.** One pass over the bytes, straight onto the model, with no
  value tree and no map per object. Each type's reader walks its object key
  by key: `keyOf` turns the key into a `Key` (a switch on the length, then
  a vector compare with each known key of that length) and the reader
  switches on it. Unknown keys and values of the wrong shape are skipped,
  their syntax checked; a field is assigned each time its key is read, so a
  duplicate key keeps its last value. Strings are borrowed from the input
  while they are inspected (vocabularies, integers, booleans) and copied
  into the document only when the model keeps them; only strings with
  escapes are decoded. The scan to a string's end and over indentation is
  a `@Vector` compare with a scalar tail. List items collect on one scratch
  stack and move to the document when the list closes. Document memory is
  bump-allocated (`bump.zig`) in chunks of its arena, the first sized from
  the input. Syntax is checked as std.json checks it, with its error names
  (`SyntaxError`, `UnexpectedEndOfInput`) in `Diagnostic.message`. Nothing
  recurses on the input's nesting: readers recurse along the schema only,
  and skipped values and `{"value": ...}` chains use an explicit bracket
  stack. `fromValue` writes the `std.json.Value` out as text (numbers in two
  private spellings that keep `.float` and `.number_string` apart) and
  reads it back. `kind` names the root element, as yorc-rs's
  `json::from_str` does. The `std.json.Value` reader this replaced is kept
  in `tests/json_legacy.zig` as the oracle of differential tests.
- **Writing.** The writer builds its own small tree (`J`), sorts each
  object's keys and prints with serde_json's pretty layout. Output is
  deterministic and byte-identical to yorc-rs's.
- **Timestamps.** These are epoch milliseconds in JSON and RFC 3339 in
  XML. `millisToDatetime` and `datetimeToMillis` convert between them,
  using a proleptic Gregorian civil-from-days conversion with no time zone
  database.
- **Enum names.** `creation-method` and similar fields use ORCID's Java
  enum names, as the API does.

## Rows

`rows.Tables.fromDocument` ports yorc-rs's `rows.rs` walker. Each row
is an array of `Cell` (`null`, `varchar`, `integer`, `boolean`) in the
column order of its `Section`. Column definitions are static tables, 300
columns over 14 sections, as yorc-rs. The walker names columns at compile time
(`RowBuilder(section).set("title", ...)` resolves to an index, and a
missing column is a compile error). A first pass (`Counter`) counts the rows
of each section, so every row list and one block of cells per section are
allocated once, at their final size. Document text is copied into a bump
area of the tables' arena; static text (item and container names, known
vocabulary values) is not copied. `source_hash` is the caller's string, normally
`hash.sha256Hex` of the document bytes.

`rows_extra.zig` (2026-10-18) adds what yorc-rs's `rows/extra.rs` and
`rows/changes.rs` add, kept outside `Section.all` and `Tables` so that the
fourteen sections, `Counter` and the walker stay as they are: the `timeline`
and `group_ids` sections (`rows.Extra`, built by their own walkers into an
`ExtraRows` arena) and `rows.changes`, the field-level diff of two snapshots
over the `Tables` of each side. Group-id documents are written by a small
emitter at the end of `xml_write.zig` (their namespace is not one of `Ns`).

## Dump

`dump.Archive` chains:

1. the caller's `*Io.Reader` of compressed bytes
2. `std.compress.flate.Decompress` (`.gzip`, with a full `max_window_len`
   window), one gzip member after another: the archive's own `Io.Reader`
   (`gzStream`) passes the current member's bytes on and, at the member's
   end, starts a fresh decompressor if more input follows, as flate2's
   `MultiGzDecoder` does. `Decompress` consumes exactly its member (bits
   are peeked, whole bytes taken, then the 8-byte trailer), so the next
   member's header comes next. Input that is not a gzip header is
   `CorruptArchive` with `detail` `BadGzipHeader`. `gzip_members` counts
   the members begun.
3. `std.tar.Iterator`, which handles GNU long names and pax headers

`nextXml` filters for `.xml` file members. Content that is not read is
skipped by the iterator. When the decompressor or tar reports an error, the
archive returns `error.CorruptArchive` and keeps the underlying error in
`detail`.

## Reservoir

`SplitMix64` and `Reservoir(T)` follow yorc-rs's `dump::reservoir`
exactly:

- the same constants
- the same `below(n)`: Lemire's multiply-shift `(next() * n) >> 64`, with no rejection step
- the same `offer`/`put` protocol

The unit tests pin the contract vectors.

## Client

`yorc_client.Client` wraps `std.http.Client` with one `Access`, read at
`init`: `.public` (ORCID's Public API, `https://pub.orcid.org/v3.0`, and
`https://orcid.org/oauth` for the optional `/read-public` token), or
`.custom` for mock servers. It reads only; it has no access to the ORCID
Sandbox or the ORCID Member API, and no sign-in (3-legged) OAuth. A token
of another `Realm`, or one without the `/read-public` scope, is
`error.Usage` before anything is sent. Each request goes through these
steps:

1. **Host check.** `Access.permits(purpose, url)` must hold just before
   every attempt: reads go to the API base, the token call only to the
   OAuth base; the URL must be the base followed by `/`, `?` or nothing.
2. **Pacing.** Clients of ORCID's hosts (`.public`, and a `.custom` whose
   base is an ORCID host) hold `RateLimiter.global()`'s
   `serial` mutex for the whole request and take a slot at least 45 s after
   the previous one, process-wide; a limiter of their own can only slow
   them further. `.custom` clients use their own limiter only.
3. **Sending.** Redirects are not followed (`.unhandled`): a deprecated
   record answers 301 with an error document, and following it would read
   another record. A 3xx status is returned as `error.Api` (`recordRaw`
   returns it as an answer). The `Accept` header is
   `application/vnd.orcid+xml` or `application/vnd.orcid+json`. The token,
   if any, goes in an `Authorization: Bearer` header. `Location` is kept.
4. **Reading the body.** `Accept-Encoding: identity` is sent, and any other
   `Content-Encoding` is rejected. The body is capped at `max_body`.
5. **Retries.** GET retries on 5xx and transport errors, at most 3
   attempts to ORCID; POST (the token call) never. A 429 is never
   retried: the limiters are paused for its `Retry-After` and the 429 is
   returned. The wait is `Retry-After`, as delta-seconds capped at
   `max_retry_after_ms` (an HTTP-date value is ignored), or else
   exponential backoff from `backoff_base_ms`, capped at 30 s, and in any
   case the limiter's spacing.
6. **Error parsing.** When retries run out, or the status is any other
   non-2xx, the body is parsed as an error-3.0 document (XML or JSON) into
   `Failure`.

The `/read-public` token call (`readPublicToken`) runs over the same
transport: a form-encoded POST to `/oauth/token` with
`Accept: application/json`. `tokenFromJson` maps the response,
including OAuth error bodies (`error`, `error_description`), and stamps the
client's realm.

There is no async interface and no parallel fetching: each request blocks
the calling thread through the `Io` it was given, and requests to ORCID are
serialised process-wide. Bulk data comes from the Public Data File
(`yorc.dump`, not throttled).

## Tests

`zig build test` builds three test binaries: the `yorc` module's unit
tests, the `yorc_client` module's unit tests, and `tests/main.zig`.

| file | covers |
|---|---|
| xml_test | every read and write sample round-trips. The XML is compared after canonicalising (namespace-aware, whitespace-insensitive) and the model is compared deeply. Also: hostile inputs. |
| xml_write_test | differential against `xml_write_legacy.zig`, the two-pass writer the one-pass one replaced (yorc-rs's `writer_matches_reference_*`): the same bytes, or the same error, path, message and code point, on every sample and the real record; on the same documents with escapes, multi-byte UTF-8, CR/TAB/LF and quotes appended to every value; with forbidden characters and invalid UTF-8 appended to every value and to one value at a time; on bulk documents (2 and 100 works); on hand-built edge values. `write` must match `toOwned` and write nothing on error. Unit tests in `xml_write.zig` check the escape scan at every chunk offset and multi-byte UTF-8 next to escapes. |
| json_test | JSON round-trips (27 samples) against the normalised original, JSON → XML → model, and XML → JSON → model over 75 files |
| json_test (streaming reader) | differential against `json_legacy.zig`, the std.json reader it replaced: every JSON sample as every kind, the JSON of all 75 XML files, about 120 lenient and malformed inputs as every kind, `fromValue` on parsed and hand-built values; plus escapes, deep nesting, unknown keys, duplicate keys, numbers |
| rows_test | a port of yorc-rs's `tests/samples.rs`, including the real record |
| extra_test | a port of yorc-rs's `tests/extra_sections.rs`: group-id records (model, XML, JSON), `timeline` and `group_ids` rows, `changes`, `Tables.take` and `sectionRows` |
| schema_test | walks the XSDs and fails on any declared name that the model neither writes nor lists in `testdata/xsd_uncovered.txt` |
| dump_test | member listing, long names, size limit, corrupt and truncated archives, reservoir picks; concatenated gzip members (a two-member fixture made with Python's gzip, the dump fixture re-split into stored members with an empty one between, input after a member that is not gzip) |
| client_test | a mock HTTP server on 127.0.0.1 in a thread, with scripted responses, and `.custom` clients. Asserts methods, paths, headers and bodies. Covers every read, anonymous and with a token, error-3.0, no retry of POST or after a 429, refused tokens (another realm, not `/read-public`; nothing is sent), the `/read-public` token call, the shared limiter and redirects. The unit tests in `src/client.zig` cover the `.public` host set (no Member API or Sandbox host) and forged URLs, token checks and the 45 s clamp as pure functions. |
| fuzz_test | `std.testing.fuzz` entry points for the XML, JSON and iD readers, for `zig build test --fuzz` |

Expected values that come from outside the algorithm, such as reservoir
picks and element counts, were computed independently with Python. The
comments in the tests name the source of each value.

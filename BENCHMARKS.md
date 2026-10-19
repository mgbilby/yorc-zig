# yorc-zig benchmarks and parity

Timings of yorc-zig next to the other implementations of the ORCID v3.0
message schema in the yorc family, [yorc-rs](https://github.com/mgbilby/yorc-rs)
and [yorc-duckdb](https://github.com/mgbilby/yorc-duckdb), with ORCID's own
Java library ([orcid-model](https://github.com/ORCID/orcid-model) 4.0.2, JAXB
and Jackson configured as ORCID's API configures them) as the baseline. Then
how the outputs of the four compare.

## Results

### Java, Rust and Zig, Rust and Zig on the same allocator (headline)

_2026-10-19, on the maintainer's machine: median of 5 runs, the order
rotating; single-threaded. Rust and Zig both on the
system allocator (glibc malloc; the Zig program linked with libc), so the
Rust/Zig numbers compare the libraries' code. `ZigOwn` is the same Zig code
on Zig's own default allocator (`smp_allocator`). Java: ORCID's orcid-model
4.0.2 on JDK 21, steady state after JIT warm-up. Cross-check: Rust and Zig
identical (597 files); Java reads 74 of the 75 JSON documents they write
(the last is Java's own XSD check of an empty element it keeps)._

This run predates the published runs. The latest published run, with its
raw lines and notes, is in [yorc-bench's RESULTS.md](https://github.com/mgbilby/yorc-bench/blob/main/RESULTS.md).

ns/op (lower is faster); A/B is A's time over B's, so below 1 A is faster.

| workload | Java | Rust | Zig | ZigOwn | Rust/Java | Zig/Java | Zig/Rust | ZigOwn/Zig |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| id_normalize | - | 771,358 | 413,013 | 431,264 | - | - | 0.54 | 1.04 |
| xml_read_record | 13,479,587 | 5,786,816 | 3,390,065 | 4,392,490 | 0.43 | 0.25 | 0.59 | 1.30 |
| xml_write_record | 5,409,463 | 589,521 | 581,692 | 1,015,980 | 0.11 | 0.11 | 0.99 | 1.75 |
| json_write_record | 4,295,744 | 4,902,113 | 3,609,261 | 4,241,311 | 1.14 | 0.84 | 0.74 | 1.18 |
| json_read_record | 4,036,027 | 5,526,203 | 1,769,885 | 2,248,658 | 1.37 | 0.44 | 0.32 | 1.27 |
| rows_record | - | 1,140,782 | 141,981 | 461,392 | - | - | 0.12 | 3.25 |
| sha256 | 3,113,553 | 4,110,109 | 3,979,678 | 3,979,338 | 1.32 | 1.28 | 0.97 | 1.00 |
| dump_stream | 15,621,551 | 6,778,430 | 3,917,354 | 5,954,712 | 0.43 | 0.25 | 0.58 | 1.52 |
| group_ids_read | 552 | 785 | 796 | 778 | 1.42 | 1.44 | 1.01 | 0.98 |
| timeline_record | - | 417,529 | 147,434 | 354,310 | - | - | 0.35 | 2.40 |
| changes_record | - | 2,570,608 | 527,083 | 1,226,876 | - | - | 0.21 | 2.33 |
| dump_sample | - | 704,356 | 794,058 | 852,370 | - | - | 1.13 | 1.07 |
| **average** (geometric mean) | | | | | **0.67** | **0.46** | **0.52** | **1.47** |

`-`: ORCID's Java library has no counterpart (no iD utility, rows,
timeline, diff or dump reader). The Java columns average over the 7
workloads Java runs, the others over all 12.

What it says about yorc-zig:

- On the same allocator it takes about half yorc-rs's time on average
  (0.52), and is faster on 9 of the 12 workloads: 0.12 of the time for rows,
  0.21 for the diff, 0.32 for JSON reads. It is level on XML writing (0.99),
  SHA-256 (0.97) and the tiny group-id read (1.01), and behind only on the
  reservoir sample (1.13).
- Against ORCID's Java library it takes 0.46 of the time on average: 0.25 on
  XML reads and dump streaming, 0.11 on XML writes, 0.44 on JSON reads. Java
  is ahead on SHA-256 (the JDK's intrinsic, 1.28) and the sub-microsecond
  group-id read (1.44).
- Zig's own allocator costs 1.47x on average and up to 3.25x on the
  allocation-heavy workloads (rows, timeline, diff, XML write, dump stream);
  see the README, "Performance".

### All four implementations (2026-10-18, earlier run)


_2026-10-18, on the maintainer's machine, yorc 0.1.0 sources before
release: median of 5 runs, the order of the programs rotating between runs;
single-threaded. Zig 0.18.0-dev.131+41f885830: ReleaseFast for the native
CPU, Zig's own `smp_allocator` (this run predates the same-allocator
headline above). Rust: `--release`, fat LTO, one codegen unit,
`-C target-cpu=native`, the system allocator. Java: JDK 21, steady state
after JIT warm-up. DuckDB: the v1.5.6 CLI with yorc-duckdb linked in,
`SET threads = 1`. Raw lines and notes: not published (this run predates
[yorc-bench](https://github.com/mgbilby/yorc-bench))._

ns/op (lower is faster); A/B is A's time over B's, so below 1 A is faster.

| workload | Java | Rust | Zig | DuckDB (provisional) | Zig/Java | Zig/Rust |
|---|---:|---:|---:|---:|---:|---:|
| id_normalize | - | 776,062 | 447,670 | 1,845,000 | - | 0.58 |
| xml_read_record | 13,462,202 | 5,830,386 | 4,346,944 | 3,966,667 | 0.32 | 0.75 |
| xml_write_record | 5,350,607 | 596,104 | 1,023,642 | - | 0.19 | 1.72 |
| json_write_record | 4,307,037 | 4,877,996 | 4,071,753 | - | 0.95 | 0.83 |
| json_read_record | 4,061,310 | 5,607,829 | 2,226,314 | 40,966,667 | 0.55 | 0.40 |
| rows_record | - | 1,163,736 | 460,412 | 48,000,000 | - | 0.40 |
| sha256 | 3,108,650 | 4,092,053 | 3,980,834 | 226,667 † | 1.28 | 0.97 |
| dump_stream | 15,568,395 | 6,765,126 | 5,913,709 | 600,000 † | 0.38 | 0.87 |
| group_ids_read | 556 | 792 | 787 | 1,000 | 1.42 | 0.99 |
| timeline_record | - | 427,414 | 353,849 | 11,000,000 | - | 0.83 |
| changes_record | - | 2,626,577 | 1,223,644 | 6,833,333 | - | 0.47 |
| dump_sample | - | 706,061 | 854,750 | 150,000 † | - | 1.21 |
| **average** (geometric mean) | | | | | **0.58** | **0.76** |

`-`: the implementation has no counterpart (ORCID's Java library has no iD
utility, rows, timeline, diff or dump reader; yorc-duckdb has no record
writer). The Zig/Java average is over the 7 workloads Java runs, Zig/Rust
over all 12. Over the same run, Rust/Java averages 0.67.

**The DuckDB column is provisional.** Its `sha256`, `dump_stream` and
`dump_sample` figures (†) are implausibly fast, probably because the query
optimiser prunes or caches part of the work in those statements; they are
being investigated and are left out of every claim on this page. Its other
figures time one SQL statement each, planning and result handling included,
and are the closest SQL counterpart of each workload rather than the same
operation: read them as what a SQL user pays, not library against library.

What this run says about yorc-zig, on Zig's own allocator:

- Against ORCID's Java library it takes 0.58 of the time on average, and
  0.32 on XML reads, 0.19 on XML writes, 0.55 on JSON reads.
- Its 1.72 against yorc-rs on XML writing is the allocator: on malloc it is
  0.99 (table above).
- SHA-256 is level with yorc-rs and behind the JDK's intrinsic (1.28); the
  very small group-id read is under a microsecond on every side.

## Caveats

- Absolute numbers depend on the machine; compare ratios within one run.
- The headline compares Rust and Zig on the same allocator (malloc); the
  `ZigOwn` column shows Zig's own default allocator, which is slower here
  for allocation-heavy work (README, "Performance"). The allocation patterns
  differ by design (one arena per document here, a tree of individually
  allocated values in yorc-rs).
- ReleaseFast removes every safety check; a Rust release build keeps slice
  bounds checks.
- yorc-zig has its own XML scanner and reads JSON with `std.json`; yorc-rs
  uses quick-xml and serde_json.
- SHA-256 is the most sensitive to the CPU target: Zig selects SHA-NI at
  compile time from the target, so a baseline build is slower.
- Every result passes through `std.mem.doNotOptimizeAway`, timed with the
  monotonic clock; there is no benchmark harness on either side.

## Parity

In the 2026-10-18 four-way run, a cross-check fed the same inputs (the real record, ORCID's
53 read and 21 write samples, ORCID's JSON samples, 10,000 iDs and the dump
fixture) to every implementation and compared the outputs class by class:
written XML and JSON byte for byte, section rows, JSON reads, dump members,
SHA-256, group ids, timelines and changes.

- yorc-zig, yorc-rs and yorc-duckdb were identical in every compared class
  (yorc-duckdb's writers in their crosswalk mode, which emits yorc-rs's
  layout).
- ORCID's Java library, as the reference reader, read 74 of the 75 JSON
  documents the others wrote. The remaining entry is the library's own XSD
  check: ORCID's read sample `work-3.0.xml` has an empty `journal-title`,
  which the XSD's non-blank pattern rejects and yorc reads as absent.

Byte-identical output with yorc-rs is a contract of both libraries: a
difference is a bug in one of them. [PARITY.md](PARITY.md) maps the APIs
item by item.

## Reproducing

The harness that produced these figures is public:
[yorc-bench](https://github.com/mgbilby/yorc-bench). It holds the three
small driver programs (Rust, Zig, Java) and the SQL leg for the DuckDB CLI
that run the workloads above on the same inputs, print one JSON line per
workload and summarise them, the cross-check that diffs their output trees,
the committed results of the published runs, and yorc-rs, yorc-zig and
yorc-duckdb as submodules at the commits measured:

```sh
git clone --recursive https://github.com/mgbilby/yorc-bench
cd yorc-bench
./run.sh                    # Rust and Zig: build, cross-check, benchmark (Zig 0.18.0-dev.131+41f885830 on PATH)
./run.sh --duckdb --java    # all four (after `make release` in yorc-duckdb; JDK 21, Maven)
```

Its README lists the prerequisites. Its [RESULTS.md](https://github.com/mgbilby/yorc-bench/blob/main/RESULTS.md) has the latest
published run (all four implementations, with the machine, toolchains and
commits) and every earlier one, each backed by its raw lines in `results/`.

Every input is in `testdata/`. To time one operation yourself, build with
`-Doptimize=ReleaseFast` for the native CPU, call the API on those files,
keep the result alive with `std.mem.doNotOptimizeAway`, and take the median
of several runs.

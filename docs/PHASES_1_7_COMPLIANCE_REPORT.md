# Phases 1-7 Compliance Report

Date: 2026-08-08
Toolchain: Zig 0.16.0

## Verdict

Phases 1 through 7 meet their current documented acceptance criteria. Phase 6
is complete: compiled POSIX ERE rules and exact adaptive uniqueness are
implemented and verified across batches and on the 2,000,000-row fixture.

## Phase Status

| Phase | Status | Evidence |
| --- | --- | --- |
| 1 Core | Complete | Seven physical types, typed columns, null bitmaps, exact decimals |
| 2 Memory/contracts | Complete | Run/batch/scratch lifetimes, fixed error context, separate raw/output arenas |
| 3 CSV | Complete | Streaming parser, bounded records, configurable malformed/missing/extra/UTF-8 policies |
| 4 Ingestion | Complete | Conservative inference and conversion for seven types, stable owned schema |
| 5 Profiling | Complete | Numeric/string/null statistics, adaptive cardinality, JSON report |
| 6 Validation | Complete | Typed rules, compiled POSIX ERE, bounded sink, exact in-memory uniqueness and SQLite spill |
| 7 Cleaning | Complete for ASCII/ISO scope | Transform contract, trim/case/replace, date/decimal normalization, CSV sink, provenance and audit JSONL |

## Required Checks

The following checks passed:

```text
zig fmt --check build.zig src tests benchmarks
zig build test
zig build -Doptimize=ReleaseSafe test
zig build -Doptimize=ReleaseFast
```

The test build runs both module unit tests and mirrored integration tests from
`tests/`.

## Large Fixture Evidence

Input fixture:

```text
fixtures/customers-2000000.csv
349,416,788 bytes
2,000,000 rows
245 batches at batch_size=8192
```

Verified operations:

* inference: 2,000,000 rows, zero invalid values;
* profiling: 2,000,000 rows with adaptive cardinality;
* validation: six rules, zero violations;
* Phase 6 validation: email ERE plus global `Customer Id` uniqueness, zero
  violations, one uniqueness rule spilled to disk;
* cleaning: 2,000,000 rows written to a 335 MiB CSV;
* audit: 245 JSONL provenance entries, one per transformed batch;
* round trip: cleaned CSV reread as 2,000,000 rows with the date column still
  inferred as `date`.

Benchmarks executed in ReleaseFast:

```text
csv_parse rows=2000000 bytes=349416788
profiling rows=2000000 batches=245
cleaning operations=10000000 bytes=130000000
phase6 validation real=7.20s rows=2000000 batches=245 unique_rules_spilled=1
```

## Code Rule Audit

Confirmed:

* Zig 0.16 module-based build APIs;
* no compatibility branches for older Zig versions;
* `anyopaque` casts restricted to Source/Reader/Sink/Transform boundaries;
* no per-cell general-purpose allocation in cleaning hot loops;
* exact decimals never route through `f64`;
* leading-zero identifiers remain strings;
* raw and transformed batches use distinct arenas;
* violation retention and exact profiling cardinality have hard limits;
* exact uniqueness uses a hard per-rule memory buffer and automatic temporary
  SQLite B-tree spill with a bounded cache;
* regex patterns and candidate inputs have explicit size limits and are
  compiled once during rule compilation;
* malformed external input returns errors or follows an explicit policy;
* Debug, ReleaseSafe and ReleaseFast gates pass.

## Remaining Scope Boundaries

1. Regex rules use POSIX Extended Regular Expressions, not PCRE syntax.
2. POSIX `REG_STARTEND` and SQLite are system dependencies and currently make
   the validated build targets macOS and Linux; another target requires an
   explicit portability implementation.
3. Nulls are ignored by `unique`; combine `required` and `unique` when a column
   must contain one distinct non-null value per row.
4. Unicode case conversion and normalization remain outside the current ASCII
   cleaning scope.

These are explicit contract boundaries rather than incomplete Phase 6 items.

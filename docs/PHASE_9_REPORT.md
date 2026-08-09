# Phase 9 Exact Matching Report

Date: 2026-08-08
Toolchain: Zig 0.16.0

## Verdict

Phase 9 meets its documented exact-matching criteria with a bounded in-memory
reference index. It matches complete datasets across arbitrary batch boundaries
without retaining result sets in memory.

## Components

- Versioned ASCII normalization: trim, lowercase, punctuation removal, and
  whitespace collapse.
- Exact keys containing both Wyhash and the complete normalized value.
- Exact, prefix, and first-token-prefix blocking strategies.
- Hard-limited memory index with compact bucket chains and measured peak usage.
- Full-byte collision verification after hash and blocking lookup.
- Compact row identities preserving source, batch, row, and global offset.
- Progressive `MatchSink` with bounded sampling implementation and abort.
- Exact matcher that indexes the complete reference before streaming all
  candidate batches.

Nulls and empty normalized values are ignored by default. Multiple reference
rows with the same normalized key each produce their own result.

## Verification

Tests cover normalization, punctuation handling, invalid blocking prefixes,
forced hash collision, blocked candidate lookup, hard memory failure, matching
between different source IDs and batches, duplicate reference keys, and 300
results emitted as two progressive sink writes.

Required gates:

```text
zig fmt --check build.zig src tests benchmarks
zig build test
zig build -Doptimize=ReleaseSafe test
zig build -Doptimize=ReleaseFast
```

## Benchmark

`zig build bench-matching` performs two complete passes over
`customers-2000000.csv`, matching `Customer Id` exactly:

```text
reference rows       2,000,000
candidate rows       2,000,000
matches              2,000,000
index memory limit   768 MiB
peak index memory    543 MiB
elapsed              6.567 s
combined throughput  about 609,000 rows/s
```

The same workload fails explicitly with `MatchIndexMemoryLimit` at 512 MiB.
This is expected Phase 9 behavior rather than an unbounded allocation.

## Boundaries

- Normalization is ASCII-only; Unicode accent folding is not claimed.
- Phase 9 has no disk spill. Datasets exceeding the configured index limit must
  use a larger explicit limit until Phase 10 adds partitioning.
- Exact matching currently targets one string column per dataset.
- Fuzzy scoring, composite keys, and pipeline-builder matching orchestration
  remain future work.

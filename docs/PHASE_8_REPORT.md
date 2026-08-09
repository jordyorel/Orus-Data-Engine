# Phase 8 Pipeline Report

Date: 2026-08-08
Toolchain: Zig 0.16.0

## Verdict

Phase 8 meets its documented acceptance criteria for the currently implemented
engine stages. Pipeline construction, structural planning, reader chaining,
transforms, sinks, error handling, metrics, and final results are operational.

## Implemented Path

```text
Source
  -> IngestReader
  -> optional ProfileReader
  -> optional RuleEngine
  -> zero or more Transforms
  -> Sink
  -> PipelineResult
```

- Pipeline-owned readers are allocated at stable addresses.
- Builder inputs needed during execution are copied into run-lifetime memory.
- Duplicate transform identifiers and missing sinks are rejected at build time.
- Typed schema-dependent checks are compiled on the first inferred batch.
- Multiple transforms alternate the two batch arenas; scratch resets after
  each transform and batch.
- Sink write and finish failures populate `ErrorContext` and invoke `abort`.
- Rows read/written, batches, bytes read, invalid values, timestamps, profile,
  and validation summaries are returned without open resources.

## Tests

The mirrored integration test covers:

- CSV source with two batches;
- profiling and regex/unique validation reader chaining;
- two consecutive string transforms;
- transformed values observed by a sink;
- result metrics and resolved schema hashes;
- missing sink and duplicate transform plan errors;
- injected sink failure, abort, and diagnostic context.

All gates pass:

```text
zig fmt --check build.zig src tests benchmarks
zig build test
zig build -Doptimize=ReleaseSafe test
zig build -Doptimize=ReleaseFast
```

## Benchmark

`zig build bench-pipeline` executes typed ingestion, lowercase transformation,
and `NullSink` output over `customers-2000000.csv`:

```text
rows             2,000,000
batches          245
bytes read       349,416,788
elapsed          3.332 s
rows/second      about 600,000
```

This is a local reference run, not a cross-platform performance guarantee.

## Boundaries

- Current transforms preserve schema; a future schema-changing transform must
  provide an explicit schema planning contract.
- Matching and audit orchestration remain future stages and are not represented
  as completed Phase 8 behavior.
- `Sink.abort` is invoked on failure. Atomic output replacement remains the
  responsibility of each concrete file sink and is not yet guaranteed by
  `CsvSink`.
- Roadmap item `P-001` tracks atomic file output before production guarantees.
- Roadmap decision `V-001` tracks the final static-SQLite versus native-Zig
  uniqueness spill backend before autonomous stable distribution.

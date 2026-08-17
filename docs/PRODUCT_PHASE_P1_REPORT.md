# Product Phase P1 Report

Status: complete for local proof-of-concept testing.

## Delivered

- Independent React and TypeScript application in `web/orus-studio`.
- Independent FastAPI Control Plane in `apps/control-plane-api`.
- Persistent projects, CSV sources and profiling runs.
- Streaming upload with a configurable 10 GB default limit.
- Bounded CSV preview and asynchronous Zig profiling.
- Persistent success and failure states with atomic report publication.
- Source, quality and run views with responsive desktop/mobile layout.
- Pilot commands for setup, tests, builds and local development.

The flow is dataset-agnostic inside the current CSV contract. No customer field
or fixture-specific schema is encoded in Studio or the Control Plane.

## Verified vertical slice

The real `zig-out/bin/orusdata` executable profiled `fixtures/sample.csv` through
the HTTP Control Plane, not through a test double. The persisted run completed
successfully and returned:

```text
rows: 3
columns: 3
batches: 1
columns: id (string), name (string), score (i64)
score nulls: 1 (33.33%)
```

Control Plane tests cover upload, preview, profiling, report retrieval,
application restart persistence, invalid file types, unknown projects and engine
failure persistence. Studio unit checks and its production TypeScript build pass.

## Readiness decision

Orus Studio P1 is ready for local end-to-end evaluation. It is not production
ready. Production acceptance requires at minimum identity and access control,
tenant isolation, durable external storage, resumable large uploads, job
cancellation/retry policy, observability, deployment automation and load tests at
the target 10-50 GB envelope.

## Next product phase

P2 should expose cleaning and transformation as a first-class job after quality
profiling: select transformations, preview their impact, execute through the Zig
pipeline, preserve provenance, download the cleaned artifact, and optionally send
validated records into the ontology pipeline.


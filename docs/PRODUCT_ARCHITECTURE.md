# Orus Product Architecture

## Purpose

Orus Studio is the product entry point. Users create a workspace, upload their
own CSV files, inspect a sample, run the Zig data engine, and read the resulting
quality profile without operating the internal components directly.

## Repository boundaries

```text
web/orus-studio/                Product user interface
        |
        v
apps/control-plane-api/         Projects, uploads, jobs and artifacts
        |
        +------> src/           Zig data engine
        |
        +------> .orus-control/ Local metadata and artifacts

web/ontology-explorer/          Ontology visualization
        |
        v
apps/ontology-api/              Ontology HTTP API
        |
        v
python/                         Ontology domain and PostgreSQL storage
```

The repository is a monorepo, but each deployable component owns its package,
dependencies, tests and runtime configuration. Shared behavior crosses a
boundary through an explicit HTTP or file contract, not through frontend access
to internal storage.

## Product flow

1. Studio creates a project through the Control Plane API.
2. The Control Plane streams a CSV upload to managed storage, computes SHA-256
   and records metadata in SQLite.
3. Studio requests a bounded preview. The Control Plane never loads the complete
   dataset for this operation.
4. A profiling request creates a persistent asynchronous run.
5. A bounded worker invokes `orusdata profile` against the stored source.
6. The generated report is published atomically and its terminal state is
   persisted.
7. Studio polls the run and renders rows, columns, nulls, types, cardinality and
   detected patterns.

## Current storage model

- SQLite stores projects, sources and profiling run metadata.
- The filesystem stores source CSV files and immutable JSON reports.
- PostgreSQL stores ontology entities, relations and evidence.
- The Control Plane does not load entire uploads into memory.

This local model is suitable for a single-node proof of concept. Object storage,
a network database and a distributed job queue can replace these adapters
without changing the browser contract.

## Runtime guarantees

- Upload names are reduced to basenames and files are committed atomically.
- Upload size and CSV extension are validated.
- Profiling concurrency and execution timeout are bounded.
- Run state survives API restarts; interrupted work is marked failed.
- Reports are unavailable until the run succeeds.
- Browser access is restricted by configured CORS origins.

## Explicit non-goals for P1

P1 does not provide authentication, multi-tenant isolation, resumable uploads,
distributed execution, object storage, quotas, cancellation, cleaning workflow,
ontology ingestion from Studio, or production observability. These are product
phases after the local vertical slice, not hidden capabilities of this release.


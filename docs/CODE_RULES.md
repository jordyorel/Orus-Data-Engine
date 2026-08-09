# Orus Data Engine - Code Rules

Version: 1.0  
Toolchain: Zig 0.16.0  
Status: normative

This document defines the rules for all production code, tests, benchmarks,
and build files in Orus Data Engine. A change that violates a `MUST` rule must
not be merged without updating this document and recording the reason.

## 1. Sources of truth

1. The project targets Zig 0.16.0 only.
2. Language and standard-library behavior MUST be checked against the Zig
   0.16.0 documentation or the standard library shipped with the installed
   Zig 0.16.0 toolchain.
3. Code copied from Zig 0.15 or older MUST be adapted and compiled before use.
4. Compatibility shims for older Zig versions MUST NOT be added.
5. Project architecture and memory rules are defined by `docs/architecture`
   and `docs/02-memory`. This document governs implementation style.

Official references:

* <https://ziglang.org/documentation/0.16.0/>
* <https://ziglang.org/download/0.16.0/release-notes.html>

## 2. Design discipline

1. Implement the smallest complete behavior required by the current roadmap
   phase.
2. Do not add an abstraction until it removes real duplication, enforces an
   invariant, or implements an architecture contract.
3. Do not create `utils`, `helpers`, `common`, `manager`, or `misc` modules.
4. Do not add empty interfaces, fake implementations, speculative options, or
   unused generic parameters.
5. A roadmap placeholder MUST NOT be exported as implemented behavior.
6. Prefer a direct function over a type with one method and no state.
7. Prefer a concrete type inside a module. Use type erasure only at stable
   boundaries such as `Reader`, `Source`, `Sink`, and `Transform`.
8. Every dependency MUST justify functionality that the standard library or a
   small local implementation cannot reasonably provide.
9. Performance changes require a benchmark or a measurable invariant. Avoid
   optimization based only on intuition.

Approved validation dependencies:

* POSIX ERE (`regex.h`) provides compiled general regular expressions instead
  of an incomplete local matcher. Patterns and inputs have hard size limits.
* SQLite provides exact spill-backed uniqueness using full canonical values as
  B-tree keys. A handwritten disk index would duplicate complex transactional
  and collision-handling behavior without improving the engine contract.
* libpq provides the optional PostgreSQL wire client, authentication and
  single-row result mode. It is linked only with `-Dpostgres=true`, so the base
  CSV/JSONL binary keeps no PostgreSQL runtime dependency.

## 3. Module boundaries

1. Files MUST follow the monorepo layout in `docs/architecture`.
2. `core/` MUST NOT import connectors, ingestion, profiling, validation,
   cleaning, matching, sinks, or pipeline modules.
3. A connector may import `core/` and its own connector contracts only.
4. A tap observes a `*const Batch` and MUST NOT mutate it.
5. An operator receives an input batch and writes a distinct output batch.
6. Public declarations MUST be exported from `src/orus_data_engine.zig` only
   when they are usable and tested.
7. Circular imports and hidden global registries are forbidden.

## 4. Zig 0.16 API usage

1. Executable entry points that need I/O MUST accept `std.process.Init` and use
   `init.io` and `init.gpa`.
2. File, process, network, and clock operations MUST use the Zig 0.16 `std.Io`
   APIs. Do not reintroduce removed pre-0.16 APIs.
3. `std.ArrayList(T)` starts as `.empty`; allocating operations receive the
   correct allocator explicitly, and `deinit` receives the same allocator.
4. Build definitions MUST use Zig 0.16 module-based build APIs.
5. Feature detection is preferred to compiler-version branching when a
   portable check is genuinely required.
6. `@ptrCast` and `@alignCast` are restricted to reviewed low-level boundaries,
   primarily type-erased dispatch. Business logic MUST remain typed.

## 5. Naming and formatting

1. `zig fmt` is authoritative.
2. Use four-space indentation and aim for lines no longer than 100 characters.
3. Types use `TitleCase`, functions use `camelCase`, and values use
   `snake_case`.
4. Namespace and directory names use `snake_case`.
5. Names MUST be chosen for their fully-qualified namespace. Avoid repetitions
   such as `csv_source.CsvSource` when `csv_source.Source` is unambiguous.
   Names fixed by the architecture, including `CsvSource`, `ColumnData`,
   `SourceIdentity`, and `BatchMetadata`, are explicit compatibility
   exceptions.
6. Do not prefix names with underscores to imply privacy.
7. Acronyms follow normal casing: `CsvSource`, `JsonlSource`, `readU32Be`.
8. Comments explain invariants, ownership, non-obvious algorithms, or reasons.
   They MUST NOT narrate obvious statements.
9. Public APIs with non-obvious ownership or lifetime MUST have `///` docs.

## 6. Ownership and allocation

1. Every allocation has exactly one owner and one lifetime: run, batch, or
   scratch.
2. Library APIs that allocate MUST accept an allocator or an explicit arena.
3. The allocator used to release memory MUST be the allocator that allocated
   it.
4. Place `errdefer` immediately after acquiring a resource that must be cleaned
   up if initialization later fails.
5. Place `defer` next to successful acquisition when cleanup is unconditional.
6. Every returned slice or pointer MUST document whether it is borrowed or
   owned and when it becomes invalid.
7. A `Batch` owns nothing. It MUST NOT expose `deinit`.
8. Run-lifetime state MUST NOT retain pointers into batch or scratch memory.
9. Scratch memory MUST NOT escape the operation that owns its reset boundary.
10. No general-purpose allocation per cell is allowed in a hot loop.
11. `std.testing.allocator` MUST be used in allocation tests so leaks are
    reported.
12. Allocation failure MUST propagate as an error. OOM is not `unreachable`.

## 7. Streaming and bounded memory

1. Memory use MUST be independent of total input size.
2. Every growing structure MUST have one of:
   * a documented hard limit;
   * a bounded approximation;
   * a spill-to-disk strategy.
3. Readers emit at most the configured batch size.
4. Sources MUST NOT retain completed batches.
5. Record size, violation count, match count, and exact-cardinality state MUST
   have explicit limits or spill behavior.
6. String columns use contiguous bytes, offsets, and a null bitmap.
7. Typed columns use contiguous typed buffers and a null bitmap.
8. Parsing buffers are reused; cells are not represented as owned strings.
9. A transformation of variable-length data SHOULD reserve output capacity in
   bulk when its size can be calculated first.
10. Claims of bounded memory require a multi-batch test or benchmark.

## 8. Errors and invariants

1. Malformed external input returns a descriptive error or follows an explicit
   configured policy. It MUST NOT panic.
2. Use `try` to propagate errors that the current layer cannot enrich or
   handle.
3. Public boundaries SHOULD expose explicit error sets. Inferred error sets are
   acceptable for private implementation functions.
4. `anyerror` is restricted to type-erased interface function pointers where
   the concrete implementation determines the error set.
5. `unreachable` is allowed only for a proven internal invariant, never for
   user input, I/O failure, allocation failure, or an unimplemented branch.
6. `catch {}` and silently discarded errors are forbidden.
7. Assertions protect programmer invariants. They do not replace input
   validation.

## 9. Data correctness

1. Original batches are logically immutable.
2. Null and empty string are distinct values.
3. Integer parsing MUST detect overflow.
4. Decimal financial data MUST NOT be routed through `f64` when exact decimal
   semantics are required.
5. Type inference MUST preserve leading-zero identifiers as strings unless an
   explicit schema overrides it.
6. Default type inference MUST require 100% compatibility inside its sample.
   Lower confidence thresholds are opt-in because conversion must not silently
   discard valid mixed-format identifiers.
7. Schema decisions and invalid-value policies MUST be deterministic.
8. Source and batch metadata MUST remain stable and reproducible.

## 10. Testing rules

1. Every completed source module has focused unit tests.
2. Every public contract has at least one test through the contract, not only
   through the concrete implementation.
3. Every bug fix adds a regression test when reproducible.
4. Parser tests cover valid input, malformed input, boundaries, CRLF, quoting,
   escaped quotes, multiline records, empty fields, and oversized records.
5. Memory tests cover multiple arena resets and verify that run-lifetime state
   survives batch and scratch resets.
6. Hot paths have ReleaseFast benchmarks using representative data.
7. Tests MUST be deterministic and MUST NOT require network access.

Required checks before a change is considered complete:

```sh
zig fmt --check build.zig src tests benchmarks
zig build test
zig build -Doptimize=ReleaseSafe test
```

For changes to parsing, ingestion, profiling, cleaning, or matching:

```sh
zig build -Doptimize=ReleaseFast
```

The relevant benchmark or large fixture MUST also be run and its result noted.

## 11. Review gate

A change is complete only when all answers are yes:

1. Does it belong to the active roadmap phase?
2. Is the module boundary correct?
3. Are ownership and lifetime explicit?
4. Is memory bounded independently of dataset size?
5. Are errors handled without panic or silent loss?
6. Is the implementation smaller than the complexity it replaces?
7. Are public behavior and edge cases tested?
8. Do Debug, ReleaseSafe, formatting, and relevant benchmarks pass?

Exceptions require a short entry in the pull request or commit description
stating the violated rule, the reason, the measured impact, and the removal or
review condition.

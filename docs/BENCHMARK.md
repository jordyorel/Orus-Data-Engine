# Benchmarking

Build the CLI in release mode before measuring:

```sh
zig build -Doptimize=ReleaseFast
```

Run the complete CSV-to-typed-batch ingestion path:

```sh
./zig-out/bin/orusdata benchmark <file.csv> [batch_size]
```

Example:

```sh
./zig-out/bin/orusdata benchmark fixtures/customers-2000000.csv 8192
```

Progress is written to stderr after each GiB consumed. The final JSON is written
to stdout and contains:

- source bytes, rows, batches, and largest batch;
- wall-clock and process CPU time;
- rows per second and MiB per second;
- invalid values produced by typed conversion;
- peak resident set size reported by the operating system.

The measured mode is `typed_ingestion`: CSV parsing, schema inference, typed
conversion, and batch allocation are all included. Profiling, validation, and
cleaning are intentionally excluded and require separate benchmark modes.

## Measurement Discipline

1. Use a ReleaseFast binary.
2. Record the exact file checksum, byte size, batch size, hardware, and command.
3. Run at least three repetitions and retain every result, not only the fastest.
4. Distinguish cold-cache and warm-cache runs. Operating-system file caching can
   materially change throughput.
5. Keep the machine idle and ensure enough free disk space for outputs.
6. Treat peak RSS as a process-wide high-water mark, not instantaneous batch
   memory.

## Current Reference

On 2026-08-08, `customers-2000000.csv` with batch size 8,192 produced:

```text
rows                  2,000,000
bytes                 349,416,788
batches               245
invalid values        0
rows/second           about 758,000
MiB/second            about 126
peak RSS              about 25 MiB
```

This is a functional reference from one run, not a stable performance claim.

## JSON Lines Reference

Run the complete CSV-to-JSONL write and JSONL read benchmark:

```sh
zig build bench-jsonl
```

On 2026-08-08, the 2,000,000 customer rows produced a 644,085,001-byte
temporary JSONL file. One ReleaseFast run measured about 432,255 rows/s for
writing and 504,954 rows/s for reading. The benchmark deletes its temporary
output after the run.

## PostgreSQL Integration

With a PostgreSQL server listening on the local test endpoint at port 55432:

```sh
zig build -Dpostgres=true test-postgres
```

The integration query generates 20,000 rows and verifies 20 streamed batches,
typed primitive columns, global row offsets and byte metrics. This is a
correctness test, not a remote-database throughput benchmark.

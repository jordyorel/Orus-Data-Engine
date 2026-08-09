# Real Dataset Challenge Report

Date: 2026-08-08

## Scope

Two public, heterogeneous CSV datasets were exercised through inference,
profiling, validation, cleaning, CSV output, audit logging, and output re-read.

| Dataset | Size | Data rows | Columns |
|---|---:|---:|---:|
| Chicago crimes, one year | about 49 MiB | 230,742 | 17 |
| NYC active for-hire vehicles | about 26 MiB | 104,576 | 23 |

These files are functional tests of real-world variability. They are not yet a
multi-gigabyte throughput benchmark; `customers-2000000.csv` remains the larger
streaming fixture.

## Results

### Chicago crimes

- Inference completed for 230,742 rows in 29 batches with zero invalid values.
- Validation completed with zero violations for the current domain rules.
- Profiling found nullable location fields, bounded ward and beat values, and
  decimal latitude/longitude values in plausible ranges.
- The source contains four headers with leading spaces. They are preserved
  exactly, which demonstrates the need for a future header normalization step.
- Lowercasing ` PRIMARY DESCRIPTION` produced 230,742 rows in 29 batches.
- The output was re-read with the same row count and zero invalid values.
- The audit log contains one provenance entry per batch (29 entries).

### NYC active for-hire vehicles

- The first run inferred `Vehicle License Number` as `i64` at the old 98%
  threshold and converted 1,056 legitimate alphanumeric identifiers to null.
- The default inference threshold is now 100%. The column remains `string`, the
  full 104,576-row run reports zero invalid values, and a regression test covers
  a 99% numeric / 1% alphanumeric identifier column.
- Strict validation reports 209,161 violations: 104,576 empty `Order Date`
  values, 104,576 expiration dates that do not match ISO format, two missing
  VINs, and seven non-17-character VINs.
- The expiration dates use `MM/DD/YYYY`; they are valid source values but fail
  the deliberately strict `date_iso` rule.
- The `Website` column contains email addresses, exposing a source-schema naming
  inconsistency.
- Uppercasing `Name` produced 104,576 rows in 13 batches.
- The output was re-read with the same row count and zero invalid values.
- The audit log contains one provenance entry per batch (13 entries).

## Verification Gates

- `zig fmt --check src tests benchmarks build.zig`: passed.
- `zig build test`: passed.
- `zig build -Doptimize=ReleaseFast`: passed.
- CSV round-trip row counts: passed for both datasets.
- Inference after round-trip: zero invalid values for both datasets.

## Benchmark Mode

The CLI now exposes `benchmark <file.csv> [batch_size]` for the complete typed
ingestion path. A ReleaseFast reference run over `customers-2000000.csv`
processed 2,000,000 rows and 349,416,788 bytes at about 758,000 rows/s and
126 MiB/s, with about 25 MiB peak RSS and zero invalid values. This single run is
a baseline, not a performance guarantee.

### NYC 311 download challenge

The downloaded `311_Service_Requests_from_2020_to_Present_20260808.csv` is not a
complete CSV export. After 835,528 data rows, the NYC server appended a JSON
`500 Internal error` response. The strict parser correctly stopped with
`UnexpectedQuote`; the original file was preserved.

The valid 737,350,184-byte prefix was benchmarked separately with batch size
8,192. A ReleaseFast run processed 835,528 rows in 4.90 seconds at about 170,000
rows/s and 143 MiB/s, with about 112 MiB peak RSS and zero invalid values.

This dataset also exposed a decimal conversion defect: six valid longitude
values were exactly `-74`, while sampled values contained fractional digits.
Decimal conversion now accepts integral representations without making integer
and decimal inference ambiguous. A regression assertion covers the case.

## Limits Exposed

1. Inference is based on the configured sample (4,096 rows by default). A new
   format appearing only after the sample is counted as invalid during
   conversion; strict schemas remain the only full-file type guarantee.
2. Date parsing and normalization currently recognize ISO dates, not US-style
   `MM/DD/YYYY` dates.
3. Cleaning transforms values but cannot yet normalize or rename headers.
4. Validation supports the current bounded pattern set, not general regular
   expressions or spill-backed global uniqueness.
5. These files validate correctness and streaming behavior but are too small to
   establish multi-gigabyte throughput, memory ceilings, or sustained I/O rates.

## Conclusion

The engine handles both datasets end to end without loading the full file into
memory and preserves row counts through cleaning. The challenge found and fixed
a real inference data-loss defect. Phase 7 has a usable value-transformation
path, but broader date normalization, header transforms, and a measured
multi-gigabyte benchmark are the next required capabilities.

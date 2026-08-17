"""Reproducible O11 benchmarks over the real customer vertical."""

import resource
import tracemalloc
from collections.abc import Callable
from datetime import datetime
from pathlib import Path
from time import monotonic, perf_counter_ns
from uuid import UUID

from pydantic import Field

from orus_ontology._schema import ImmutableModel
from orus_ontology.interchange.subprocess_bridge import RunStatus, SubprocessBridge
from orus_ontology.mapping.compiler import MappingCompiler
from orus_ontology.materialization.batch import BatchMaterializer
from orus_ontology.query.filters import ObjectQuery, PropertyFilter
from orus_ontology.query.service import QueryService
from orus_ontology.query.traversal import TraversalHop, TraversalQuery
from orus_ontology.storage.contracts import RelationDirection
from orus_ontology.storage.postgres import PostgresStore
from orus_ontology.vertical.customers import (
    CUSTOMER_TYPE_ID,
    customer_mapping,
    customer_ontology,
    customer_source_contract,
)
from orus_ontology.vertical.importer import CustomerImporter, canonical_customer_records


class MaterializationBenchmark(ImmutableModel):
    rows: int = Field(ge=0)
    batches: int = Field(ge=0)
    objects: int = Field(ge=0)
    relations: int = Field(ge=0)
    elapsed_seconds: float = Field(ge=0)
    rows_per_second: float = Field(ge=0)
    python_peak_bytes: int = Field(ge=0)
    process_peak_rss_bytes: int = Field(ge=0)


class LatencyBenchmark(ImmutableModel):
    samples: int = Field(ge=1)
    minimum_ms: float = Field(ge=0)
    median_ms: float = Field(ge=0)
    p95_ms: float = Field(ge=0)
    maximum_ms: float = Field(ge=0)


class PostgresBenchmark(ImmutableModel):
    rows: int = Field(ge=0)
    rows_per_second: float = Field(ge=0)
    objects: int = Field(ge=0)
    relations: int = Field(ge=0)
    assertions: int = Field(ge=0)
    identity_lookup: LatencyBenchmark
    one_hop_neighbors: LatencyBenchmark
    bounded_traversal: LatencyBenchmark


def benchmark_materialization(
    engine_binary: str | Path,
    csv_path: str | Path,
    *,
    rows: int,
    batch_size: int,
    run_id: UUID,
    observed_at: datetime,
) -> MaterializationBenchmark:
    plan = MappingCompiler.compile(
        customer_mapping(), customer_ontology(), customer_source_contract()
    )
    run = SubprocessBridge(engine_binary).run(
        (
            "export-jsonl",
            str(Path(csv_path).resolve()),
            str(Path(csv_path).resolve()),
            str(run_id),
            observed_at.isoformat(),
            str(batch_size),
            "0",
            str(rows),
        )
    )
    materializer = BatchMaterializer(plan, batch_size=batch_size, recorded_at=observed_at)
    tracemalloc.start()
    started = monotonic()
    row_count = batch_count = object_count = relation_count = 0
    for batch in materializer.materialize(canonical_customer_records(run)):
        row_count += batch.input_count
        batch_count += 1
        object_count += len(batch.objects)
        relation_count += len(batch.relations)
    elapsed = monotonic() - started
    _, peak = tracemalloc.get_traced_memory()
    tracemalloc.stop()
    if run.status is not RunStatus.COMPLETE:
        raise RuntimeError("materialization benchmark did not complete")
    return MaterializationBenchmark(
        rows=row_count,
        batches=batch_count,
        objects=object_count,
        relations=relation_count,
        elapsed_seconds=elapsed,
        rows_per_second=row_count / elapsed if elapsed else 0,
        python_peak_bytes=peak,
        process_peak_rss_bytes=_peak_rss_bytes(),
    )


def benchmark_postgres(
    store: PostgresStore,
    engine_binary: str | Path,
    csv_path: str | Path,
    *,
    rows: int,
    batch_size: int,
    run_id: UUID,
    observed_at: datetime,
    customer_id: str,
    samples: int = 50,
) -> PostgresBenchmark:
    imported = CustomerImporter(store, engine_binary).run(
        csv_path,
        run_id=run_id,
        observed_at=observed_at,
        batch_size=batch_size,
        max_rows=rows,
    )
    service = QueryService(store)
    query = ObjectQuery(
        object_type_id=CUSTOMER_TYPE_ID,
        filters=(PropertyFilter(predicate="customer_id", value=customer_id),),
        limit=1,
    )
    found = service.find_objects(query)
    if not found:
        raise RuntimeError("benchmark customer was not materialized")
    customer = found[0]
    identity_latency = _measure(lambda: service.find_objects(query), samples)
    neighbor_latency = _measure(
        lambda: service.neighbors(
            customer.object_id,
            direction=RelationDirection.OUTGOING,
            limit=10,
        ),
        samples,
    )
    traversal_latency = _measure(
        lambda: service.traverse(
            TraversalQuery(
                start_object_id=customer.object_id,
                hops=(TraversalHop(direction=RelationDirection.OUTGOING),),
                limit=10,
            )
        ),
        samples,
    )
    statistics = imported.store_statistics
    return PostgresBenchmark(
        rows=imported.rows_processed,
        rows_per_second=imported.rows_per_second,
        objects=statistics["objects"],
        relations=statistics["relations"],
        assertions=statistics["assertions"],
        identity_lookup=identity_latency,
        one_hop_neighbors=neighbor_latency,
        bounded_traversal=traversal_latency,
    )


def _measure(operation: Callable[[], object], samples: int) -> LatencyBenchmark:
    if samples < 1:
        raise ValueError("invalid latency benchmark")
    values: list[float] = []
    for _ in range(samples):
        started = perf_counter_ns()
        operation()
        values.append((perf_counter_ns() - started) / 1_000_000)
    values.sort()
    return LatencyBenchmark(
        samples=samples,
        minimum_ms=values[0],
        median_ms=values[len(values) // 2],
        p95_ms=values[min(len(values) - 1, int(len(values) * 0.95))],
        maximum_ms=values[-1],
    )


def _peak_rss_bytes() -> int:
    peak = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss
    return int(peak if __import__("sys").platform == "darwin" else peak * 1024)

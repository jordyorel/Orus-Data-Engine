"""Streaming customer vertical from the Zig CLI into PostgreSQL."""

import json
import os
from collections.abc import Iterable, Iterator, Mapping
from datetime import datetime
from pathlib import Path
from time import monotonic
from typing import cast
from uuid import UUID

from pydantic import Field

from orus_ontology._schema import ImmutableModel
from orus_ontology.errors import BridgeError
from orus_ontology.interchange.subprocess_bridge import RunStatus, SubprocessBridge
from orus_ontology.mapping.compiler import MappingCompiler
from orus_ontology.materialization.batch import BatchMaterializer, CanonicalRecord
from orus_ontology.storage.postgres import PostgresStore
from orus_ontology.vertical.customers import (
    RAW_TO_CANONICAL,
    customer_mapping,
    customer_ontology,
    customer_source_contract,
)


class ImportResult(ImmutableModel):
    run_id: UUID
    rows_processed: int = Field(ge=0)
    batches_committed: int = Field(ge=0)
    objects_inserted: int = Field(ge=0)
    relations_inserted: int = Field(ge=0)
    assertions_inserted: int = Field(ge=0)
    elapsed_seconds: float = Field(ge=0)
    rows_per_second: float = Field(ge=0)
    next_offset: int = Field(ge=0)
    complete: bool
    store_statistics: dict[str, int]


class CustomerImporter:
    def __init__(self, store: PostgresStore, engine_binary: str | Path) -> None:
        self._store = store
        self._bridge = SubprocessBridge(engine_binary)
        self._ontology = customer_ontology()
        self._plan = MappingCompiler.compile(
            customer_mapping(), self._ontology, customer_source_contract()
        )

    def run(
        self,
        csv_path: str | Path,
        *,
        run_id: UUID,
        observed_at: datetime,
        batch_size: int = 1_024,
        start_offset: int = 0,
        max_rows: int | None = None,
        checkpoint_path: str | Path | None = None,
    ) -> ImportResult:
        if batch_size < 1 or start_offset < 0 or (max_rows is not None and max_rows < 1):
            raise ValueError("invalid customer import bounds")
        source = Path(csv_path).resolve()
        checkpoint = Path(checkpoint_path) if checkpoint_path is not None else None
        if checkpoint is not None and checkpoint.exists():
            state = json.loads(checkpoint.read_text())
            _validate_checkpoint(state, source, run_id)
            start_offset = int(state["next_offset"])
        self._store.put_schema(self._ontology)
        arguments = [
            "export-jsonl",
            str(source),
            str(source),
            str(run_id),
            observed_at.isoformat(),
            str(batch_size),
            str(start_offset),
        ]
        if max_rows is not None:
            arguments.append(str(max_rows))
        bridge_run = self._bridge.run(tuple(arguments))
        materializer = BatchMaterializer(self._plan, batch_size=batch_size, recorded_at=observed_at)
        started = monotonic()
        rows = batches = objects = relations = assertions = 0
        for batch in materializer.materialize(canonical_customer_records(bridge_run)):
            written = self._store.put_materialized_batch(batch)
            rows += batch.input_count
            batches += 1
            objects += written.objects
            relations += written.relations
            assertions += written.assertions
            if checkpoint is not None:
                _write_checkpoint(checkpoint, source, run_id, start_offset + rows)
        if bridge_run.status is not RunStatus.COMPLETE:
            raise BridgeError("customer import ended without a complete Zig run")
        elapsed = monotonic() - started
        complete = max_rows is None
        return ImportResult(
            run_id=run_id,
            rows_processed=rows,
            batches_committed=batches,
            objects_inserted=objects,
            relations_inserted=relations,
            assertions_inserted=assertions,
            elapsed_seconds=elapsed,
            rows_per_second=rows / elapsed if elapsed else 0,
            next_offset=start_offset + rows,
            complete=complete,
            store_statistics=self._store.statistics(),
        )


def canonical_customer_records(
    records: Iterable[CanonicalRecord],
) -> Iterator[CanonicalRecord]:
    for record in records:
        unknown = set(record.values) - set(RAW_TO_CANONICAL)
        missing = set(RAW_TO_CANONICAL) - set(record.values)
        if unknown or missing:
            raise BridgeError(
                "customer CSV columns do not match the vertical contract",
                context={"unknown": tuple(sorted(unknown)), "missing": tuple(sorted(missing))},
            )
        yield CanonicalRecord(
            values={RAW_TO_CANONICAL[key]: value for key, value in record.values.items()},
            source=record.source,
        )


def _validate_checkpoint(state: object, source: Path, run_id: UUID) -> None:
    if not isinstance(state, dict):
        raise BridgeError("customer checkpoint is not a JSON object")
    checkpoint = cast(Mapping[str, object], state)
    expected = {"source": str(source), "run_id": str(run_id)}
    if any(checkpoint.get(key) != value for key, value in expected.items()):
        raise BridgeError("customer checkpoint does not match source or run")
    offset = checkpoint.get("next_offset")
    if not isinstance(offset, int) or offset < 0:
        raise BridgeError("customer checkpoint has an invalid offset")


def _write_checkpoint(path: Path, source: Path, run_id: UUID, next_offset: int) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(
        json.dumps(
            {"source": str(source), "run_id": str(run_id), "next_offset": next_offset},
            sort_keys=True,
        )
        + "\n"
    )
    os.replace(temporary, path)

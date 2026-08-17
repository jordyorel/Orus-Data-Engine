"""Versioned interchange envelope between Zig ingestion and Python ontology."""

from datetime import datetime
from typing import Literal
from uuid import UUID

from pydantic import Field

from orus_ontology._schema import ImmutableModel
from orus_ontology.assertions.provenance import SourceReference
from orus_ontology.materialization.batch import CanonicalRecord

CONTRACT_VERSION = 1


class InterchangeSource(ImmutableModel):
    source_id: str = Field(min_length=1)
    source_version: str | None = None
    batch_id: int = Field(ge=0)
    row_id: int = Field(ge=0)
    global_offset: int = Field(ge=0)
    observed_at: datetime
    checksum: str | None = None


class InterchangeEnvelope(ImmutableModel):
    contract_version: Literal[1]
    record: dict[str, object]
    source: InterchangeSource
    run_id: UUID

    def canonical_record(self) -> CanonicalRecord:
        return CanonicalRecord(
            values=self.record,
            source=SourceReference(
                **self.source.model_dump(),
                run_id=self.run_id,
            ),
        )

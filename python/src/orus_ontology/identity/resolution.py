"""Auditable decisions accepting or rejecting entity match candidates."""

from datetime import datetime
from decimal import Decimal
from enum import StrEnum
from uuid import UUID, uuid4, uuid5

from pydantic import Field, field_validator, model_validator

from orus_ontology._schema import ImmutableModel
from orus_ontology.assertions.temporal import normalize_utc
from orus_ontology.identity.candidate import MatchCandidate


class ResolutionOutcome(StrEnum):
    MERGE = "merge"
    REJECT = "reject"


class ResolutionDecision(ImmutableModel):
    """Immutable decision preserving every source object identity."""

    decision_id: UUID = Field(default_factory=uuid4)
    ontology_id: UUID
    ontology_version: int = Field(ge=1)
    candidate_id: UUID
    source_object_ids: tuple[UUID, UUID]
    outcome: ResolutionOutcome
    canonical_object_id: UUID | None = None
    confidence: Decimal
    method: str
    resolver_version: int = Field(ge=1)
    decided_at: datetime
    actor_id: str | None = None

    @classmethod
    def from_candidate(
        cls,
        candidate: MatchCandidate,
        *,
        ontology_version: int,
        outcome: ResolutionOutcome,
        resolver_version: int,
        decided_at: datetime,
        actor_id: str | None = None,
    ) -> "ResolutionDecision":
        canonical_id = None
        if outcome is ResolutionOutcome.MERGE:
            canonical_id = uuid5(
                candidate.ontology_id,
                f"canonical:{candidate.object_ids[0]}:{candidate.object_ids[1]}",
            )
        return cls(
            ontology_id=candidate.ontology_id,
            ontology_version=ontology_version,
            candidate_id=candidate.candidate_id,
            source_object_ids=candidate.object_ids,
            outcome=outcome,
            canonical_object_id=canonical_id,
            confidence=candidate.confidence,
            method=candidate.method,
            resolver_version=resolver_version,
            decided_at=decided_at,
            actor_id=actor_id,
        )

    @field_validator("decided_at")
    @classmethod
    def normalize_decided_at(cls, value: datetime) -> datetime:
        return normalize_utc(value)

    @field_validator("actor_id")
    @classmethod
    def reject_blank_actor(cls, value: str | None) -> str | None:
        if value is not None and not value.strip():
            raise ValueError("actor_id must not be blank")
        return value

    @field_validator("confidence", mode="before")
    @classmethod
    def reject_inexact_confidence(cls, value: object) -> object:
        if isinstance(value, float | bool):
            raise ValueError("resolution confidence must use an exact decimal value")
        return value

    @model_validator(mode="after")
    def validate_decision(self) -> "ResolutionDecision":
        if self.confidence < 0 or self.confidence > 1:
            raise ValueError("resolution confidence must be between 0 and 1")
        if self.source_object_ids[0] == self.source_object_ids[1]:
            raise ValueError("resolution must preserve two distinct source objects")
        if self.outcome is ResolutionOutcome.MERGE and self.canonical_object_id is None:
            raise ValueError("merge decision requires canonical_object_id")
        if self.outcome is ResolutionOutcome.REJECT and self.canonical_object_id is not None:
            raise ValueError("rejected decision must not create a canonical object")
        return self

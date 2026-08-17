"""Deterministic entity match candidates."""

from datetime import datetime
from decimal import Decimal
from uuid import UUID, uuid5

from pydantic import Field, field_validator, model_validator

from orus_ontology._schema import ImmutableModel, validate_technical_name
from orus_ontology.assertions.temporal import normalize_utc


class MatchCandidate(ImmutableModel):
    """Scored hypothesis that two source objects represent the same entity."""

    candidate_id: UUID
    ontology_id: UUID
    object_ids: tuple[UUID, UUID]
    confidence: Decimal
    method: str
    matcher_version: int = Field(ge=1)
    evidence_assertion_ids: tuple[UUID, ...] = ()
    created_at: datetime

    @classmethod
    def create(
        cls,
        *,
        ontology_id: UUID,
        left_object_id: UUID,
        right_object_id: UUID,
        confidence: Decimal,
        method: str,
        matcher_version: int,
        evidence_assertion_ids: tuple[UUID, ...] = (),
        created_at: datetime,
    ) -> "MatchCandidate":
        object_ids = _canonical_pair(left_object_id, right_object_id)
        candidate_id = _candidate_id(ontology_id, object_ids, method, matcher_version)
        return cls(
            candidate_id=candidate_id,
            ontology_id=ontology_id,
            object_ids=object_ids,
            confidence=confidence,
            method=method,
            matcher_version=matcher_version,
            evidence_assertion_ids=evidence_assertion_ids,
            created_at=created_at,
        )

    @field_validator("confidence", mode="before")
    @classmethod
    def reject_inexact_confidence(cls, value: object) -> object:
        if isinstance(value, float | bool):
            raise ValueError("candidate confidence must use an exact decimal value")
        return value

    @field_validator("method")
    @classmethod
    def validate_method(cls, value: str) -> str:
        return validate_technical_name(value, field_name="match method")

    @field_validator("evidence_assertion_ids")
    @classmethod
    def unique_evidence(cls, values: tuple[UUID, ...]) -> tuple[UUID, ...]:
        if len(values) != len(set(values)):
            raise ValueError("evidence assertion IDs must be unique")
        return values

    @field_validator("created_at")
    @classmethod
    def normalize_created_at(cls, value: datetime) -> datetime:
        return normalize_utc(value)

    @model_validator(mode="after")
    def validate_candidate(self) -> "MatchCandidate":
        if self.object_ids[0] == self.object_ids[1]:
            raise ValueError("match candidate requires two distinct objects")
        if self.object_ids != _canonical_pair(*self.object_ids):
            raise ValueError("match candidate object IDs must use canonical order")
        if self.confidence < 0 or self.confidence > 1:
            raise ValueError("candidate confidence must be between 0 and 1")
        expected = _candidate_id(
            self.ontology_id,
            self.object_ids,
            self.method,
            self.matcher_version,
        )
        if self.candidate_id != expected:
            raise ValueError("candidate_id does not match candidate content")
        return self


def _canonical_pair(left: UUID, right: UUID) -> tuple[UUID, UUID]:
    return (left, right) if left.int < right.int else (right, left)


def _candidate_id(
    ontology_id: UUID,
    object_ids: tuple[UUID, UUID],
    method: str,
    matcher_version: int,
) -> UUID:
    return uuid5(
        ontology_id,
        f"candidate:{object_ids[0]}:{object_ids[1]}:{method}:{matcher_version}",
    )

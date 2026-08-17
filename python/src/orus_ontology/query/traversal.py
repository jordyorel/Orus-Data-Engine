"""Bounded graph traversal request and result models."""

from enum import StrEnum
from uuid import UUID

from pydantic import Field, model_validator

from orus_ontology._schema import ImmutableModel
from orus_ontology.materialization.batch import ObjectInstance, RelationInstance
from orus_ontology.query.filters import PropertyFilter
from orus_ontology.storage.contracts import RelationDirection


class CyclePolicy(StrEnum):
    SKIP = "skip"
    INCLUDE_ONCE = "include_once"


class TraversalHop(ImmutableModel):
    direction: RelationDirection = RelationDirection.OUTGOING
    relation_type_id: UUID | None = None
    target_object_type_id: UUID | None = None
    target_filters: tuple[PropertyFilter, ...] = ()


class TraversalQuery(ImmutableModel):
    start_object_id: UUID
    hops: tuple[TraversalHop, ...] = Field(min_length=1, max_length=16)
    limit: int = Field(default=100, ge=1, le=10_000)
    cycle_policy: CyclePolicy = CyclePolicy.SKIP


class TraversalResult(ImmutableModel):
    objects: tuple[ObjectInstance, ...]
    relations: tuple[RelationInstance, ...]
    depth_reached: int = Field(ge=0)
    truncated: bool

    @model_validator(mode="after")
    def enforce_limit_consistency(self) -> "TraversalResult":
        if self.depth_reached == 0 and (self.objects or self.relations):
            raise ValueError("zero-depth traversal cannot contain results")
        return self

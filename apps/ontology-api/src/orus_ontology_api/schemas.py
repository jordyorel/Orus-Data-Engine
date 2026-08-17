"""Stable HTTP request and response schemas."""

from uuid import UUID

from orus_ontology import (
    Assertion,
    CyclePolicy,
    ObjectInstance,
    PropertyFilter,
    RelationDirection,
    RelationInstance,
    SourceReference,
    TraversalHop,
)
from pydantic import BaseModel, ConfigDict, Field


class ApiModel(BaseModel):
    model_config = ConfigDict(extra="forbid")


class StatusResponse(ApiModel):
    status: str


class StatisticsResponse(ApiModel):
    schemas: int = Field(ge=0)
    objects: int = Field(ge=0)
    relations: int = Field(ge=0)
    assertions: int = Field(ge=0)
    resolutions: int = Field(ge=0)


class ObjectSearchRequest(ApiModel):
    object_type_id: UUID | None = None
    filters: tuple[PropertyFilter, ...] = Field(default=(), max_length=8)
    limit: int = Field(default=50, ge=1, le=200)
    offset: int = Field(default=0, ge=0, le=1_000_000)


class ObjectListResponse(ApiModel):
    objects: tuple[ObjectInstance, ...]
    limit: int
    offset: int


class ObjectContextResponse(ApiModel):
    object: ObjectInstance
    assertions: tuple[Assertion, ...]
    provenance: tuple[SourceReference, ...]


class NeighborResponse(ApiModel):
    relation: RelationInstance
    object: ObjectInstance


class NeighborListResponse(ApiModel):
    object_id: UUID
    direction: RelationDirection
    neighbors: tuple[NeighborResponse, ...]
    limit: int


class TraversalRequest(ApiModel):
    start_object_id: UUID
    hops: tuple[TraversalHop, ...] = Field(min_length=1, max_length=4)
    limit: int = Field(default=100, ge=1, le=500)
    cycle_policy: CyclePolicy = CyclePolicy.SKIP


class GraphResponse(ApiModel):
    root: ObjectInstance
    objects: tuple[ObjectInstance, ...]
    relations: tuple[RelationInstance, ...]
    depth_reached: int = Field(ge=0, le=4)
    truncated: bool

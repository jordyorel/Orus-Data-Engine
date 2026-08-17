"""Bounded ontology query routes."""

from typing import Annotated, Protocol, cast
from uuid import UUID

from fastapi import APIRouter, Depends, HTTPException, Query
from orus_ontology import ObjectQuery, QueryService, RelationDirection, TraversalQuery
from orus_ontology.storage.contracts import OntologyStore

from orus_ontology_api.dependencies import get_store
from orus_ontology_api.schemas import (
    GraphResponse,
    NeighborListResponse,
    NeighborResponse,
    ObjectContextResponse,
    ObjectListResponse,
    ObjectSearchRequest,
    StatisticsResponse,
    StatusResponse,
    TraversalRequest,
)

router = APIRouter()
Store = Annotated[OntologyStore, Depends(get_store)]


class StatisticsStore(Protocol):
    def statistics(self) -> dict[str, int]: ...


@router.get("/health/live", response_model=StatusResponse, tags=["health"])
def live() -> StatusResponse:
    return StatusResponse(status="ok")


@router.get("/health/ready", response_model=StatusResponse, tags=["health"])
def ready(store: Store) -> StatusResponse:
    _statistics(store)
    return StatusResponse(status="ready")


@router.get("/v1/statistics", response_model=StatisticsResponse, tags=["ontology"])
def statistics(store: Store) -> StatisticsResponse:
    return StatisticsResponse.model_validate(_statistics(store))


@router.post("/v1/objects/search", response_model=ObjectListResponse, tags=["objects"])
def search_objects(request: ObjectSearchRequest, store: Store) -> ObjectListResponse:
    objects = QueryService(store).find_objects(
        ObjectQuery(
            object_type_id=request.object_type_id,
            filters=request.filters,
            limit=request.limit,
            offset=request.offset,
        )
    )
    return ObjectListResponse(
        objects=objects,
        limit=request.limit,
        offset=request.offset,
    )


@router.get("/v1/objects/{object_id}", response_model=ObjectContextResponse, tags=["objects"])
def object_context(
    object_id: UUID,
    store: Store,
    assertion_limit: Annotated[int, Query(ge=1, le=500)] = 100,
    provenance_limit: Annotated[int, Query(ge=1, le=500)] = 100,
) -> ObjectContextResponse:
    service = QueryService(store)
    instance = service.get_object(object_id)
    if instance is None:
        raise HTTPException(status_code=404, detail="ontology object not found")
    return ObjectContextResponse(
        object=instance,
        assertions=service.assertions(instance.object_id, limit=assertion_limit),
        provenance=service.provenance(instance.object_id, limit=provenance_limit),
    )


@router.get(
    "/v1/objects/{object_id}/neighbors",
    response_model=NeighborListResponse,
    tags=["graph"],
)
def neighbors(
    object_id: UUID,
    store: Store,
    direction: RelationDirection = RelationDirection.BOTH,
    relation_type_id: UUID | None = None,
    limit: Annotated[int, Query(ge=1, le=200)] = 50,
) -> NeighborListResponse:
    service = QueryService(store)
    if service.get_object(object_id) is None:
        raise HTTPException(status_code=404, detail="ontology object not found")
    result = service.neighbors(
        object_id,
        direction=direction,
        relation_type_id=relation_type_id,
        limit=limit,
    )
    return NeighborListResponse(
        object_id=object_id,
        direction=direction,
        neighbors=tuple(
            NeighborResponse(relation=relation, object=instance)
            for relation, instance in result
        ),
        limit=limit,
    )


@router.post("/v1/traversals", response_model=GraphResponse, tags=["graph"])
def traverse(request: TraversalRequest, store: Store) -> GraphResponse:
    service = QueryService(store)
    root = service.get_object(request.start_object_id)
    if root is None:
        raise HTTPException(status_code=404, detail="ontology object not found")
    result = service.traverse(
        TraversalQuery(
            start_object_id=request.start_object_id,
            hops=request.hops,
            limit=request.limit,
            cycle_policy=request.cycle_policy,
        )
    )
    return GraphResponse(
        root=root,
        objects=result.objects,
        relations=result.relations,
        depth_reached=result.depth_reached,
        truncated=result.truncated,
    )


def _statistics(store: OntologyStore) -> dict[str, int]:
    method = getattr(store, "statistics", None)
    if not callable(method):
        raise RuntimeError("configured ontology store does not expose statistics")
    return cast(StatisticsStore, store).statistics()

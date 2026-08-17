"""Storage contracts shared by reference and persistent backends."""

from collections.abc import Sequence
from enum import StrEnum
from typing import Protocol, runtime_checkable
from uuid import UUID

from orus_ontology.assertions.assertion import Assertion
from orus_ontology.identity.resolution import ResolutionDecision
from orus_ontology.materialization.batch import ObjectInstance, RelationInstance
from orus_ontology.metamodel.ontology import OntologyDefinition


class RelationDirection(StrEnum):
    OUTGOING = "outgoing"
    INCOMING = "incoming"
    BOTH = "both"


@runtime_checkable
class SchemaStore(Protocol):
    def put_schema(self, schema: OntologyDefinition) -> None: ...

    def get_schema(self, ontology_id: UUID, version: int) -> OntologyDefinition | None: ...

    def latest_schema(self, ontology_id: UUID) -> OntologyDefinition | None: ...


@runtime_checkable
class ObjectStore(Protocol):
    def put_object(self, instance: ObjectInstance) -> None: ...

    def get_object(self, object_id: UUID) -> ObjectInstance | None: ...

    def put_assertions(self, assertions: Sequence[Assertion]) -> None: ...

    def get_assertion(self, assertion_id: UUID) -> Assertion | None: ...

    def assertions_for(self, subject_id: UUID) -> tuple[Assertion, ...]: ...

    def scan_objects(
        self, object_type_id: UUID | None, *, limit: int, offset: int
    ) -> tuple[ObjectInstance, ...]: ...

    def lookup_objects(
        self,
        predicate: str,
        value: object,
        object_type_id: UUID | None,
        *,
        limit: int,
        offset: int,
    ) -> tuple[ObjectInstance, ...]: ...


@runtime_checkable
class RelationStore(Protocol):
    def put_relation(self, instance: RelationInstance) -> None: ...

    def get_relation(self, relation_id: UUID) -> RelationInstance | None: ...

    def neighbors(
        self,
        object_id: UUID,
        relation_type_id: UUID | None,
        direction: RelationDirection,
        *,
        limit: int,
        offset: int,
    ) -> tuple[RelationInstance, ...]: ...


@runtime_checkable
class ResolutionStore(Protocol):
    def put_resolution(self, decision: ResolutionDecision) -> None: ...

    def canonical_id(self, object_id: UUID) -> UUID: ...


class OntologyStore(SchemaStore, ObjectStore, RelationStore, ResolutionStore, Protocol):
    """Complete contract required by the query service."""

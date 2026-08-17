"""Bounded reference storage for tests and small proofs of concept."""

from collections import defaultdict
from collections.abc import Sequence
from uuid import UUID

from orus_ontology.assertions.assertion import Assertion, ValueTarget
from orus_ontology.errors import StorageError
from orus_ontology.identity.resolution import ResolutionDecision, ResolutionOutcome
from orus_ontology.materialization.batch import ObjectInstance, RelationInstance
from orus_ontology.metamodel.ontology import OntologyDefinition, OntologyStatus
from orus_ontology.storage.contracts import RelationDirection


class MemoryStore:
    """In-process backend with deterministic ordering and explicit query bounds."""

    def __init__(self) -> None:
        self._schemas: dict[tuple[UUID, int], OntologyDefinition] = {}
        self._objects: dict[UUID, ObjectInstance] = {}
        self._relations: dict[UUID, RelationInstance] = {}
        self._assertions: dict[UUID, Assertion] = {}
        self._subjects: dict[UUID, list[UUID]] = defaultdict(list)
        self._outgoing: dict[UUID, list[UUID]] = defaultdict(list)
        self._incoming: dict[UUID, list[UUID]] = defaultdict(list)
        self._canonical: dict[UUID, UUID] = {}

    def put_schema(self, schema: OntologyDefinition) -> None:
        if schema.status is not OntologyStatus.PUBLISHED:
            raise StorageError("only published ontology schemas can be stored")
        key = (schema.ontology_id, schema.version)
        existing = self._schemas.get(key)
        if existing is not None and existing != schema:
            raise StorageError("schema identity collision")
        self._schemas[key] = schema

    def get_schema(self, ontology_id: UUID, version: int) -> OntologyDefinition | None:
        return self._schemas.get((ontology_id, version))

    def latest_schema(self, ontology_id: UUID) -> OntologyDefinition | None:
        matches = [
            schema for (stored_id, _), schema in self._schemas.items() if stored_id == ontology_id
        ]
        return max(matches, key=lambda schema: schema.version, default=None)

    def put_object(self, instance: ObjectInstance) -> None:
        schema = self._require_schema(instance.ontology_id, instance.ontology_version)
        if schema.get_object_type(instance.object_type_id) is None:
            raise StorageError("object instance references an unknown object type")
        existing = self._objects.get(instance.object_id)
        if existing is not None and (
            existing.ontology_id,
            existing.ontology_version,
            existing.object_type_id,
        ) != (
            instance.ontology_id,
            instance.ontology_version,
            instance.object_type_id,
        ):
            raise StorageError(
                "object identity collision", context={"object_id": instance.object_id}
            )
        self._check_assertions(instance.assertions)
        if existing is None:
            self._objects[instance.object_id] = instance
        self.put_assertions(instance.assertions)

    def get_object(self, object_id: UUID) -> ObjectInstance | None:
        return self._objects.get(object_id)

    def put_assertions(self, assertions: Sequence[Assertion]) -> None:
        self._check_assertions(assertions)
        for assertion in assertions:
            if (
                assertion.subject_id not in self._objects
                and assertion.subject_id not in self._relations
            ):
                raise StorageError("assertion references an unknown subject")
        for assertion in assertions:
            if assertion.assertion_id not in self._assertions:
                self._assertions[assertion.assertion_id] = assertion
                self._subjects[assertion.subject_id].append(assertion.assertion_id)

    def assertions_for(self, subject_id: UUID) -> tuple[Assertion, ...]:
        return tuple(
            sorted(
                (self._assertions[item] for item in self._subjects.get(subject_id, ())),
                key=lambda assertion: assertion.assertion_id.int,
            )
        )

    def get_assertion(self, assertion_id: UUID) -> Assertion | None:
        return self._assertions.get(assertion_id)

    def scan_objects(
        self, object_type_id: UUID | None, *, limit: int, offset: int
    ) -> tuple[ObjectInstance, ...]:
        self._validate_page(limit, offset)
        values = (
            item
            for item in self._objects.values()
            if object_type_id is None or item.object_type_id == object_type_id
        )
        ordered = sorted(values, key=lambda item: item.object_id.int)
        return tuple(ordered[offset : offset + limit])

    def lookup_objects(
        self,
        predicate: str,
        value: object,
        object_type_id: UUID | None,
        *,
        limit: int,
        offset: int,
    ) -> tuple[ObjectInstance, ...]:
        self._validate_page(limit, offset)
        matches: list[ObjectInstance] = []
        for instance in self._objects.values():
            if object_type_id is not None and instance.object_type_id != object_type_id:
                continue
            if any(
                assertion.predicate == predicate
                and isinstance(assertion.target, ValueTarget)
                and assertion.target.value == value
                for assertion in self.assertions_for(instance.object_id)
            ):
                matches.append(instance)
        matches.sort(key=lambda item: item.object_id.int)
        return tuple(matches[offset : offset + limit])

    def put_relation(self, instance: RelationInstance) -> None:
        schema = self._require_schema(instance.ontology_id, instance.ontology_version)
        relation_type = schema.get_relation_type(instance.relation_type_id)
        source = self._objects.get(instance.source_object_id)
        target = self._objects.get(instance.target_object_id)
        if relation_type is None:
            raise StorageError("relation instance references an unknown relation type")
        if source is None or target is None:
            raise StorageError("relation endpoint does not exist")
        if (
            source.object_type_id != relation_type.source_type_id
            or target.object_type_id != relation_type.target_type_id
        ):
            raise StorageError("relation endpoints do not match the relation type")
        existing = self._relations.get(instance.relation_id)
        if existing is not None and (
            existing.ontology_id,
            existing.ontology_version,
            existing.relation_type_id,
            existing.source_object_id,
            existing.target_object_id,
        ) != (
            instance.ontology_id,
            instance.ontology_version,
            instance.relation_type_id,
            instance.source_object_id,
            instance.target_object_id,
        ):
            raise StorageError(
                "relation identity collision", context={"relation_id": instance.relation_id}
            )
        self._check_assertions(instance.assertions)
        if existing is None:
            self._relations[instance.relation_id] = instance
            self._outgoing[instance.source_object_id].append(instance.relation_id)
            self._incoming[instance.target_object_id].append(instance.relation_id)
        self.put_assertions(instance.assertions)

    def get_relation(self, relation_id: UUID) -> RelationInstance | None:
        return self._relations.get(relation_id)

    def neighbors(
        self,
        object_id: UUID,
        relation_type_id: UUID | None,
        direction: RelationDirection,
        *,
        limit: int,
        offset: int,
    ) -> tuple[RelationInstance, ...]:
        self._validate_page(limit, offset)
        if object_id not in self._objects:
            return ()
        ids: list[UUID] = []
        if direction in (RelationDirection.OUTGOING, RelationDirection.BOTH):
            ids.extend(self._outgoing.get(object_id, ()))
        if direction in (RelationDirection.INCOMING, RelationDirection.BOTH):
            ids.extend(self._incoming.get(object_id, ()))
        relations = [self._relations[item] for item in dict.fromkeys(ids)]
        filtered = [
            item
            for item in relations
            if relation_type_id is None or item.relation_type_id == relation_type_id
        ]
        filtered.sort(key=lambda item: item.relation_id.int)
        return tuple(filtered[offset : offset + limit])

    def put_resolution(self, decision: ResolutionDecision) -> None:
        if decision.outcome is not ResolutionOutcome.MERGE:
            return
        canonical_id = decision.canonical_object_id
        if canonical_id is None:
            raise StorageError("merge resolution has no canonical object ID")
        for source_id in decision.source_object_ids:
            existing = self._canonical.get(source_id)
            if existing is not None and existing != canonical_id:
                raise StorageError("object has conflicting canonical resolutions")
        for source_id in decision.source_object_ids:
            self._canonical[source_id] = canonical_id

    def canonical_id(self, object_id: UUID) -> UUID:
        return self._canonical.get(object_id, object_id)

    def _require_schema(self, ontology_id: UUID, version: int) -> OntologyDefinition:
        schema = self.get_schema(ontology_id, version)
        if schema is None:
            raise StorageError("instance references an unpublished schema")
        return schema

    def _check_assertions(self, assertions: Sequence[Assertion]) -> None:
        for assertion in assertions:
            existing = self._assertions.get(assertion.assertion_id)
            if existing is not None and existing != assertion:
                raise StorageError("assertion identity collision")
            if (
                assertion.supersedes_assertion_id is not None
                and assertion.supersedes_assertion_id not in self._assertions
            ):
                raise StorageError("correction supersedes an unknown assertion")

    @staticmethod
    def _validate_page(limit: int, offset: int) -> None:
        if not 1 <= limit <= 10_000 or offset < 0:
            raise StorageError("invalid bounded page", context={"limit": limit, "offset": offset})

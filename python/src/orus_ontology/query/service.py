"""Storage-independent bounded ontology query service."""

from collections.abc import Iterable
from datetime import datetime
from uuid import UUID

from orus_ontology.assertions.assertion import Assertion, ValueTarget
from orus_ontology.assertions.provenance import SourceReference
from orus_ontology.errors import QueryError
from orus_ontology.materialization.batch import ObjectInstance, RelationInstance
from orus_ontology.query.filters import FilterOperator, ObjectQuery, PropertyFilter
from orus_ontology.query.traversal import CyclePolicy, TraversalQuery, TraversalResult
from orus_ontology.storage.contracts import OntologyStore, RelationDirection

_PAGE_SIZE = 256


class QueryService:
    def __init__(self, store: OntologyStore) -> None:
        self._store = store

    def get_object(self, object_id: UUID, *, canonical: bool = True) -> ObjectInstance | None:
        resolved = self._store.canonical_id(object_id) if canonical else object_id
        return self._store.get_object(resolved) or self._store.get_object(object_id)

    def find_objects(self, query: ObjectQuery) -> tuple[ObjectInstance, ...]:
        type_id = query.object_type_id
        equality = next(
            (item for item in query.filters if item.operator is FilterOperator.EQUALS), None
        )
        matched: list[ObjectInstance] = []
        skipped = 0
        page_offset = 0
        while len(matched) < query.limit:
            page = (
                self._store.lookup_objects(
                    equality.predicate,
                    equality.value,
                    type_id,
                    limit=_PAGE_SIZE,
                    offset=page_offset,
                )
                if equality is not None
                else self._store.scan_objects(type_id, limit=_PAGE_SIZE, offset=page_offset)
            )
            if not page:
                break
            for instance in page:
                if not self._matches(instance, query.filters):
                    continue
                if skipped < query.offset:
                    skipped += 1
                    continue
                matched.append(instance)
                if len(matched) == query.limit:
                    break
            page_offset += len(page)
        return tuple(matched)

    def assertions(
        self,
        subject_id: UUID,
        *,
        predicate: str | None = None,
        active_at: datetime | None = None,
        include_superseded: bool = False,
        limit: int = 100,
    ) -> tuple[Assertion, ...]:
        if not 1 <= limit <= 10_000:
            raise QueryError("assertion limit must be between 1 and 10000")
        history = self._store.assertions_for(subject_id)
        superseded = {
            item.supersedes_assertion_id for item in history if item.supersedes_assertion_id
        }
        result: list[Assertion] = []
        for assertion in history:
            if predicate is not None and assertion.predicate != predicate:
                continue
            if not include_superseded and assertion.assertion_id in superseded:
                continue
            if active_at is not None and not _active_at(assertion, active_at):
                continue
            result.append(assertion)
            if len(result) == limit:
                break
        return tuple(result)

    def neighbors(
        self,
        object_id: UUID,
        *,
        direction: RelationDirection = RelationDirection.BOTH,
        relation_type_id: UUID | None = None,
        limit: int = 100,
    ) -> tuple[tuple[RelationInstance, ObjectInstance], ...]:
        relations = self._store.neighbors(
            object_id, relation_type_id, direction, limit=limit, offset=0
        )
        result: list[tuple[RelationInstance, ObjectInstance]] = []
        for relation in relations:
            adjacent_id = (
                relation.target_object_id
                if relation.source_object_id == object_id
                else relation.source_object_id
            )
            adjacent = self._store.get_object(adjacent_id)
            if adjacent is not None:
                result.append((relation, adjacent))
        return tuple(result)

    def traverse(self, query: TraversalQuery) -> TraversalResult:
        frontier = {query.start_object_id}
        visited = {query.start_object_id}
        objects: list[ObjectInstance] = []
        relations: list[RelationInstance] = []
        relation_ids: set[UUID] = set()
        truncated = False
        depth_reached = 0
        for hop in query.hops:
            depth_reached += 1
            next_frontier: set[UUID] = set()
            for current in sorted(frontier, key=lambda value: value.int):
                edges = self._store.neighbors(
                    current,
                    hop.relation_type_id,
                    hop.direction,
                    limit=query.limit,
                    offset=0,
                )
                for edge in edges:
                    adjacent_id = (
                        edge.target_object_id
                        if edge.source_object_id == current
                        else edge.source_object_id
                    )
                    if adjacent_id in visited and query.cycle_policy is CyclePolicy.SKIP:
                        continue
                    adjacent = self._store.get_object(adjacent_id)
                    if (
                        adjacent is None
                        or (
                            hop.target_object_type_id is not None
                            and adjacent.object_type_id != hop.target_object_type_id
                        )
                        or not self._matches(adjacent, hop.target_filters)
                    ):
                        continue
                    if edge.relation_id not in relation_ids:
                        relations.append(edge)
                        relation_ids.add(edge.relation_id)
                    if adjacent_id not in visited:
                        objects.append(adjacent)
                    visited.add(adjacent_id)
                    next_frontier.add(adjacent_id)
                    if len(objects) >= query.limit:
                        truncated = True
                        break
                if truncated:
                    break
            frontier = next_frontier
            if truncated or not frontier:
                break
        return TraversalResult(
            objects=tuple(objects),
            relations=tuple(relations),
            depth_reached=depth_reached,
            truncated=truncated,
        )

    def provenance(self, subject_id: UUID, *, limit: int = 100) -> tuple[SourceReference, ...]:
        seen: set[str] = set()
        result: list[SourceReference] = []
        relation = self._store.get_relation(subject_id)
        sources: Iterable[SourceReference] = relation.provenance if relation else ()
        for source in (
            *sources,
            *(
                p
                for a in self.assertions(subject_id, include_superseded=True, limit=limit)
                for p in a.provenance
            ),
        ):
            key = source.model_dump_json()
            if key not in seen:
                seen.add(key)
                result.append(source)
                if len(result) == limit:
                    break
        return tuple(result)

    def _matches(self, instance: ObjectInstance, filters: tuple[PropertyFilter, ...]) -> bool:
        active = self.assertions(instance.object_id, limit=10_000)
        values: dict[str, list[object]] = {}
        for assertion in active:
            if isinstance(assertion.target, ValueTarget):
                values.setdefault(assertion.predicate, []).append(assertion.target.value)
        return all(
            any(_compare(value, item) for value in values.get(item.predicate, ()))
            for item in filters
        )


def _active_at(assertion: Assertion, at: datetime) -> bool:
    temporal = assertion.temporal
    return (temporal.valid_from is None or temporal.valid_from <= at) and (
        temporal.valid_to is None or at <= temporal.valid_to
    )


def _compare(actual: object, condition: PropertyFilter) -> bool:
    expected = condition.value
    try:
        if condition.operator is FilterOperator.EQUALS:
            return actual == expected
        if condition.operator is FilterOperator.NOT_EQUALS:
            return actual != expected
        if condition.operator is FilterOperator.LESS_THAN:
            return actual < expected  # type: ignore[operator]
        if condition.operator is FilterOperator.LESS_THAN_OR_EQUAL:
            return actual <= expected  # type: ignore[operator]
        if condition.operator is FilterOperator.GREATER_THAN:
            return actual > expected  # type: ignore[operator]
        if condition.operator is FilterOperator.GREATER_THAN_OR_EQUAL:
            return actual >= expected  # type: ignore[operator]
        if condition.operator is FilterOperator.CONTAINS:
            return expected in actual  # type: ignore[operator]
        if condition.operator is FilterOperator.IN:
            return actual in expected  # type: ignore[operator]
    except TypeError:
        return False
    return False

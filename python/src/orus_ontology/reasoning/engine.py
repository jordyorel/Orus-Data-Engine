"""Deterministic bounded forward-chaining over stored assertions."""

from datetime import datetime
from decimal import Decimal
from uuid import UUID, uuid5

from pydantic import Field

from orus_ontology._schema import ImmutableModel
from orus_ontology.assertions.assertion import Assertion, AssertionKind, ValueTarget
from orus_ontology.assertions.temporal import TemporalContext, normalize_utc
from orus_ontology.errors import ReasoningError
from orus_ontology.materialization.batch import ObjectInstance
from orus_ontology.reasoning.rule import ConditionOperator, InferenceRule, RuleCondition
from orus_ontology.storage.contracts import OntologyStore


class ReasoningLimits(ImmutableModel):
    max_iterations: int = Field(default=8, ge=1, le=64)
    max_assertions: int = Field(default=10_000, ge=1, le=1_000_000)
    max_objects: int = Field(default=100_000, ge=1, le=10_000_000)
    page_size: int = Field(default=256, ge=1, le=10_000)


class ReasoningResult(ImmutableModel):
    iterations: int = Field(ge=0)
    objects_scanned: int = Field(ge=0)
    assertions_created: int = Field(ge=0)
    saturated: bool
    truncated: bool


class InferenceExplanation(ImmutableModel):
    assertion: Assertion
    premises: tuple["InferenceExplanation", ...] = ()
    truncated: bool = False


class ReasoningEngine:
    def __init__(self, store: OntologyStore) -> None:
        self._store = store

    def apply(
        self,
        rules: tuple[InferenceRule, ...],
        *,
        recorded_at: datetime,
        limits: ReasoningLimits | None = None,
    ) -> ReasoningResult:
        if not rules:
            raise ReasoningError("reasoning requires at least one rule")
        rule_keys = [(rule.rule_id, rule.version) for rule in rules]
        if len(rule_keys) != len(set(rule_keys)):
            raise ReasoningError("reasoning rules must have unique ID/version pairs")
        recorded_at = normalize_utc(recorded_at)
        limits = limits or ReasoningLimits()
        ordered_rules = tuple(sorted(rules, key=lambda item: (item.rule_id, item.version)))
        created = 0
        scanned = 0
        total_scanned = 0
        truncated = False
        saturated = False

        for iteration in range(1, limits.max_iterations + 1):
            pending: list[Assertion] = []
            offset = 0
            while scanned < limits.max_objects:
                page_limit = min(limits.page_size, limits.max_objects - scanned)
                objects = self._store.scan_objects(None, limit=page_limit, offset=offset)
                if not objects:
                    break
                scanned += len(objects)
                total_scanned += len(objects)
                offset += len(objects)
                for instance in objects:
                    assertions = self._active_assertions(instance.object_id)
                    for rule in ordered_rules:
                        if instance.object_type_id != rule.object_type_id:
                            continue
                        inferred = self._infer(instance, assertions, rule, recorded_at)
                        if inferred is None or self._store.get_assertion(inferred.assertion_id):
                            continue
                        if any(item.assertion_id == inferred.assertion_id for item in pending):
                            continue
                        pending.append(inferred)
                        if created + len(pending) >= limits.max_assertions:
                            truncated = True
                            break
                    if truncated:
                        break
                if truncated or len(objects) < page_limit:
                    break
            if pending:
                self._store.put_assertions(pending)
                created += len(pending)
            if truncated:
                return ReasoningResult(
                    iterations=iteration,
                    objects_scanned=total_scanned,
                    assertions_created=created,
                    saturated=False,
                    truncated=True,
                )
            if not pending:
                saturated = True
                return ReasoningResult(
                    iterations=iteration,
                    objects_scanned=total_scanned,
                    assertions_created=created,
                    saturated=True,
                    truncated=False,
                )
            scanned = 0
        return ReasoningResult(
            iterations=limits.max_iterations,
            objects_scanned=total_scanned,
            assertions_created=created,
            saturated=saturated,
            truncated=not saturated,
        )

    def explain(self, assertion_id: UUID, *, max_depth: int = 8) -> InferenceExplanation:
        if not 0 <= max_depth <= 64:
            raise ReasoningError("explanation depth must be between 0 and 64")
        assertion = self._store.get_assertion(assertion_id)
        if assertion is None:
            raise ReasoningError("assertion to explain does not exist")
        return self._explain(assertion, max_depth, set())

    def _infer(
        self,
        instance: ObjectInstance,
        assertions: tuple[Assertion, ...],
        rule: InferenceRule,
        recorded_at: datetime,
    ) -> Assertion | None:
        schema = self._store.get_schema(instance.ontology_id, instance.ontology_version)
        object_type = schema.get_object_type(instance.object_type_id) if schema else None
        if object_type is None:
            raise ReasoningError("reasoning subject has no published object type")
        declared = {prop.name: prop for prop in object_type.properties}
        unknown = [
            condition.predicate
            for condition in rule.conditions
            if condition.predicate not in declared
        ]
        if unknown:
            raise ReasoningError(
                "rule condition is not declared by its object type",
                context={"rule_id": rule.rule_id, "predicates": tuple(unknown)},
            )
        conclusion_property = declared.get(rule.conclusion.predicate)
        if (
            conclusion_property is None
            or conclusion_property.value_type is not rule.conclusion.value_type
        ):
            raise ReasoningError(
                "rule conclusion does not match its object type",
                context={"rule_id": rule.rule_id, "predicate": rule.conclusion.predicate},
            )
        matched: dict[str, Assertion] = {}
        for condition in rule.conditions:
            candidates = [
                assertion
                for assertion in assertions
                if assertion.predicate == condition.predicate
                and isinstance(assertion.target, ValueTarget)
                and _matches(assertion.target.value, condition)
            ]
            if not candidates:
                return None
            matched[condition.predicate] = min(
                candidates, key=lambda assertion: assertion.assertion_id.int
            )
        conclusion = rule.conclusion
        raw_value = conclusion.value
        if conclusion.copy_from_predicate is not None:
            source = matched[conclusion.copy_from_predicate]
            assert isinstance(source.target, ValueTarget)
            raw_value = source.target.value
        target = ValueTarget(value_type=conclusion.value_type, value=raw_value)
        if any(
            assertion.predicate == conclusion.predicate and assertion.target == target
            for assertion in assertions
        ):
            return None
        premises = tuple(sorted(matched.values(), key=lambda item: item.assertion_id.int))
        temporal = _intersect_temporal(premises, recorded_at)
        if temporal is None:
            return None
        first = premises[0]
        confidence = min((item.confidence for item in premises), default=Decimal("1"))
        confidence *= rule.confidence
        assertion_id = uuid5(
            first.ontology_id,
            f"inference:{instance.object_id}:{rule.rule_id}:{rule.version}:{conclusion.predicate}",
        )
        return Assertion(
            assertion_id=assertion_id,
            ontology_id=first.ontology_id,
            ontology_version=first.ontology_version,
            subject_id=instance.object_id,
            predicate=conclusion.predicate,
            target=target,
            kind=AssertionKind.INFERRED,
            derived_from_assertion_ids=tuple(item.assertion_id for item in premises),
            confidence=confidence,
            temporal=temporal,
            mapping_version=max(item.mapping_version for item in premises),
            rule_id=f"{rule.rule_id}@{rule.version}",
        )

    def _active_assertions(self, subject_id: UUID) -> tuple[Assertion, ...]:
        history = self._store.assertions_for(subject_id)
        superseded = {
            item.supersedes_assertion_id for item in history if item.supersedes_assertion_id
        }
        return tuple(item for item in history if item.assertion_id not in superseded)

    def _explain(self, assertion: Assertion, depth: int, path: set[UUID]) -> InferenceExplanation:
        if assertion.assertion_id in path:
            return InferenceExplanation(assertion=assertion, truncated=True)
        if not assertion.derived_from_assertion_ids:
            return InferenceExplanation(assertion=assertion)
        if depth == 0:
            return InferenceExplanation(assertion=assertion, truncated=True)
        next_path = {*path, assertion.assertion_id}
        premises: list[InferenceExplanation] = []
        for premise_id in assertion.derived_from_assertion_ids:
            premise = self._store.get_assertion(premise_id)
            if premise is None:
                raise ReasoningError(
                    "inference references a missing premise",
                    context={"assertion_id": assertion.assertion_id, "premise_id": premise_id},
                )
            premises.append(self._explain(premise, depth - 1, next_path))
        return InferenceExplanation(assertion=assertion, premises=tuple(premises))


def _matches(value: object, condition: RuleCondition) -> bool:
    if condition.operator is ConditionOperator.EXISTS:
        return True
    if condition.operator is ConditionOperator.EQUALS:
        return value == condition.value
    return value != condition.value


def _intersect_temporal(
    premises: tuple[Assertion, ...], recorded_at: datetime
) -> TemporalContext | None:
    observed_at = max(item.temporal.observed_at for item in premises)
    if recorded_at < observed_at:
        raise ReasoningError("inference recording time precedes its premises")
    starts = [item.temporal.valid_from for item in premises if item.temporal.valid_from]
    ends = [item.temporal.valid_to for item in premises if item.temporal.valid_to]
    valid_from = max(starts) if starts else None
    valid_to = min(ends) if ends else None
    if valid_from is not None and valid_to is not None and valid_from > valid_to:
        return None
    return TemporalContext(
        observed_at=observed_at,
        valid_from=valid_from,
        valid_to=valid_to,
        recorded_at=recorded_at,
    )

from datetime import UTC, datetime
from uuid import UUID

import pytest

from orus_ontology import (
    AssertionKind,
    BatchMaterializer,
    CanonicalRecord,
    ConditionOperator,
    InferenceRule,
    MappingCompiler,
    MappingDefinition,
    MemoryStore,
    ObjectType,
    OntologyDefinition,
    PropertyType,
    ReasoningEngine,
    ReasoningError,
    ReasoningLimits,
    RuleConclusion,
    RuleCondition,
    SourceContract,
    SourceReference,
    ValueTarget,
    ValueType,
)

NOW = datetime(2026, 8, 15, 12, tzinfo=UTC)
RUN_ID = UUID("aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")


def _reasoning_ontology(base: OntologyDefinition) -> OntologyDefinition:
    customer = base.get_object_type("Customer")
    assert customer is not None
    extended_customer = ObjectType.model_validate(
        {
            **customer.model_dump(),
            "properties": (
                *customer.properties,
                PropertyType(name="segment", value_type=ValueType.STRING),
                PropertyType(name="review_status", value_type=ValueType.STRING),
            ),
        }
    )
    return OntologyDefinition.model_validate(
        {
            **base.model_dump(),
            "object_types": tuple(
                extended_customer if item.type_id == customer.type_id else item
                for item in base.object_types
            ),
        }
    )


@pytest.fixture
def reasoning_store(
    ontology: OntologyDefinition,
    source_contract: SourceContract,
    mapping_definition: MappingDefinition,
) -> tuple[MemoryStore, ObjectType]:
    extended = _reasoning_ontology(ontology)
    plan = MappingCompiler.compile(mapping_definition, extended, source_contract)
    record = CanonicalRecord(
        values={
            "customer_id": "C-42",
            "customer_name": "Alice",
            "email": "alice@example.com",
            "email_verified": True,
        },
        source=SourceReference(
            source_id="reasoning.csv",
            batch_id=0,
            row_id=0,
            global_offset=0,
            run_id=RUN_ID,
            observed_at=NOW,
        ),
    )
    batch = next(BatchMaterializer(plan, batch_size=1, recorded_at=NOW).materialize((record,)))
    store = MemoryStore()
    store.put_schema(extended)
    for instance in batch.objects:
        store.put_object(instance)
    for relation in batch.relations:
        store.put_relation(relation)
    customer = extended.get_object_type("Customer")
    assert customer is not None
    return store, customer


def _rules(customer: ObjectType) -> tuple[InferenceRule, ...]:
    return (
        InferenceRule(
            rule_id="derive_segment",
            object_type_id=customer.type_id,
            conditions=(RuleCondition(predicate="customer_id"),),
            conclusion=RuleConclusion(
                predicate="segment", value_type=ValueType.STRING, value="known"
            ),
        ),
        InferenceRule(
            rule_id="derive_review",
            object_type_id=customer.type_id,
            conditions=(
                RuleCondition(
                    predicate="segment",
                    operator=ConditionOperator.EQUALS,
                    value="known",
                ),
            ),
            conclusion=RuleConclusion(
                predicate="review_status",
                value_type=ValueType.STRING,
                value="ready",
            ),
        ),
    )


def test_forward_chaining_is_deterministic_bounded_and_explainable(
    reasoning_store: tuple[MemoryStore, ObjectType],
) -> None:
    store, customer_type = reasoning_store
    engine = ReasoningEngine(store)
    result = engine.apply(_rules(customer_type), recorded_at=NOW)

    assert result.assertions_created == 2
    assert result.iterations == 3
    assert result.saturated and not result.truncated
    customer = store.scan_objects(customer_type.type_id, limit=1, offset=0)[0]
    inferred = tuple(
        item
        for item in store.assertions_for(customer.object_id)
        if item.kind is AssertionKind.INFERRED
    )
    assert {item.predicate for item in inferred} == {"segment", "review_status"}
    review = next(item for item in inferred if item.predicate == "review_status")
    assert isinstance(review.target, ValueTarget)
    assert review.target.value == "ready"
    explanation = engine.explain(review.assertion_id)
    assert explanation.premises[0].assertion.predicate == "segment"
    assert explanation.premises[0].premises[0].assertion.predicate == "customer_id"

    repeated = engine.apply(_rules(customer_type), recorded_at=NOW)
    assert repeated.assertions_created == 0
    assert repeated.saturated


def test_reasoning_limits_mark_partial_expansion(
    reasoning_store: tuple[MemoryStore, ObjectType],
) -> None:
    store, customer_type = reasoning_store
    result = ReasoningEngine(store).apply(
        _rules(customer_type),
        recorded_at=NOW,
        limits=ReasoningLimits(max_assertions=1),
    )
    assert result.assertions_created == 1
    assert result.truncated and not result.saturated


def test_invalid_rule_schema_and_explanation_depth_are_rejected(
    reasoning_store: tuple[MemoryStore, ObjectType],
) -> None:
    store, customer_type = reasoning_store
    invalid = InferenceRule(
        rule_id="unknown_conclusion",
        object_type_id=customer_type.type_id,
        conditions=(RuleCondition(predicate="customer_id"),),
        conclusion=RuleConclusion(
            predicate="missing_property", value_type=ValueType.STRING, value="x"
        ),
    )
    with pytest.raises(ReasoningError, match="conclusion"):
        ReasoningEngine(store).apply((invalid,), recorded_at=NOW)

    engine = ReasoningEngine(store)
    engine.apply(_rules(customer_type), recorded_at=NOW)
    customer = store.scan_objects(customer_type.type_id, limit=1, offset=0)[0]
    inferred = next(
        item
        for item in store.assertions_for(customer.object_id)
        if item.predicate == "review_status"
    )
    assert engine.explain(inferred.assertion_id, max_depth=0).truncated

from collections.abc import Mapping
from datetime import UTC, datetime
from decimal import Decimal
from types import MappingProxyType
from uuid import UUID, uuid4

import pytest
from pydantic import ValidationError

from orus_ontology import (
    Assertion,
    AssertionKind,
    AssertionTarget,
    ObjectTarget,
    SourceReference,
    TemporalContext,
    ValueTarget,
    ValueType,
)

NOW = datetime(2026, 8, 15, 12, 0, tzinfo=UTC)


def source_reference() -> SourceReference:
    return SourceReference(
        source_id="customers.csv",
        batch_id=1,
        row_id=42,
        run_id=uuid4(),
        observed_at=NOW,
    )


def make_assertion(
    target: AssertionTarget,
    *,
    kind: AssertionKind = AssertionKind.OBSERVED,
    provenance: tuple[SourceReference, ...] | None = None,
    derived_from: tuple[UUID, ...] = (),
    confidence: Decimal = Decimal("1"),
    rule_id: str | None = None,
    supersedes: UUID | None = None,
    metadata: Mapping[str, object] | None = None,
) -> Assertion:
    return Assertion(
        ontology_id=uuid4(),
        ontology_version=1,
        subject_id=uuid4(),
        predicate="balance",
        target=target,
        kind=kind,
        provenance=(source_reference(),) if provenance is None else provenance,
        derived_from_assertion_ids=derived_from,
        confidence=confidence,
        temporal=TemporalContext(observed_at=NOW, recorded_at=NOW),
        mapping_version=1,
        rule_id=rule_id,
        supersedes_assertion_id=supersedes,
        metadata=metadata or {},
    )


def test_value_assertion_round_trips_exact_decimal_and_provenance() -> None:
    assertion = make_assertion(
        ValueTarget(value_type=ValueType.DECIMAL, value=Decimal("12.340")),
        confidence=Decimal("0.95"),
        metadata={"review": {"labels": ["verified"]}},
    )

    restored = Assertion.model_validate_json(assertion.model_dump_json())

    assert restored == assertion
    assert isinstance(restored.target, ValueTarget)
    assert restored.target.value == Decimal("12.340")
    assert restored.confidence == Decimal("0.95")
    assert isinstance(restored.metadata, MappingProxyType)


def test_value_target_distinguishes_explicit_null_from_object_target() -> None:
    null_target = ValueTarget(value_type=ValueType.STRING, value=None)
    object_id = uuid4()
    object_target = ObjectTarget(object_id=object_id)

    assert null_target.value is None
    assert object_target.object_id == object_id
    assert null_target.target_kind != object_target.target_kind


@pytest.mark.parametrize(
    ("value_type", "value"),
    [
        (ValueType.INTEGER, True),
        (ValueType.DECIMAL, 1.5),
        (ValueType.BOOLEAN, "true"),
        (ValueType.REFERENCE, "not-a-uuid"),
    ],
)
def test_value_target_rejects_incompatible_values(value_type: ValueType, value: object) -> None:
    with pytest.raises(ValidationError):
        ValueTarget(value_type=value_type, value=value)


def test_json_target_is_deeply_immutable() -> None:
    source = {"tags": ["customer", {"score": 1}]}
    target = ValueTarget(value_type=ValueType.JSON, value=source)
    source["tags"].append("mutated")

    assert target.value == MappingProxyType({"tags": ("customer", MappingProxyType({"score": 1}))})


def test_assertion_requires_an_origin_and_exact_confidence() -> None:
    with pytest.raises(ValidationError, match="requires direct source provenance"):
        make_assertion(
            ValueTarget(value_type=ValueType.STRING, value="Alice"),
            provenance=(),
        )

    with pytest.raises(ValidationError, match="requires direct source provenance"):
        make_assertion(
            ValueTarget(value_type=ValueType.STRING, value="Alice"),
            provenance=(),
            derived_from=(uuid4(),),
        )

    with pytest.raises(ValidationError, match="must use Decimal"):
        Assertion(
            ontology_id=uuid4(),
            ontology_version=1,
            subject_id=uuid4(),
            predicate="name",
            target=ValueTarget(value_type=ValueType.STRING, value="Alice"),
            kind=AssertionKind.OBSERVED,
            provenance=(source_reference(),),
            confidence=0.9,  # type: ignore[arg-type]
            temporal=TemporalContext(observed_at=NOW, recorded_at=NOW),
            mapping_version=1,
        )

    with pytest.raises(ValidationError, match="between 0 and 1"):
        make_assertion(
            ValueTarget(value_type=ValueType.STRING, value="Alice"),
            confidence=Decimal("1.1"),
        )


def test_inference_requires_rule_and_source_assertions() -> None:
    with pytest.raises(ValidationError, match="requires rule_id"):
        make_assertion(
            ObjectTarget(object_id=uuid4()),
            kind=AssertionKind.INFERRED,
            provenance=(),
            derived_from=(uuid4(),),
        )

    with pytest.raises(ValidationError, match="requires source assertion IDs"):
        make_assertion(
            ObjectTarget(object_id=uuid4()),
            kind=AssertionKind.INFERRED,
            provenance=(),
            rule_id="shared_email@1",
        )


def test_correction_references_prior_assertion_without_mutating_it() -> None:
    original = make_assertion(ValueTarget(value_type=ValueType.STRING, value="Alic"))
    corrected = make_assertion(
        ValueTarget(value_type=ValueType.STRING, value="Alice"),
        kind=AssertionKind.CORRECTED,
        supersedes=original.assertion_id,
    )

    assert corrected.supersedes_assertion_id == original.assertion_id
    assert isinstance(original.target, ValueTarget)
    assert original.target.value == "Alic"

    with pytest.raises(ValidationError, match="requires supersedes"):
        make_assertion(
            ValueTarget(value_type=ValueType.STRING, value="Alice"),
            kind=AssertionKind.CORRECTED,
        )

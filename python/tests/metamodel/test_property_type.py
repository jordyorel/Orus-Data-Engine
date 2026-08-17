from decimal import Decimal
from types import MappingProxyType
from uuid import uuid4

import pytest
from pydantic import ValidationError

from orus_ontology import PropertyCardinality, PropertyConstraints, PropertyType, ValueType


def test_property_type_is_deeply_immutable_and_serializable() -> None:
    source_metadata = {"labels": ["pii", {"level": 2}]}
    prop = PropertyType(
        name="customer_id",
        value_type=ValueType.STRING,
        required=True,
        nullable=False,
        metadata=source_metadata,
    )

    source_metadata["labels"].append("mutated")

    assert isinstance(prop.metadata, MappingProxyType)
    assert prop.metadata["labels"] == ("pii", MappingProxyType({"level": 2}))
    assert prop.model_dump(mode="json")["metadata"] == {"labels": ["pii", {"level": 2}]}
    assert PropertyType.model_validate_json(prop.model_dump_json()) == prop

    with pytest.raises(ValidationError, match="frozen"):
        prop.name = "other"  # type: ignore[misc]


@pytest.mark.parametrize(
    ("value_type", "default_value"),
    [
        (ValueType.STRING, 42),
        (ValueType.INTEGER, True),
        (ValueType.DECIMAL, 1.5),
        (ValueType.BOOLEAN, "true"),
        (ValueType.DATE, "2026-08-15"),
    ],
)
def test_property_rejects_incompatible_default(
    value_type: ValueType, default_value: object
) -> None:
    with pytest.raises(ValidationError, match="default value is incompatible"):
        PropertyType(name="invalid_default", value_type=value_type, default_value=default_value)


def test_decimal_default_remains_exact() -> None:
    prop = PropertyType(
        name="balance",
        value_type=ValueType.DECIMAL,
        default_value=Decimal("12.340"),
    )

    assert prop.default_value == Decimal("12.340")
    assert "12.340" in prop.model_dump_json()


def test_reference_and_enum_require_their_structural_configuration() -> None:
    with pytest.raises(ValidationError, match="reference_type_id"):
        PropertyType(name="employer", value_type=ValueType.REFERENCE)

    with pytest.raises(ValidationError, match="at least one enum value"):
        PropertyType(name="status", value_type=ValueType.ENUM)

    target_id = uuid4()
    reference = PropertyType(
        name="employer",
        value_type=ValueType.REFERENCE,
        reference_type_id=target_id,
    )
    enum = PropertyType(
        name="status",
        value_type=ValueType.ENUM,
        constraints=PropertyConstraints(enum_values=("active", "closed")),
        default_value="active",
    )

    assert reference.reference_type_id == target_id
    assert enum.default_value == "active"


def test_constraints_reject_inverted_ranges_and_duplicate_enum_values() -> None:
    with pytest.raises(ValidationError, match="min_length must not exceed"):
        PropertyConstraints(min_length=8, max_length=4)

    with pytest.raises(ValidationError, match="enum constraint values must be unique"):
        PropertyConstraints(enum_values=("active", "active"))


def test_constraints_must_match_property_value_type() -> None:
    with pytest.raises(ValidationError, match="only valid for string"):
        PropertyType(
            name="age",
            value_type=ValueType.INTEGER,
            constraints=PropertyConstraints(min_length=1),
        )

    with pytest.raises(ValidationError, match="only valid for integer or decimal"):
        PropertyType(
            name="name",
            value_type=ValueType.STRING,
            constraints=PropertyConstraints(minimum=Decimal("1")),
        )

    with pytest.raises(ValidationError, match="invalid property pattern"):
        PropertyConstraints(pattern="[")


def test_many_valued_default_is_an_immutable_validated_collection() -> None:
    prop = PropertyType(
        name="tags",
        value_type=ValueType.STRING,
        cardinality=PropertyCardinality.MANY,
        default_value=["new", "customer"],
    )

    assert prop.default_value == ("new", "customer")

    with pytest.raises(ValidationError, match="must be a collection"):
        PropertyType(
            name="tags",
            value_type=ValueType.STRING,
            cardinality=PropertyCardinality.MANY,
            default_value="new",
        )


def test_metadata_rejects_non_json_values_without_silent_conversion() -> None:
    with pytest.raises(ValidationError, match="valid string"):
        PropertyType(
            name="name",
            value_type=ValueType.STRING,
            metadata={1: "invalid"},  # type: ignore[dict-item]
        )

    with pytest.raises(ValidationError, match="must be finite"):
        PropertyType(name="name", value_type=ValueType.STRING, metadata={"score": float("nan")})

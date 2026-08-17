from datetime import UTC, datetime
from decimal import Decimal
from uuid import UUID, uuid4

import pytest

from orus_ontology import (
    IdentityError,
    IdentityGenerator,
    IdentityNormalizer,
    IdentitySpec,
    ObjectType,
    PropertyType,
    ValueType,
)


def make_customer(identity_spec: IdentitySpec | None = None) -> ObjectType:
    return ObjectType(
        name="Customer",
        identity_spec=identity_spec
        or IdentitySpec(
            property_names=("country_code", "customer_id"),
            normalizers=(IdentityNormalizer.TRIM, IdentityNormalizer.UPPERCASE),
        ),
        properties=(
            PropertyType(
                name="country_code",
                value_type=ValueType.STRING,
                required=True,
                nullable=False,
            ),
            PropertyType(
                name="customer_id",
                value_type=ValueType.STRING,
                required=True,
                nullable=False,
            ),
        ),
    )


def test_identity_is_stable_across_input_order_and_equivalent_normalization() -> None:
    ontology_id = UUID("12345678-1234-5678-1234-567812345678")
    customer = make_customer()

    first = IdentityGenerator.generate(
        ontology_id,
        customer,
        {"country_code": " cg ", "customer_id": " ab-42 "},
    )
    second = IdentityGenerator.generate(
        ontology_id,
        customer,
        {"customer_id": "AB-42", "country_code": "CG"},
    )

    assert first == second
    assert first == IdentityGenerator.generate(
        ontology_id,
        customer,
        {"country_code": "CG", "customer_id": "AB-42"},
    )


def test_composite_identity_encoding_does_not_have_separator_collisions() -> None:
    ontology_id = uuid4()
    customer = make_customer(IdentitySpec(property_names=("country_code", "customer_id")))

    first = IdentityGenerator.generate(
        ontology_id,
        customer,
        {"country_code": "A:B", "customer_id": "C"},
    )
    second = IdentityGenerator.generate(
        ontology_id,
        customer,
        {"country_code": "A", "customer_id": "B:C"},
    )

    assert first != second


def test_identity_rejects_missing_null_and_empty_components() -> None:
    customer = make_customer()
    ontology_id = uuid4()

    with pytest.raises(IdentityError, match="is missing"):
        IdentityGenerator.generate(ontology_id, customer, {"country_code": "CG"})

    with pytest.raises(IdentityError, match="must not be null"):
        IdentityGenerator.generate(
            ontology_id,
            customer,
            {"country_code": "CG", "customer_id": None},
        )

    with pytest.raises(IdentityError, match="must not be empty"):
        IdentityGenerator.generate(
            ontology_id,
            customer,
            {"country_code": "CG", "customer_id": "   "},
        )


def test_decimal_and_datetime_identity_components_are_canonical() -> None:
    account = ObjectType(
        name="AccountSnapshot",
        identity_spec=IdentitySpec(property_names=("balance", "captured_at")),
        properties=(
            PropertyType(
                name="balance",
                value_type=ValueType.DECIMAL,
                required=True,
                nullable=False,
            ),
            PropertyType(
                name="captured_at",
                value_type=ValueType.DATETIME,
                required=True,
                nullable=False,
            ),
        ),
    )
    ontology_id = uuid4()
    instant = datetime(2026, 8, 15, 12, 0, tzinfo=UTC)

    first = IdentityGenerator.generate(
        ontology_id,
        account,
        {"balance": Decimal("12.3400"), "captured_at": instant},
    )
    second = IdentityGenerator.generate(
        ontology_id,
        account,
        {"balance": "12.34", "captured_at": "2026-08-15T12:00:00+00:00"},
    )

    assert first == second

    with pytest.raises(IdentityError, match="must include a timezone"):
        IdentityGenerator.generate(
            ontology_id,
            account,
            {
                "balance": Decimal("12.34"),
                "captured_at": datetime(2026, 8, 15, 12, 0),
            },
        )

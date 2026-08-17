from uuid import uuid4

import pytest
from pydantic import ValidationError

from orus_ontology import IdentityNormalizer, IdentitySpec, ObjectType, PropertyType, ValueType


def customer_id_property() -> PropertyType:
    return PropertyType(
        name="customer_id",
        value_type=ValueType.STRING,
        required=True,
        nullable=False,
        unique=True,
    )


def test_object_type_requires_declared_non_nullable_identity_properties() -> None:
    identity = IdentitySpec(property_names=("customer_id",))

    with pytest.raises(ValidationError, match="is not declared"):
        ObjectType(name="Customer", identity_spec=identity, properties=())

    nullable_identity = PropertyType(
        name="customer_id",
        value_type=ValueType.STRING,
        required=True,
        nullable=True,
    )
    with pytest.raises(ValidationError, match="required and non-nullable"):
        ObjectType(name="Customer", identity_spec=identity, properties=(nullable_identity,))


def test_object_type_rejects_duplicate_property_names_and_ids() -> None:
    identity = IdentitySpec(property_names=("customer_id",))
    first = customer_id_property()
    duplicate_name = PropertyType(
        name="customer_id",
        value_type=ValueType.INTEGER,
        required=True,
        nullable=False,
    )
    with pytest.raises(ValidationError, match="property names must be unique"):
        ObjectType(
            name="Customer",
            identity_spec=identity,
            properties=(first, duplicate_name),
        )

    duplicate_id = PropertyType(
        property_id=first.property_id,
        name="external_id",
        value_type=ValueType.STRING,
    )
    with pytest.raises(ValidationError, match="property IDs must be unique"):
        ObjectType(
            name="Customer",
            identity_spec=identity,
            properties=(first, duplicate_id),
        )


def test_identity_spec_is_ordered_validated_and_immutable() -> None:
    identity = IdentitySpec(
        property_names=("country_code", "customer_id"),
        normalizers=(IdentityNormalizer.TRIM, IdentityNormalizer.UPPERCASE),
    )

    assert identity.property_names == ("country_code", "customer_id")

    with pytest.raises(ValidationError, match="must be unique"):
        IdentitySpec(property_names=("customer_id", "customer_id"))

    with pytest.raises(ValidationError, match="lowercase and uppercase"):
        IdentitySpec(
            property_names=("customer_id",),
            normalizers=(IdentityNormalizer.LOWERCASE, IdentityNormalizer.UPPERCASE),
        )


def test_schema_names_reject_spaces_and_punctuation() -> None:
    with pytest.raises(ValidationError, match="must start with a letter"):
        IdentitySpec(property_names=("Customer Id",))

    with pytest.raises(ValidationError, match="must start with a letter"):
        PropertyType(name="customer-id", value_type=ValueType.STRING)


def test_get_property_uses_name_not_property_id_string() -> None:
    prop = customer_id_property()
    object_type = ObjectType(
        type_id=uuid4(),
        name="Customer",
        identity_spec=IdentitySpec(property_names=("customer_id",)),
        properties=(prop,),
    )

    assert object_type.get_property("customer_id") is prop
    assert object_type.get_property(str(prop.property_id)) is None

from uuid import uuid4

import pytest
from pydantic import ValidationError

from orus_ontology import (
    IdentitySpec,
    ObjectType,
    OntologyDefinition,
    PropertyType,
    RelationType,
    SchemaError,
    SchemaValidator,
    ValueType,
)


def make_object_type(name: str, identity_name: str) -> ObjectType:
    identity = PropertyType(
        name=identity_name,
        value_type=ValueType.STRING,
        required=True,
        nullable=False,
        unique=True,
    )
    return ObjectType(
        name=name,
        identity_spec=IdentitySpec(property_names=(identity_name,)),
        properties=(identity,),
    )


def test_complete_ontology_round_trips_with_stable_ids() -> None:
    customer = make_object_type("Customer", "customer_id")
    company = make_object_type("Company", "company_id")
    works_for = RelationType(
        name="WORKS_FOR",
        source_type_id=customer.type_id,
        target_type_id=company.type_id,
    )
    ontology = OntologyDefinition(
        name="Commerce",
        object_types=(customer, company),
        relation_types=(works_for,),
        metadata={"domain": {"owners": ["data-team"]}},
    )

    restored = OntologyDefinition.model_validate_json(ontology.model_dump_json())

    assert restored == ontology
    assert restored.ontology_id == ontology.ontology_id
    assert restored.get_object_type("Customer") == customer
    assert restored.get_relation_type(works_for.type_id) == works_for
    SchemaValidator.validate(restored)


def test_ontology_rejects_unknown_relation_endpoints() -> None:
    customer = make_object_type("Customer", "customer_id")
    relation = RelationType(
        name="WORKS_FOR",
        source_type_id=customer.type_id,
        target_type_id=uuid4(),
    )

    with pytest.raises(ValidationError, match="unknown target type"):
        OntologyDefinition(
            name="Commerce",
            object_types=(customer,),
            relation_types=(relation,),
        )


def test_ontology_rejects_unknown_reference_target() -> None:
    customer_id = PropertyType(
        name="customer_id",
        value_type=ValueType.STRING,
        required=True,
        nullable=False,
    )
    employer = PropertyType(
        name="employer",
        value_type=ValueType.REFERENCE,
        reference_type_id=uuid4(),
    )
    customer = ObjectType(
        name="Customer",
        identity_spec=IdentitySpec(property_names=("customer_id",)),
        properties=(customer_id, employer),
    )

    with pytest.raises(ValidationError, match="references an unknown object type"):
        OntologyDefinition(name="Commerce", object_types=(customer,))


def test_ontology_rejects_duplicate_type_names_and_global_property_ids() -> None:
    first = make_object_type("Customer", "customer_id")
    same_name = make_object_type("Customer", "external_id")
    with pytest.raises(ValidationError, match="object type names must be unique"):
        OntologyDefinition(name="Commerce", object_types=(first, same_name))

    shared_id = first.properties[0].property_id
    duplicate_property = PropertyType(
        property_id=shared_id,
        name="company_id",
        value_type=ValueType.STRING,
        required=True,
        nullable=False,
    )
    company = ObjectType(
        name="Company",
        identity_spec=IdentitySpec(property_names=("company_id",)),
        properties=(duplicate_property,),
    )
    with pytest.raises(ValidationError, match="property IDs must be unique"):
        OntologyDefinition(name="Commerce", object_types=(first, company))


def test_explicit_validator_rejects_wrong_boundary_type() -> None:
    with pytest.raises(SchemaError) as caught:
        SchemaValidator.validate({"name": "not-a-model"})

    assert caught.value.context == {"received_type": "dict"}

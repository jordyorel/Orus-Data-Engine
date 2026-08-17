from decimal import Decimal
from uuid import uuid4

import pytest

from orus_ontology import (
    IdentityNormalizer,
    IdentitySpec,
    MappingDefinition,
    ObjectMapping,
    ObjectType,
    OntologyDefinition,
    OntologyStatus,
    PropertyMapping,
    PropertyType,
    RelationMapping,
    RelationType,
    SourceContract,
    SourceField,
    TransformName,
    ValueType,
)


@pytest.fixture
def ontology() -> OntologyDefinition:
    customer = ObjectType(
        name="Customer",
        identity_spec=IdentitySpec(
            property_names=("customer_id",),
            normalizers=(IdentityNormalizer.TRIM, IdentityNormalizer.UPPERCASE),
        ),
        properties=(
            PropertyType(
                name="customer_id",
                value_type=ValueType.STRING,
                required=True,
                nullable=False,
                unique=True,
            ),
            PropertyType(name="name", value_type=ValueType.STRING),
        ),
    )
    email = ObjectType(
        name="EmailAddress",
        identity_spec=IdentitySpec(
            property_names=("address",),
            normalizers=(IdentityNormalizer.TRIM, IdentityNormalizer.LOWERCASE),
        ),
        properties=(
            PropertyType(
                name="address",
                value_type=ValueType.STRING,
                required=True,
                nullable=False,
                unique=True,
            ),
        ),
    )
    owns_email = RelationType(
        name="OWNS_EMAIL",
        source_type_id=customer.type_id,
        target_type_id=email.type_id,
        properties=(PropertyType(name="verified", value_type=ValueType.BOOLEAN),),
    )
    return OntologyDefinition(
        ontology_id=uuid4(),
        name="Commerce",
        version=1,
        status=OntologyStatus.PUBLISHED,
        object_types=(customer, email),
        relation_types=(owns_email,),
    )


@pytest.fixture
def source_contract() -> SourceContract:
    return SourceContract(
        name="customers_clean_v1",
        version=1,
        fields=(
            SourceField(name="customer_id", value_type=ValueType.STRING, nullable=False),
            SourceField(name="customer_name", value_type=ValueType.STRING),
            SourceField(name="email", value_type=ValueType.STRING, nullable=False),
            SourceField(name="email_verified", value_type=ValueType.BOOLEAN),
        ),
    )


@pytest.fixture
def mapping_definition(ontology: OntologyDefinition) -> MappingDefinition:
    return MappingDefinition(
        name="customers_v1",
        version=1,
        ontology_id=ontology.ontology_id,
        ontology_version=ontology.version,
        source_contract="customers_clean_v1",
        source_contract_version=1,
        objects=(
            ObjectMapping(
                alias="customer",
                object_type="Customer",
                properties=(
                    PropertyMapping(
                        target_property="customer_id",
                        source_field="customer_id",
                        transforms=(TransformName.TRIM, TransformName.UPPERCASE),
                    ),
                    PropertyMapping(
                        target_property="name",
                        source_field="customer_name",
                        transforms=(TransformName.TRIM,),
                    ),
                ),
            ),
            ObjectMapping(
                alias="email",
                object_type="EmailAddress",
                properties=(
                    PropertyMapping(
                        target_property="address",
                        source_field="email",
                        transforms=(TransformName.TRIM, TransformName.LOWERCASE),
                    ),
                ),
            ),
        ),
        relations=(
            RelationMapping(
                relation_type="OWNS_EMAIL",
                source_alias="customer",
                target_alias="email",
                properties=(
                    PropertyMapping(
                        target_property="verified",
                        source_field="email_verified",
                    ),
                ),
                confidence=Decimal("1"),
            ),
        ),
    )

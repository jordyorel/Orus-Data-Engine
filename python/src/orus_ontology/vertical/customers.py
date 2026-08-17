"""Stable customer vertical used by the first production-scale ontology flow."""

from decimal import Decimal
from uuid import UUID

from orus_ontology.identity.spec import IdentityNormalizer, IdentitySpec
from orus_ontology.mapping.definition import (
    MappingDefinition,
    ObjectMapping,
    PropertyMapping,
    RelationMapping,
    SourceContract,
    SourceField,
    TransformName,
)
from orus_ontology.metamodel.object_type import ObjectType
from orus_ontology.metamodel.ontology import OntologyDefinition, OntologyStatus
from orus_ontology.metamodel.property_type import PropertyType
from orus_ontology.metamodel.relation_type import RelationType
from orus_ontology.metamodel.value_type import ValueType

ONTOLOGY_ID = UUID("4e4e358d-8618-5c56-a646-d90406883895")
CUSTOMER_TYPE_ID = UUID("c45a055a-b2e7-51c4-99e8-763f5560c312")
EMAIL_TYPE_ID = UUID("cf510978-675d-5e6b-ab2f-8c820891c356")
COMPANY_TYPE_ID = UUID("103f7270-712d-5373-b228-3b50ed1258e6")
OWNS_EMAIL_TYPE_ID = UUID("9846f937-d9cf-5c25-98c8-996872911990")
WORKS_FOR_TYPE_ID = UUID("9062a09b-b6a7-51a8-9647-92775d8a7958")
MAPPING_ID = UUID("8af80d1f-140a-5d42-8344-a86f7416ad71")

RAW_TO_CANONICAL = {
    "Index": "index",
    "Customer Id": "customer_id",
    "First Name": "first_name",
    "Last Name": "last_name",
    "Company": "company",
    "City": "city",
    "Country": "country",
    "Phone 1": "phone_1",
    "Phone 2": "phone_2",
    "Email": "email",
    "Subscription Date": "subscription_date",
    "Website": "website",
}


def customer_ontology() -> OntologyDefinition:
    customer = ObjectType(
        type_id=CUSTOMER_TYPE_ID,
        name="Customer",
        identity_spec=IdentitySpec(
            property_names=("customer_id",),
            normalizers=(IdentityNormalizer.TRIM, IdentityNormalizer.UPPERCASE),
        ),
        properties=(
            PropertyType(
                property_id=UUID("83014472-cf9e-50ce-bf2d-18eeab35be3a"),
                name="customer_id",
                value_type=ValueType.STRING,
                required=True,
                nullable=False,
                unique=True,
            ),
            PropertyType(
                property_id=UUID("57c58b03-5dd6-5bad-9ff9-d3aebdafde3c"),
                name="first_name",
                value_type=ValueType.STRING,
            ),
            PropertyType(
                property_id=UUID("cbe27ccb-1750-598d-8235-b82799b9bd8a"),
                name="last_name",
                value_type=ValueType.STRING,
            ),
            PropertyType(
                property_id=UUID("3c43d884-dd5f-5897-94ac-b17b9a414de2"),
                name="subscription_date",
                value_type=ValueType.DATE,
            ),
        ),
    )
    email = ObjectType(
        type_id=EMAIL_TYPE_ID,
        name="EmailAddress",
        identity_spec=IdentitySpec(
            property_names=("address",),
            normalizers=(IdentityNormalizer.TRIM, IdentityNormalizer.LOWERCASE),
        ),
        properties=(
            PropertyType(
                property_id=UUID("4bdc2d7d-b5b7-55c3-8ebf-25f981d3eefc"),
                name="address",
                value_type=ValueType.STRING,
                required=True,
                nullable=False,
                unique=True,
            ),
        ),
    )
    company = ObjectType(
        type_id=COMPANY_TYPE_ID,
        name="Company",
        identity_spec=IdentitySpec(
            property_names=("name",),
            normalizers=(IdentityNormalizer.TRIM, IdentityNormalizer.UPPERCASE),
        ),
        properties=(
            PropertyType(
                property_id=UUID("9ab9c959-6295-5663-95dc-bd9249722b62"),
                name="name",
                value_type=ValueType.STRING,
                required=True,
                nullable=False,
            ),
        ),
    )
    return OntologyDefinition(
        ontology_id=ONTOLOGY_ID,
        name="CustomerCommerce",
        version=1,
        status=OntologyStatus.PUBLISHED,
        object_types=(customer, email, company),
        relation_types=(
            RelationType(
                type_id=OWNS_EMAIL_TYPE_ID,
                name="OWNS_EMAIL",
                source_type_id=CUSTOMER_TYPE_ID,
                target_type_id=EMAIL_TYPE_ID,
            ),
            RelationType(
                type_id=WORKS_FOR_TYPE_ID,
                name="WORKS_FOR",
                source_type_id=CUSTOMER_TYPE_ID,
                target_type_id=COMPANY_TYPE_ID,
            ),
        ),
    )


def customer_source_contract() -> SourceContract:
    return SourceContract(
        name="customers_csv_v1",
        version=1,
        fields=(
            SourceField(name="index", value_type=ValueType.INTEGER, nullable=False),
            SourceField(name="customer_id", value_type=ValueType.STRING, nullable=False),
            SourceField(name="first_name", value_type=ValueType.STRING, nullable=False),
            SourceField(name="last_name", value_type=ValueType.STRING, nullable=False),
            SourceField(name="company", value_type=ValueType.STRING, nullable=False),
            SourceField(name="city", value_type=ValueType.STRING, nullable=False),
            SourceField(name="country", value_type=ValueType.STRING, nullable=False),
            SourceField(name="phone_1", value_type=ValueType.STRING, nullable=False),
            SourceField(name="phone_2", value_type=ValueType.STRING, nullable=False),
            SourceField(name="email", value_type=ValueType.STRING, nullable=False),
            SourceField(name="subscription_date", value_type=ValueType.DATE, nullable=False),
            SourceField(name="website", value_type=ValueType.STRING, nullable=False),
        ),
    )


def customer_mapping() -> MappingDefinition:
    return MappingDefinition(
        mapping_id=MAPPING_ID,
        name="customers_vertical_v1",
        version=1,
        ontology_id=ONTOLOGY_ID,
        ontology_version=1,
        source_contract="customers_csv_v1",
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
                    PropertyMapping(target_property="first_name", source_field="first_name"),
                    PropertyMapping(target_property="last_name", source_field="last_name"),
                    PropertyMapping(
                        target_property="subscription_date",
                        source_field="subscription_date",
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
            ObjectMapping(
                alias="company",
                object_type="Company",
                properties=(
                    PropertyMapping(
                        target_property="name",
                        source_field="company",
                        transforms=(TransformName.TRIM, TransformName.UPPERCASE),
                    ),
                ),
            ),
        ),
        relations=(
            RelationMapping(
                relation_type="OWNS_EMAIL",
                source_alias="customer",
                target_alias="email",
                confidence=Decimal("1"),
            ),
            RelationMapping(
                relation_type="WORKS_FOR",
                source_alias="customer",
                target_alias="company",
                confidence=Decimal("1"),
            ),
        ),
    )

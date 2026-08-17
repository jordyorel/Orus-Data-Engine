from uuid import uuid4

import pytest

from orus_ontology import (
    MappingCompiler,
    MappingDefinition,
    MappingError,
    ObjectMapping,
    OntologyDefinition,
    PropertyMapping,
    SourceContract,
)


def test_compiler_resolves_schema_objects_and_properties(
    ontology: OntologyDefinition,
    source_contract: SourceContract,
    mapping_definition: MappingDefinition,
) -> None:
    plan = MappingCompiler.compile(mapping_definition, ontology, source_contract)

    assert plan.ontology is ontology
    assert plan.objects[0].object_type.name == "Customer"
    assert plan.objects[0].properties[0].target_property.name == "customer_id"
    assert plan.relations[0].relation_type.name == "OWNS_EMAIL"
    assert plan.relations[0].source_alias == "customer"


def test_compiler_rejects_wrong_ontology_and_contract_versions(
    ontology: OntologyDefinition,
    source_contract: SourceContract,
    mapping_definition: MappingDefinition,
) -> None:
    wrong_ontology = MappingDefinition.model_validate(
        {**mapping_definition.model_dump(), "ontology_id": uuid4()}
    )
    with pytest.raises(MappingError, match="different ontology"):
        MappingCompiler.compile(wrong_ontology, ontology, source_contract)

    wrong_contract = MappingDefinition.model_validate(
        {**mapping_definition.model_dump(), "source_contract_version": 2}
    )
    with pytest.raises(MappingError, match="version does not match"):
        MappingCompiler.compile(wrong_contract, ontology, source_contract)


def test_compiler_rejects_missing_identity_and_unknown_fields(
    ontology: OntologyDefinition,
    source_contract: SourceContract,
    mapping_definition: MappingDefinition,
) -> None:
    customer_without_identity = ObjectMapping(
        alias="customer",
        object_type="Customer",
        properties=(PropertyMapping(target_property="name", source_field="customer_name"),),
    )
    missing_identity = MappingDefinition.model_validate(
        {
            **mapping_definition.model_dump(),
            "objects": (customer_without_identity, mapping_definition.objects[1]),
        }
    )
    with pytest.raises(MappingError, match="identity property"):
        MappingCompiler.compile(missing_identity, ontology, source_contract)

    unknown_source = ObjectMapping(
        alias="customer",
        object_type="Customer",
        properties=(PropertyMapping(target_property="customer_id", source_field="unknown_field"),),
    )
    invalid_source = MappingDefinition.model_validate(
        {
            **mapping_definition.model_dump(),
            "objects": (unknown_source, mapping_definition.objects[1]),
        }
    )
    with pytest.raises(MappingError, match="unknown source field"):
        MappingCompiler.compile(invalid_source, ontology, source_contract)


def test_compiler_rejects_relation_alias_type_mismatch(
    ontology: OntologyDefinition,
    source_contract: SourceContract,
    mapping_definition: MappingDefinition,
) -> None:
    relation = mapping_definition.relations[0]
    reversed_relation = relation.model_copy(
        update={"source_alias": "email", "target_alias": "customer"}
    )
    invalid = MappingDefinition.model_validate(
        {**mapping_definition.model_dump(), "relations": (reversed_relation,)}
    )

    with pytest.raises(MappingError, match="source alias has an incompatible"):
        MappingCompiler.compile(invalid, ontology, source_contract)

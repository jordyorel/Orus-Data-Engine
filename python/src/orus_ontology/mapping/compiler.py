"""Compile declarative mappings into validated immutable execution plans."""

from orus_ontology.errors import MappingError
from orus_ontology.mapping.definition import (
    MappingDefinition,
    ObjectMapping,
    PropertyMapping,
    RelationMapping,
    SourceContract,
    SourceField,
)
from orus_ontology.mapping.plan import (
    CompiledObjectMapping,
    CompiledPropertyMapping,
    CompiledRelationMapping,
    MappingPlan,
)
from orus_ontology.metamodel.object_type import ObjectType
from orus_ontology.metamodel.ontology import OntologyDefinition, OntologyStatus
from orus_ontology.metamodel.property_type import PropertyType
from orus_ontology.metamodel.relation_type import RelationType
from orus_ontology.metamodel.value_type import ValueType


class MappingCompiler:
    """Resolve every schema name and compatibility check before execution."""

    @staticmethod
    def compile(
        definition: MappingDefinition,
        ontology: OntologyDefinition,
        source_contract: SourceContract,
    ) -> MappingPlan:
        _validate_contract_identity(definition, ontology, source_contract)
        compiled_objects = tuple(
            _compile_object(mapping, ontology, source_contract) for mapping in definition.objects
        )
        objects_by_alias = {mapping.alias: mapping for mapping in compiled_objects}
        compiled_relations = tuple(
            _compile_relation(mapping, ontology, source_contract, objects_by_alias)
            for mapping in definition.relations
        )
        return MappingPlan(
            definition=definition,
            ontology=ontology,
            source_contract=source_contract,
            objects=compiled_objects,
            relations=compiled_relations,
            error_policy=definition.error_policy,
        )


def _validate_contract_identity(
    definition: MappingDefinition,
    ontology: OntologyDefinition,
    source_contract: SourceContract,
) -> None:
    if ontology.status is not OntologyStatus.PUBLISHED:
        raise MappingError("mapping compilation requires a published ontology")
    if definition.ontology_id != ontology.ontology_id:
        raise MappingError("mapping targets a different ontology")
    if definition.ontology_version != ontology.version:
        raise MappingError("mapping ontology version does not match schema version")
    if definition.source_contract != source_contract.name:
        raise MappingError("mapping source contract name does not match")
    if definition.source_contract_version != source_contract.version:
        raise MappingError("mapping source contract version does not match")


def _compile_object(
    mapping: ObjectMapping,
    ontology: OntologyDefinition,
    source_contract: SourceContract,
) -> CompiledObjectMapping:
    object_type = ontology.get_object_type(mapping.object_type)
    if object_type is None:
        raise MappingError(
            "object mapping references an unknown object type",
            context={"alias": mapping.alias, "object_type": mapping.object_type},
        )
    properties = tuple(
        _compile_property(item, object_type, source_contract) for item in mapping.properties
    )
    mapped_names = {item.target_property.name for item in properties}
    missing_identity = set(object_type.identity_spec.property_names) - mapped_names
    if missing_identity:
        raise MappingError(
            "object mapping does not provide every identity property",
            context={"alias": mapping.alias, "missing": tuple(sorted(missing_identity))},
        )
    return CompiledObjectMapping(
        alias=mapping.alias,
        object_type=object_type,
        properties=properties,
    )


def _compile_property(
    mapping: PropertyMapping,
    owner: ObjectType | RelationType,
    source_contract: SourceContract,
) -> CompiledPropertyMapping:
    target = owner.get_property(mapping.target_property)
    if target is None:
        raise MappingError(
            "property mapping references an unknown target property",
            context={"owner": owner.name, "property": mapping.target_property},
        )
    source = source_contract.get_field(mapping.source_field)
    if source is None:
        raise MappingError(
            "property mapping references an unknown source field",
            context={"source_field": mapping.source_field},
        )
    _validate_type_compatibility(source, target)
    if mapping.transforms and source.value_type is not ValueType.STRING:
        raise MappingError(
            "string transforms require a string source field",
            context={"source_field": source.name},
        )
    return CompiledPropertyMapping(
        source_field=source.name,
        target_property=target,
        transforms=mapping.transforms,
    )


def _compile_relation(
    mapping: RelationMapping,
    ontology: OntologyDefinition,
    source_contract: SourceContract,
    objects_by_alias: dict[str, CompiledObjectMapping],
) -> CompiledRelationMapping:
    relation_type = ontology.get_relation_type(mapping.relation_type)
    if relation_type is None:
        raise MappingError(
            "relation mapping references an unknown relation type",
            context={"relation_type": mapping.relation_type},
        )
    source = objects_by_alias.get(mapping.source_alias)
    target = objects_by_alias.get(mapping.target_alias)
    if source is None or target is None:
        raise MappingError("relation mapping references an unknown object alias")
    if source.object_type.type_id != relation_type.source_type_id:
        raise MappingError("relation source alias has an incompatible object type")
    if target.object_type.type_id != relation_type.target_type_id:
        raise MappingError("relation target alias has an incompatible object type")
    confidence = mapping.confidence
    if confidence < 0 or confidence > 1:
        raise MappingError("relation confidence must be between 0 and 1")
    properties = tuple(
        _compile_property(item, relation_type, source_contract) for item in mapping.properties
    )
    return CompiledRelationMapping(
        relation_type=relation_type,
        source_alias=source.alias,
        target_alias=target.alias,
        properties=properties,
        confidence=confidence,
    )


def _validate_type_compatibility(source: SourceField, target: PropertyType) -> None:
    allowed_sources = {
        ValueType.STRING: {ValueType.STRING},
        ValueType.INTEGER: {ValueType.INTEGER},
        ValueType.DECIMAL: {ValueType.DECIMAL, ValueType.INTEGER, ValueType.STRING},
        ValueType.BOOLEAN: {ValueType.BOOLEAN},
        ValueType.DATE: {ValueType.DATE, ValueType.STRING},
        ValueType.DATETIME: {ValueType.DATETIME, ValueType.STRING},
        ValueType.ENUM: {ValueType.STRING, ValueType.INTEGER},
        ValueType.REFERENCE: {ValueType.REFERENCE, ValueType.STRING},
        ValueType.JSON: {ValueType.JSON},
    }[target.value_type]
    if source.value_type not in allowed_sources:
        raise MappingError(
            "source and target property types are incompatible",
            context={
                "source_field": source.name,
                "source_type": source.value_type.value,
                "target_property": target.name,
                "target_type": target.value_type.value,
            },
        )
    if not target.nullable and source.nullable and target.default_value is None:
        raise MappingError(
            "nullable source cannot feed a non-nullable property without a default",
            context={"source_field": source.name, "target_property": target.name},
        )

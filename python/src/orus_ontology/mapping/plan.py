"""Immutable execution plan produced by the mapping compiler."""

from decimal import Decimal

from orus_ontology._schema import ImmutableModel
from orus_ontology.mapping.definition import (
    MappingDefinition,
    RecordErrorPolicy,
    SourceContract,
    TransformName,
)
from orus_ontology.metamodel.object_type import ObjectType
from orus_ontology.metamodel.ontology import OntologyDefinition
from orus_ontology.metamodel.property_type import PropertyType
from orus_ontology.metamodel.relation_type import RelationType


class CompiledPropertyMapping(ImmutableModel):
    source_field: str
    target_property: PropertyType
    transforms: tuple[TransformName, ...] = ()


class CompiledObjectMapping(ImmutableModel):
    alias: str
    object_type: ObjectType
    properties: tuple[CompiledPropertyMapping, ...]


class CompiledRelationMapping(ImmutableModel):
    relation_type: RelationType
    source_alias: str
    target_alias: str
    properties: tuple[CompiledPropertyMapping, ...]
    confidence: Decimal


class MappingPlan(ImmutableModel):
    definition: MappingDefinition
    ontology: OntologyDefinition
    source_contract: SourceContract
    objects: tuple[CompiledObjectMapping, ...]
    relations: tuple[CompiledRelationMapping, ...]
    error_policy: RecordErrorPolicy

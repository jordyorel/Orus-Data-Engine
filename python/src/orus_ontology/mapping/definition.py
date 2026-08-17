"""Declarative source and ontology mapping definitions."""

from decimal import Decimal
from enum import StrEnum
from uuid import UUID, uuid4

from pydantic import Field, field_validator, model_validator

from orus_ontology._schema import SchemaModel, validate_technical_name
from orus_ontology.metamodel.value_type import ValueType


class TransformName(StrEnum):
    TRIM = "trim"
    LOWERCASE = "lowercase"
    UPPERCASE = "uppercase"


class RecordErrorPolicy(StrEnum):
    REJECT = "reject"
    QUARANTINE = "quarantine"


class SourceField(SchemaModel):
    name: str
    value_type: ValueType
    required: bool = True
    nullable: bool = True

    @field_validator("name")
    @classmethod
    def validate_name(cls, value: str) -> str:
        return validate_technical_name(value, field_name="source field name")


class SourceContract(SchemaModel):
    name: str
    version: int = Field(ge=1)
    fields: tuple[SourceField, ...]

    @field_validator("name")
    @classmethod
    def validate_name(cls, value: str) -> str:
        return validate_technical_name(value, field_name="source contract name")

    @model_validator(mode="after")
    def unique_fields(self) -> "SourceContract":
        names = [field.name for field in self.fields]
        if len(names) != len(set(names)):
            raise ValueError("source field names must be unique")
        return self

    def get_field(self, name: str) -> SourceField | None:
        return next((field for field in self.fields if field.name == name), None)


class PropertyMapping(SchemaModel):
    target_property: str
    source_field: str
    transforms: tuple[TransformName, ...] = ()

    @field_validator("target_property", "source_field")
    @classmethod
    def validate_names(cls, value: str) -> str:
        return validate_technical_name(value, field_name="mapping field name")

    @field_validator("transforms")
    @classmethod
    def validate_transforms(cls, values: tuple[TransformName, ...]) -> tuple[TransformName, ...]:
        if len(values) != len(set(values)):
            raise ValueError("property transforms must be unique")
        if TransformName.LOWERCASE in values and TransformName.UPPERCASE in values:
            raise ValueError("property mapping cannot lowercase and uppercase together")
        return values


class ObjectMapping(SchemaModel):
    alias: str
    object_type: str
    properties: tuple[PropertyMapping, ...]

    @field_validator("alias", "object_type")
    @classmethod
    def validate_names(cls, value: str) -> str:
        return validate_technical_name(value, field_name="object mapping name")

    @model_validator(mode="after")
    def unique_targets(self) -> "ObjectMapping":
        targets = [mapping.target_property for mapping in self.properties]
        if len(targets) != len(set(targets)):
            raise ValueError("object mapping target properties must be unique")
        return self


class RelationMapping(SchemaModel):
    relation_type: str
    source_alias: str
    target_alias: str
    properties: tuple[PropertyMapping, ...] = ()
    confidence: Decimal = Decimal("1")

    @field_validator("relation_type", "source_alias", "target_alias")
    @classmethod
    def validate_names(cls, value: str) -> str:
        return validate_technical_name(value, field_name="relation mapping name")

    @field_validator("confidence", mode="before")
    @classmethod
    def reject_float_confidence(cls, value: object) -> object:
        if isinstance(value, float | bool):
            raise ValueError("relation confidence must use an exact decimal value")
        return value

    @model_validator(mode="after")
    def unique_targets(self) -> "RelationMapping":
        targets = [mapping.target_property for mapping in self.properties]
        if len(targets) != len(set(targets)):
            raise ValueError("relation mapping target properties must be unique")
        return self


class MappingDefinition(SchemaModel):
    mapping_id: UUID = Field(default_factory=uuid4)
    name: str
    version: int = Field(ge=1)
    ontology_id: UUID
    ontology_version: int = Field(ge=1)
    source_contract: str
    source_contract_version: int = Field(ge=1)
    objects: tuple[ObjectMapping, ...]
    relations: tuple[RelationMapping, ...] = ()
    error_policy: RecordErrorPolicy = RecordErrorPolicy.REJECT

    @field_validator("name", "source_contract")
    @classmethod
    def validate_names(cls, value: str) -> str:
        return validate_technical_name(value, field_name="mapping definition name")

    @model_validator(mode="after")
    def validate_aliases(self) -> "MappingDefinition":
        if not self.objects:
            raise ValueError("mapping definition requires at least one object mapping")
        aliases = [mapping.alias for mapping in self.objects]
        if len(aliases) != len(set(aliases)):
            raise ValueError("object mapping aliases must be unique")
        return self

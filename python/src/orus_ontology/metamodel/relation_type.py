"""Semantic relation type declarations."""

from enum import StrEnum
from uuid import UUID, uuid4

from pydantic import Field, field_validator, model_validator

from orus_ontology._schema import SchemaModel, validate_technical_name
from orus_ontology.metamodel.property_type import PropertyType
from orus_ontology.metamodel.validator import validate_unique_properties


class RelationCardinality(StrEnum):
    ONE_TO_ONE = "one_to_one"
    ONE_TO_MANY = "one_to_many"
    MANY_TO_ONE = "many_to_one"
    MANY_TO_MANY = "many_to_many"


class RelationType(SchemaModel):
    """Versioned definition of a typed edge between two object types."""

    type_id: UUID = Field(default_factory=uuid4)
    name: str
    source_type_id: UUID
    target_type_id: UUID
    directed: bool = True
    cardinality: RelationCardinality = RelationCardinality.MANY_TO_MANY
    temporal: bool = False
    properties: tuple[PropertyType, ...] = ()
    constraints: tuple[str, ...] = ()

    @field_validator("name")
    @classmethod
    def validate_name(cls, name: str) -> str:
        return validate_technical_name(name, field_name="relation type name")

    @model_validator(mode="after")
    def validate_properties(self) -> "RelationType":
        validate_unique_properties(self.properties, owner=self.name)
        return self

    def get_property(self, name: str) -> PropertyType | None:
        return next((prop for prop in self.properties if prop.name == name), None)

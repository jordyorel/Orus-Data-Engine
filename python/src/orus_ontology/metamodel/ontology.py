"""Root ontology schema definition and cross-type invariants."""

from enum import StrEnum
from uuid import UUID, uuid4

from pydantic import Field, field_validator, model_validator

from orus_ontology._schema import SchemaModel, validate_technical_name
from orus_ontology.metamodel.object_type import ObjectType
from orus_ontology.metamodel.relation_type import RelationType
from orus_ontology.metamodel.validator import validate_unique_ids
from orus_ontology.metamodel.value_type import ValueType


class OntologyStatus(StrEnum):
    DRAFT = "draft"
    PUBLISHED = "published"
    RETIRED = "retired"


class OntologyDefinition(SchemaModel):
    """Complete, self-validating snapshot of an ontology schema."""

    ontology_id: UUID = Field(default_factory=uuid4)
    name: str
    version: int = Field(default=1, ge=1)
    status: OntologyStatus = OntologyStatus.DRAFT
    object_types: tuple[ObjectType, ...]
    relation_types: tuple[RelationType, ...] = ()
    constraints: tuple[str, ...] = ()

    @field_validator("name")
    @classmethod
    def validate_name(cls, name: str) -> str:
        return validate_technical_name(name, field_name="ontology name")

    @model_validator(mode="after")
    def validate_graph_schema(self) -> "OntologyDefinition":
        object_ids = [item.type_id for item in self.object_types]
        relation_ids = [item.type_id for item in self.relation_types]
        validate_unique_ids(object_ids, label="object type")
        validate_unique_ids(relation_ids, label="relation type")

        object_names = [item.name for item in self.object_types]
        relation_names = [item.name for item in self.relation_types]
        if len(object_names) != len(set(object_names)):
            raise ValueError("object type names must be unique")
        if len(relation_names) != len(set(relation_names)):
            raise ValueError("relation type names must be unique")

        known_object_ids = set(object_ids)
        property_ids: list[UUID] = []
        for object_type in self.object_types:
            property_ids.extend(prop.property_id for prop in object_type.properties)
            for prop in object_type.properties:
                if (
                    prop.value_type is ValueType.REFERENCE
                    and prop.reference_type_id not in known_object_ids
                ):
                    raise ValueError(
                        f"property '{object_type.name}.{prop.name}' references an unknown "
                        "object type"
                    )

        for relation_type in self.relation_types:
            property_ids.extend(prop.property_id for prop in relation_type.properties)
            if relation_type.source_type_id not in known_object_ids:
                raise ValueError(f"relation '{relation_type.name}' has an unknown source type")
            if relation_type.target_type_id not in known_object_ids:
                raise ValueError(f"relation '{relation_type.name}' has an unknown target type")

        validate_unique_ids(property_ids, label="property")
        return self

    def get_object_type(self, key: UUID | str) -> ObjectType | None:
        return next(
            (item for item in self.object_types if item.type_id == key or item.name == key),
            None,
        )

    def get_relation_type(self, key: UUID | str) -> RelationType | None:
        return next(
            (item for item in self.relation_types if item.type_id == key or item.name == key),
            None,
        )

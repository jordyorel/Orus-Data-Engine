"""Semantic object type declarations."""

from uuid import UUID, uuid4

from pydantic import Field, field_validator, model_validator

from orus_ontology._schema import SchemaModel, validate_technical_name
from orus_ontology.identity.spec import IdentitySpec
from orus_ontology.metamodel.property_type import PropertyType
from orus_ontology.metamodel.validator import validate_unique_properties


class ObjectType(SchemaModel):
    """Versioned definition of a business entity class."""

    type_id: UUID = Field(default_factory=uuid4)
    name: str
    display_name: str | None = None
    description: str | None = None
    version: int = Field(default=1, ge=1)
    identity_spec: IdentitySpec
    properties: tuple[PropertyType, ...]
    constraints: tuple[str, ...] = ()

    @field_validator("name")
    @classmethod
    def validate_name(cls, name: str) -> str:
        return validate_technical_name(name, field_name="object type name")

    @field_validator("display_name", "description")
    @classmethod
    def reject_blank_text(cls, value: str | None) -> str | None:
        if value is not None and not value.strip():
            raise ValueError("text fields must not be blank")
        return value

    @model_validator(mode="after")
    def validate_properties(self) -> "ObjectType":
        validate_unique_properties(self.properties, owner=self.name)
        by_name = {prop.name: prop for prop in self.properties}
        for name in self.identity_spec.property_names:
            prop = by_name.get(name)
            if prop is None:
                raise ValueError(f"identity property '{name}' is not declared")
            if not prop.required or prop.nullable:
                raise ValueError(f"identity property '{name}' must be required and non-nullable")
        return self

    def get_property(self, name: str) -> PropertyType | None:
        return next((prop for prop in self.properties if prop.name == name), None)

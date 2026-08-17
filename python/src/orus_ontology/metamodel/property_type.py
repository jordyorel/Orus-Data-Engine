"""Semantic property declarations and their local constraints."""

import re
from datetime import date, datetime
from decimal import Decimal
from enum import StrEnum
from typing import cast
from uuid import UUID, uuid4

from pydantic import Field, field_serializer, field_validator, model_validator

from orus_ontology._schema import SchemaModel, freeze_json, thaw_json, validate_technical_name
from orus_ontology.metamodel.value_type import ValueType


class PropertyCardinality(StrEnum):
    ONE = "one"
    MANY = "many"


class PropertyConstraints(SchemaModel):
    """Optional constraints applicable to a semantic property."""

    min_length: int | None = Field(default=None, ge=0)
    max_length: int | None = Field(default=None, ge=0)
    pattern: str | None = None
    minimum: Decimal | None = None
    maximum: Decimal | None = None
    enum_values: tuple[str | int, ...] = ()

    @field_validator("minimum", "maximum", mode="before")
    @classmethod
    def reject_inexact_numeric_bound(cls, value: object) -> object:
        if isinstance(value, float | bool):
            raise ValueError("numeric bounds must use Decimal, integer, or decimal text")
        return value

    @model_validator(mode="after")
    def validate_ranges(self) -> "PropertyConstraints":
        if (
            self.min_length is not None
            and self.max_length is not None
            and self.min_length > self.max_length
        ):
            raise ValueError("min_length must not exceed max_length")
        if self.minimum is not None and self.maximum is not None and self.minimum > self.maximum:
            raise ValueError("minimum must not exceed maximum")
        if len(self.enum_values) != len(set(self.enum_values)):
            raise ValueError("enum constraint values must be unique")
        if self.pattern is not None:
            try:
                re.compile(self.pattern)
            except re.error as error:
                raise ValueError(f"invalid property pattern: {error}") from error
        return self


class PropertyType(SchemaModel):
    """A named, typed property belonging to an object or relation type."""

    property_id: UUID = Field(default_factory=uuid4)
    name: str
    value_type: ValueType
    required: bool = False
    nullable: bool = True
    unique: bool = False
    cardinality: PropertyCardinality = PropertyCardinality.ONE
    default_value: object | None = None
    reference_type_id: UUID | None = None
    constraints: PropertyConstraints = Field(default_factory=PropertyConstraints)

    @field_validator("name")
    @classmethod
    def validate_name(cls, name: str) -> str:
        return validate_technical_name(name, field_name="property name")

    @field_validator("default_value", mode="before")
    @classmethod
    def freeze_default(cls, value: object) -> object:
        if isinstance(value, dict | list | tuple):
            return freeze_json(cast(object, value))
        return value

    @field_serializer("default_value")
    def serialize_default(self, value: object | None) -> object:
        return thaw_json(value)

    @model_validator(mode="after")
    def validate_definition(self) -> "PropertyType":
        if self.value_type is ValueType.REFERENCE and self.reference_type_id is None:
            raise ValueError("reference property requires reference_type_id")
        if self.value_type is not ValueType.REFERENCE and self.reference_type_id is not None:
            raise ValueError("reference_type_id is only valid for reference properties")
        if self.value_type is ValueType.ENUM and not self.constraints.enum_values:
            raise ValueError("enum property requires at least one enum value")
        if self.value_type is not ValueType.ENUM and self.constraints.enum_values:
            raise ValueError("enum values are only valid for enum properties")
        has_length_constraint = (
            self.constraints.min_length is not None
            or self.constraints.max_length is not None
            or self.constraints.pattern is not None
        )
        if has_length_constraint and self.value_type is not ValueType.STRING:
            raise ValueError("length and pattern constraints are only valid for string properties")
        has_numeric_constraint = (
            self.constraints.minimum is not None or self.constraints.maximum is not None
        )
        if has_numeric_constraint and self.value_type not in (ValueType.INTEGER, ValueType.DECIMAL):
            raise ValueError("numeric constraints are only valid for integer or decimal properties")
        if self.default_value is None:
            if not self.nullable:
                return self
        else:
            default_value = self.default_value
            if self.cardinality is PropertyCardinality.MANY:
                if not isinstance(default_value, tuple):
                    raise ValueError("a many-valued property default must be a collection")
                for item in cast(tuple[object, ...], default_value):
                    self._validate_default_value(item)
            else:
                self._validate_default_value(default_value)
        return self

    def _validate_default_value(self, value: object) -> None:
        valid = {
            ValueType.STRING: isinstance(value, str),
            ValueType.INTEGER: isinstance(value, int) and not isinstance(value, bool),
            ValueType.DECIMAL: isinstance(value, Decimal | int) and not isinstance(value, bool),
            ValueType.BOOLEAN: isinstance(value, bool),
            ValueType.DATE: isinstance(value, date) and not isinstance(value, datetime),
            ValueType.DATETIME: isinstance(value, datetime),
            ValueType.ENUM: value in self.constraints.enum_values,
            ValueType.REFERENCE: isinstance(value, UUID),
            ValueType.JSON: self._is_json_value(value),
        }[self.value_type]
        if not valid:
            raise ValueError(f"default value is incompatible with value type '{self.value_type}'")

    @staticmethod
    def _is_json_value(value: object) -> bool:
        try:
            freeze_json(value)
        except (TypeError, ValueError):
            return False
        return not isinstance(value, Decimal | date | datetime | UUID)

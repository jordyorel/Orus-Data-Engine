"""Typed and fully applied object-property filters."""

from enum import StrEnum
from uuid import UUID

from pydantic import Field, field_validator

from orus_ontology._schema import ImmutableModel, validate_technical_name


class FilterOperator(StrEnum):
    EQUALS = "equals"
    NOT_EQUALS = "not_equals"
    LESS_THAN = "less_than"
    LESS_THAN_OR_EQUAL = "less_than_or_equal"
    GREATER_THAN = "greater_than"
    GREATER_THAN_OR_EQUAL = "greater_than_or_equal"
    CONTAINS = "contains"
    IN = "in"


class PropertyFilter(ImmutableModel):
    predicate: str
    operator: FilterOperator = FilterOperator.EQUALS
    value: object

    @field_validator("predicate")
    @classmethod
    def validate_predicate(cls, value: str) -> str:
        return validate_technical_name(value, field_name="query predicate")


class ObjectQuery(ImmutableModel):
    object_type_id: UUID | None = None
    filters: tuple[PropertyFilter, ...] = ()
    limit: int = Field(default=100, ge=1, le=10_000)
    offset: int = Field(default=0, ge=0)

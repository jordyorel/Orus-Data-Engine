"""Typed, immutable, and traceable ontology assertions."""

from collections.abc import Mapping
from datetime import date, datetime
from decimal import Decimal, InvalidOperation
from enum import StrEnum
from typing import Annotated, Literal
from uuid import UUID, uuid4

from pydantic import Field, ValidationInfo, field_serializer, field_validator, model_validator

from orus_ontology._schema import (
    ImmutableModel,
    freeze_json,
    thaw_json,
    validate_technical_name,
)
from orus_ontology.assertions.provenance import SourceReference
from orus_ontology.assertions.temporal import TemporalContext
from orus_ontology.metamodel.value_type import ValueType


class AssertionKind(StrEnum):
    OBSERVED = "observed"
    TRANSFORMED = "transformed"
    CORRECTED = "corrected"
    INFERRED = "inferred"


class TargetKind(StrEnum):
    VALUE = "value"
    OBJECT = "object"


class ValueTarget(ImmutableModel):
    """A typed literal target; `None` represents an explicit null assertion."""

    target_kind: Literal[TargetKind.VALUE] = TargetKind.VALUE
    value_type: ValueType
    value: object

    @field_validator("value", mode="before")
    @classmethod
    def parse_typed_value(cls, value: object, info: ValidationInfo) -> object:
        value_type = info.data.get("value_type")
        if not isinstance(value_type, ValueType):
            return value
        if value is None:
            return None
        if value_type is ValueType.DECIMAL:
            if isinstance(value, float | bool):
                raise ValueError("decimal assertion values must not use float or bool")
            try:
                return value if isinstance(value, Decimal) else Decimal(str(value))
            except (InvalidOperation, ValueError) as error:
                raise ValueError("invalid decimal assertion value") from error
        if value_type is ValueType.DATE and isinstance(value, str):
            try:
                return date.fromisoformat(value)
            except ValueError as error:
                raise ValueError("invalid ISO date assertion value") from error
        if value_type is ValueType.DATETIME and isinstance(value, str):
            try:
                return datetime.fromisoformat(value)
            except ValueError as error:
                raise ValueError("invalid ISO datetime assertion value") from error
        if value_type is ValueType.REFERENCE and isinstance(value, str):
            try:
                return UUID(value)
            except ValueError as error:
                raise ValueError("invalid UUID assertion value") from error
        if value_type is ValueType.JSON:
            return freeze_json(value)
        return value

    @field_serializer("value")
    def serialize_value(self, value: object) -> object:
        if isinstance(value, Decimal):
            return str(value)
        if isinstance(value, date | datetime):
            return value.isoformat()
        if isinstance(value, UUID):
            return str(value)
        return thaw_json(value)

    @model_validator(mode="after")
    def validate_typed_value(self) -> "ValueTarget":
        if self.value is None:
            return self
        value = self.value
        valid = {
            ValueType.STRING: isinstance(value, str),
            ValueType.INTEGER: isinstance(value, int) and not isinstance(value, bool),
            ValueType.DECIMAL: isinstance(value, Decimal),
            ValueType.BOOLEAN: isinstance(value, bool),
            ValueType.DATE: isinstance(value, date) and not isinstance(value, datetime),
            ValueType.DATETIME: isinstance(value, datetime),
            ValueType.ENUM: isinstance(value, str | int) and not isinstance(value, bool),
            ValueType.REFERENCE: isinstance(value, UUID),
            ValueType.JSON: _is_frozen_json(value),
        }[self.value_type]
        if not valid:
            raise ValueError(f"assertion value is incompatible with type '{self.value_type}'")
        return self


class ObjectTarget(ImmutableModel):
    """Target of an assertion linking the subject to another ontology object."""

    target_kind: Literal[TargetKind.OBJECT] = TargetKind.OBJECT
    object_id: UUID


AssertionTarget = Annotated[ValueTarget | ObjectTarget, Field(discriminator="target_kind")]


class Assertion(ImmutableModel):
    """One versioned fact with provenance, confidence, and temporal semantics."""

    assertion_id: UUID = Field(default_factory=uuid4)
    ontology_id: UUID
    ontology_version: int = Field(ge=1)
    subject_id: UUID
    predicate: str
    target: AssertionTarget
    kind: AssertionKind
    provenance: tuple[SourceReference, ...] = ()
    derived_from_assertion_ids: tuple[UUID, ...] = ()
    confidence: Decimal = Decimal("1")
    temporal: TemporalContext
    mapping_version: int = Field(ge=1)
    rule_id: str | None = None
    supersedes_assertion_id: UUID | None = None

    @field_validator("predicate")
    @classmethod
    def validate_predicate(cls, value: str) -> str:
        return validate_technical_name(value, field_name="assertion predicate")

    @field_validator("confidence", mode="before")
    @classmethod
    def parse_confidence(cls, value: object) -> object:
        if isinstance(value, float | bool):
            raise ValueError("confidence must use Decimal, integer, or decimal text")
        return value

    @field_validator("rule_id")
    @classmethod
    def reject_blank_rule_id(cls, value: str | None) -> str | None:
        if value is not None and not value.strip():
            raise ValueError("rule_id must not be blank")
        return value

    @field_validator("provenance")
    @classmethod
    def unique_provenance(cls, values: tuple[SourceReference, ...]) -> tuple[SourceReference, ...]:
        for index, value in enumerate(values):
            if any(value == earlier for earlier in values[:index]):
                raise ValueError("provenance references must be unique")
        return values

    @field_validator("derived_from_assertion_ids")
    @classmethod
    def unique_derived_assertions(cls, values: tuple[UUID, ...]) -> tuple[UUID, ...]:
        if len(values) != len(set(values)):
            raise ValueError("derived assertion IDs must be unique")
        return values

    @model_validator(mode="after")
    def validate_semantics(self) -> "Assertion":
        if self.confidence < 0 or self.confidence > 1:
            raise ValueError("confidence must be between 0 and 1")
        if self.kind is AssertionKind.INFERRED:
            if self.rule_id is None:
                raise ValueError("inferred assertion requires rule_id")
            if not self.derived_from_assertion_ids:
                raise ValueError("inferred assertion requires source assertion IDs")
        elif self.rule_id is not None:
            raise ValueError("rule_id is only valid for inferred assertions")
        if self.kind is AssertionKind.OBSERVED and not self.provenance:
            raise ValueError("observed assertion requires direct source provenance")
        has_origin = bool(self.provenance or self.derived_from_assertion_ids)
        if not has_origin:
            raise ValueError("assertion requires provenance or source assertions")
        if self.kind is AssertionKind.CORRECTED:
            if self.supersedes_assertion_id is None:
                raise ValueError("corrected assertion requires supersedes_assertion_id")
        elif self.supersedes_assertion_id is not None:
            raise ValueError("supersedes_assertion_id is only valid for corrected assertions")
        return self


def _is_frozen_json(value: object) -> bool:
    try:
        frozen = freeze_json(value)
    except ValueError:
        return False
    if isinstance(value, Mapping):
        return isinstance(frozen, Mapping)
    return isinstance(value, str | int | float | bool | tuple) or value is None

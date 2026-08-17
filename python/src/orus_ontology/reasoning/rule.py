"""Declarative, immutable contracts for controlled inference rules."""

from decimal import Decimal
from enum import StrEnum
from uuid import UUID

from pydantic import Field, field_validator, model_validator

from orus_ontology._schema import ImmutableModel, validate_technical_name
from orus_ontology.metamodel.value_type import ValueType


class ConditionOperator(StrEnum):
    EXISTS = "exists"
    EQUALS = "equals"
    NOT_EQUALS = "not_equals"


class RuleCondition(ImmutableModel):
    predicate: str
    operator: ConditionOperator = ConditionOperator.EXISTS
    value: object | None = None

    @field_validator("predicate")
    @classmethod
    def validate_predicate(cls, value: str) -> str:
        return validate_technical_name(value, field_name="rule condition predicate")

    @model_validator(mode="after")
    def validate_operand(self) -> "RuleCondition":
        if self.operator is ConditionOperator.EXISTS and self.value is not None:
            raise ValueError("exists condition cannot declare a value")
        if self.operator is not ConditionOperator.EXISTS and self.value is None:
            raise ValueError("comparison condition requires a value")
        return self


class RuleConclusion(ImmutableModel):
    predicate: str
    value_type: ValueType
    value: object | None = None
    copy_from_predicate: str | None = None

    @field_validator("predicate", "copy_from_predicate")
    @classmethod
    def validate_predicates(cls, value: str | None) -> str | None:
        if value is None:
            return None
        return validate_technical_name(value, field_name="rule conclusion predicate")

    @model_validator(mode="after")
    def validate_source(self) -> "RuleConclusion":
        if (self.value is None) == (self.copy_from_predicate is None):
            raise ValueError("conclusion requires exactly one literal or copied value")
        return self


class InferenceRule(ImmutableModel):
    rule_id: str
    version: int = Field(default=1, ge=1)
    object_type_id: UUID
    conditions: tuple[RuleCondition, ...] = Field(min_length=1)
    conclusion: RuleConclusion
    confidence: Decimal = Decimal("1")

    @field_validator("rule_id")
    @classmethod
    def validate_rule_id(cls, value: str) -> str:
        return validate_technical_name(value, field_name="rule ID")

    @field_validator("confidence", mode="before")
    @classmethod
    def reject_inexact_confidence(cls, value: object) -> object:
        if isinstance(value, float | bool):
            raise ValueError("rule confidence must use an exact decimal value")
        return value

    @model_validator(mode="after")
    def validate_rule(self) -> "InferenceRule":
        if not 0 <= self.confidence <= 1:
            raise ValueError("rule confidence must be between 0 and 1")
        predicates = [condition.predicate for condition in self.conditions]
        if len(predicates) != len(set(predicates)):
            raise ValueError("rule condition predicates must be unique")
        copied = self.conclusion.copy_from_predicate
        if copied is not None and copied not in predicates:
            raise ValueError("copied conclusion value must reference a condition")
        return self

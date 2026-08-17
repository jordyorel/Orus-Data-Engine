"""Bounded input and output records for ontology materialization."""

from collections.abc import Iterable, Iterator, Mapping, Sequence
from datetime import date, datetime
from decimal import Decimal
from types import MappingProxyType
from typing import cast
from uuid import UUID

from pydantic import BaseModel, ConfigDict, Field, ValidationError, field_validator, model_validator

from orus_ontology._schema import ImmutableModel
from orus_ontology.assertions.assertion import Assertion, ValueTarget
from orus_ontology.assertions.provenance import SourceReference
from orus_ontology.assertions.temporal import TemporalContext, normalize_utc
from orus_ontology.errors import IdentityError, MaterializationError, OntologyError
from orus_ontology.mapping.definition import RecordErrorPolicy
from orus_ontology.mapping.plan import MappingPlan


def _freeze_record_value(value: object) -> object:
    if value is None or isinstance(
        value,
        str | int | float | bool | Decimal | date | datetime | UUID,
    ):
        return value
    if isinstance(value, Mapping):
        mapping = cast(Mapping[object, object], value)
        frozen: dict[str, object] = {}
        for key, item in mapping.items():
            if not isinstance(key, str):
                raise ValueError("canonical record keys must be strings")
            frozen[key] = _freeze_record_value(item)
        return MappingProxyType(frozen)
    if isinstance(value, list | tuple):
        values = cast(Sequence[object], value)
        return tuple(_freeze_record_value(item) for item in values)
    raise ValueError(f"unsupported canonical record value type '{type(value).__name__}'")


class CanonicalRecord(BaseModel):
    """One immutable canonical record and its source provenance."""

    model_config = ConfigDict(frozen=True, extra="forbid", arbitrary_types_allowed=True)

    values: Mapping[str, object]
    source: SourceReference

    @field_validator("values", mode="after")
    @classmethod
    def freeze_values(cls, values: Mapping[str, object]) -> Mapping[str, object]:
        frozen = _freeze_record_value(values)
        return cast(Mapping[str, object], frozen)


class ObjectInstance(ImmutableModel):
    object_id: UUID
    ontology_id: UUID
    ontology_version: int = Field(ge=1)
    object_type_id: UUID
    assertions: tuple[Assertion, ...]

    @model_validator(mode="after")
    def validate_assertions(self) -> "ObjectInstance":
        if not self.assertions:
            raise ValueError("object instance requires at least one assertion")
        for assertion in self.assertions:
            if assertion.subject_id != self.object_id:
                raise ValueError("object assertion subject does not match object ID")
            if (
                assertion.ontology_id != self.ontology_id
                or assertion.ontology_version != self.ontology_version
            ):
                raise ValueError("object assertion ontology does not match instance")
        return self


class RelationInstance(ImmutableModel):
    relation_id: UUID
    ontology_id: UUID
    ontology_version: int = Field(ge=1)
    relation_type_id: UUID
    source_object_id: UUID
    target_object_id: UUID
    confidence: Decimal
    assertions: tuple[Assertion, ...] = ()
    provenance: tuple[SourceReference, ...]
    temporal: TemporalContext

    @field_validator("confidence", mode="before")
    @classmethod
    def reject_inexact_confidence(cls, value: object) -> object:
        if isinstance(value, float | bool):
            raise ValueError("relation confidence must use an exact decimal value")
        return value

    @model_validator(mode="after")
    def validate_assertions(self) -> "RelationInstance":
        for assertion in self.assertions:
            if assertion.subject_id != self.relation_id:
                raise ValueError("relation assertion subject does not match relation ID")
        return self


class QuarantinedRecord(ImmutableModel):
    record: CanonicalRecord
    error_code: str
    message: str
    context: Mapping[str, object] = Field(default_factory=dict)

    @field_validator("context", mode="after")
    @classmethod
    def freeze_context(cls, value: Mapping[str, object]) -> Mapping[str, object]:
        frozen = _freeze_record_value(value)
        return cast(Mapping[str, object], frozen)


class MaterializedBatch(ImmutableModel):
    input_count: int = Field(ge=1)
    objects: tuple[ObjectInstance, ...]
    relations: tuple[RelationInstance, ...]
    quarantined: tuple[QuarantinedRecord, ...] = ()


class BatchMaterializer:
    """Materialize an iterable using fixed-size batches and atomic records."""

    def __init__(self, plan: MappingPlan, *, batch_size: int, recorded_at: datetime) -> None:
        if batch_size < 1:
            raise ValueError("batch_size must be positive")
        self._plan = plan
        self._batch_size = batch_size
        self._recorded_at = normalize_utc(recorded_at)

    def materialize(self, records: Iterable[CanonicalRecord]) -> Iterator[MaterializedBatch]:
        pending: list[CanonicalRecord] = []
        for record in records:
            pending.append(record)
            if len(pending) == self._batch_size:
                yield self._materialize_batch(pending)
                pending.clear()
        if pending:
            yield self._materialize_batch(pending)

    def _materialize_batch(self, records: Sequence[CanonicalRecord]) -> MaterializedBatch:
        from orus_ontology.materialization.object_materializer import materialize_object
        from orus_ontology.materialization.relation_materializer import materialize_relation

        objects: list[ObjectInstance] = []
        relations: list[RelationInstance] = []
        quarantined: list[QuarantinedRecord] = []
        allowed_fields = {field.name for field in self._plan.source_contract.fields}

        for record in records:
            try:
                unknown_fields = set(record.values) - allowed_fields
                if unknown_fields:
                    raise MaterializationError(
                        "record contains fields outside the source contract",
                        context={"fields": tuple(sorted(unknown_fields))},
                    )
                _validate_source_contract(self._plan, record)
                record_objects = {
                    mapping.alias: materialize_object(
                        self._plan,
                        mapping,
                        record,
                        recorded_at=self._recorded_at,
                    )
                    for mapping in self._plan.objects
                }
                record_relations = tuple(
                    materialize_relation(
                        self._plan,
                        mapping,
                        record,
                        record_objects,
                        recorded_at=self._recorded_at,
                    )
                    for mapping in self._plan.relations
                )
            except ValidationError as validation_error:
                error = MaterializationError(
                    "materialized record violates runtime invariants",
                    context={"details": _validation_details(validation_error)},
                )
                if self._plan.error_policy is RecordErrorPolicy.REJECT:
                    raise error from validation_error
                quarantined.append(_quarantine(record, error))
                continue
            except (IdentityError, MaterializationError) as error:
                if self._plan.error_policy is RecordErrorPolicy.REJECT:
                    raise
                quarantined.append(_quarantine(record, error))
                continue

            objects.extend(record_objects.values())
            relations.extend(record_relations)

        return MaterializedBatch(
            input_count=len(records),
            objects=tuple(objects),
            relations=tuple(relations),
            quarantined=tuple(quarantined),
        )


def _quarantine(record: CanonicalRecord, error: OntologyError) -> QuarantinedRecord:
    return QuarantinedRecord(
        record=record,
        error_code=error.code.value,
        message=error.message,
        context=error.context,
    )


def _validate_source_contract(plan: MappingPlan, record: CanonicalRecord) -> None:
    for field in plan.source_contract.fields:
        if field.name not in record.values:
            if field.required:
                raise MaterializationError(
                    "record is missing a required source-contract field",
                    context={"source_field": field.name},
                )
            continue
        value = record.values[field.name]
        if value is None:
            if not field.nullable:
                raise MaterializationError(
                    "non-nullable source-contract field received null",
                    context={"source_field": field.name},
                )
            continue
        try:
            ValueTarget(value_type=field.value_type, value=value)
        except ValidationError as error:
            raise MaterializationError(
                "source-contract field has an incompatible value",
                context={"source_field": field.name, "value_type": field.value_type.value},
            ) from error


def _validation_details(error: ValidationError) -> tuple[dict[str, object], ...]:
    return tuple(
        {
            "location": ".".join(str(part) for part in detail["loc"]),
            "message": detail["msg"],
            "type": detail["type"],
        }
        for detail in error.errors(include_url=False)
    )

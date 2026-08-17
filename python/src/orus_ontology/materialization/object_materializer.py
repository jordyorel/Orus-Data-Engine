"""Materialize one object mapping from one canonical record."""

import re
from collections.abc import Mapping, Sequence
from datetime import datetime
from decimal import Decimal
from typing import cast
from uuid import UUID, uuid5

from pydantic import ValidationError

from orus_ontology.assertions.assertion import (
    Assertion,
    AssertionKind,
    AssertionTarget,
    ObjectTarget,
    ValueTarget,
)
from orus_ontology.assertions.provenance import SourceReference
from orus_ontology.assertions.temporal import TemporalContext
from orus_ontology.errors import MaterializationError
from orus_ontology.identity.generator import IdentityGenerator
from orus_ontology.mapping.definition import TransformName
from orus_ontology.mapping.plan import (
    CompiledObjectMapping,
    CompiledPropertyMapping,
    MappingPlan,
)
from orus_ontology.materialization.batch import CanonicalRecord, ObjectInstance
from orus_ontology.metamodel.property_type import PropertyCardinality, PropertyType
from orus_ontology.metamodel.value_type import ValueType


def materialize_object(
    plan: MappingPlan,
    mapping: CompiledObjectMapping,
    record: CanonicalRecord,
    *,
    recorded_at: datetime,
) -> ObjectInstance:
    mapped_values: dict[str, object] = {}
    for property_mapping in mapping.properties:
        present, value = extract_value(property_mapping, record.values)
        if present:
            mapped_values[property_mapping.target_property.name] = value

    object_id = IdentityGenerator.generate(
        plan.ontology.ontology_id,
        mapping.object_type,
        mapped_values,
    )
    assertions: list[Assertion] = []
    for property_mapping in mapping.properties:
        present, value = extract_value(property_mapping, record.values)
        if not present:
            continue
        targets = materialize_targets(property_mapping.target_property, value)
        used_default = property_mapping.source_field not in record.values
        provenance = property_provenance(
            record.source,
            property_mapping,
            used_default=used_default,
        )
        kind = (
            AssertionKind.TRANSFORMED
            if property_mapping.transforms or property_mapping.source_field not in record.values
            else AssertionKind.OBSERVED
        )
        for index, target in enumerate(targets):
            assertions.append(
                make_assertion(
                    plan,
                    subject_id=object_id,
                    predicate=property_mapping.target_property.name,
                    target=target,
                    kind=kind,
                    provenance=provenance,
                    recorded_at=recorded_at,
                    ordinal=index,
                )
            )
    try:
        return ObjectInstance(
            object_id=object_id,
            ontology_id=plan.ontology.ontology_id,
            ontology_version=plan.ontology.version,
            object_type_id=mapping.object_type.type_id,
            assertions=tuple(assertions),
        )
    except ValidationError as error:
        raise MaterializationError(
            "materialized object violates instance invariants",
            context={"object_alias": mapping.alias},
        ) from error


def extract_value(
    mapping: CompiledPropertyMapping,
    values: Mapping[str, object],
) -> tuple[bool, object]:
    prop = mapping.target_property
    if mapping.source_field not in values:
        if prop.default_value is not None:
            value = prop.default_value
        elif prop.required:
            raise MaterializationError(
                "required source field is missing",
                context={"source_field": mapping.source_field, "property": prop.name},
            )
        else:
            return False, None
    else:
        value = values[mapping.source_field]
    if value is None:
        if not prop.nullable:
            raise MaterializationError(
                "non-nullable property received null",
                context={"source_field": mapping.source_field, "property": prop.name},
            )
        return True, None
    for transform in mapping.transforms:
        if not isinstance(value, str):
            raise MaterializationError(
                "string transform received a non-string value",
                context={"source_field": mapping.source_field, "transform": transform.value},
            )
        if transform is TransformName.TRIM:
            value = value.strip()
        elif transform is TransformName.LOWERCASE:
            value = value.lower()
        elif transform is TransformName.UPPERCASE:
            value = value.upper()
    return True, value


def materialize_targets(prop: PropertyType, value: object) -> tuple[AssertionTarget, ...]:
    if prop.cardinality is PropertyCardinality.MANY:
        if not isinstance(value, Sequence) or isinstance(value, str | bytes):
            raise MaterializationError(
                "many-valued property requires a sequence",
                context={"property": prop.name},
            )
        raw_values = tuple(cast(Sequence[object], value))
    else:
        raw_values = (value,)

    targets: list[AssertionTarget] = []
    for raw_value in raw_values:
        try:
            value_target = ValueTarget(value_type=prop.value_type, value=raw_value)
        except ValidationError as error:
            raise MaterializationError(
                "property value is incompatible with semantic type",
                context={"property": prop.name, "value_type": prop.value_type.value},
            ) from error
        _validate_constraints(prop, value_target.value)
        if prop.value_type is ValueType.REFERENCE and value_target.value is not None:
            targets.append(ObjectTarget(object_id=cast(UUID, value_target.value)))
        else:
            targets.append(value_target)
    return tuple(targets)


def _validate_constraints(prop: PropertyType, value: object) -> None:
    if value is None:
        return
    constraints = prop.constraints
    if isinstance(value, str):
        if constraints.min_length is not None and len(value) < constraints.min_length:
            raise MaterializationError("string value is shorter than minimum length")
        if constraints.max_length is not None and len(value) > constraints.max_length:
            raise MaterializationError("string value exceeds maximum length")
        if constraints.pattern is not None and re.fullmatch(constraints.pattern, value) is None:
            raise MaterializationError("string value does not match required pattern")
    if prop.value_type is ValueType.ENUM and value not in constraints.enum_values:
        raise MaterializationError("enum value is outside its declared domain")
    if isinstance(value, int | Decimal) and not isinstance(value, bool):
        numeric = Decimal(value)
        if constraints.minimum is not None and numeric < constraints.minimum:
            raise MaterializationError("numeric value is below minimum")
        if constraints.maximum is not None and numeric > constraints.maximum:
            raise MaterializationError("numeric value exceeds maximum")


def property_provenance(
    source: SourceReference,
    mapping: CompiledPropertyMapping,
    *,
    used_default: bool,
) -> SourceReference:
    applied = [f"{transform.value}@1" for transform in mapping.transforms]
    if used_default:
        applied.append("default@1")
    transformation_ids = tuple(
        dict.fromkeys(
            (
                *source.transformation_ids,
                *applied,
            )
        )
    )
    return SourceReference(
        source_id=source.source_id,
        source_version=source.source_version,
        batch_id=source.batch_id,
        row_id=source.row_id,
        global_offset=source.global_offset,
        source_column=mapping.source_field,
        run_id=source.run_id,
        transformation_ids=transformation_ids,
        observed_at=source.observed_at,
        checksum=source.checksum,
        metadata=source.metadata,
    )


def make_assertion(
    plan: MappingPlan,
    *,
    subject_id: UUID,
    predicate: str,
    target: AssertionTarget,
    kind: AssertionKind,
    provenance: SourceReference,
    recorded_at: datetime,
    ordinal: int,
) -> Assertion:
    assertion_id = uuid5(
        plan.ontology.ontology_id,
        ":".join(
            (
                "assertion",
                str(plan.definition.mapping_id),
                str(plan.definition.version),
                str(provenance.run_id),
                str(provenance.row_id),
                str(provenance.global_offset),
                str(subject_id),
                predicate,
                str(ordinal),
                target.model_dump_json(),
            )
        ),
    )
    return Assertion(
        assertion_id=assertion_id,
        ontology_id=plan.ontology.ontology_id,
        ontology_version=plan.ontology.version,
        subject_id=subject_id,
        predicate=predicate,
        target=target,
        kind=kind,
        provenance=(provenance,),
        confidence=Decimal("1"),
        temporal=TemporalContext(
            observed_at=provenance.observed_at,
            recorded_at=recorded_at,
        ),
        mapping_version=plan.definition.version,
    )

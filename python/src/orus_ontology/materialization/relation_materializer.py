"""Materialize one relation mapping from already materialized record objects."""

from collections.abc import Mapping
from datetime import datetime
from uuid import UUID, uuid5

from orus_ontology.assertions.assertion import Assertion, AssertionKind
from orus_ontology.assertions.temporal import TemporalContext
from orus_ontology.mapping.plan import CompiledRelationMapping, MappingPlan
from orus_ontology.materialization.batch import (
    CanonicalRecord,
    ObjectInstance,
    RelationInstance,
)
from orus_ontology.materialization.object_materializer import (
    extract_value,
    make_assertion,
    materialize_targets,
    property_provenance,
)


def materialize_relation(
    plan: MappingPlan,
    mapping: CompiledRelationMapping,
    record: CanonicalRecord,
    objects_by_alias: Mapping[str, ObjectInstance],
    *,
    recorded_at: datetime,
) -> RelationInstance:
    source = objects_by_alias[mapping.source_alias]
    target = objects_by_alias[mapping.target_alias]
    source_id, target_id = _relation_endpoints(
        source.object_id,
        target.object_id,
        directed=mapping.relation_type.directed,
    )
    relation_id = uuid5(
        plan.ontology.ontology_id,
        f"relation:{mapping.relation_type.type_id}:{source_id}:{target_id}",
    )
    assertions: list[Assertion] = []
    for property_mapping in mapping.properties:
        present, value = extract_value(property_mapping, record.values)
        if not present:
            continue
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
        for index, assertion_target in enumerate(
            materialize_targets(property_mapping.target_property, value)
        ):
            assertions.append(
                make_assertion(
                    plan,
                    subject_id=relation_id,
                    predicate=property_mapping.target_property.name,
                    target=assertion_target,
                    kind=kind,
                    provenance=provenance,
                    recorded_at=recorded_at,
                    ordinal=index,
                )
            )
    return RelationInstance(
        relation_id=relation_id,
        ontology_id=plan.ontology.ontology_id,
        ontology_version=plan.ontology.version,
        relation_type_id=mapping.relation_type.type_id,
        source_object_id=source_id,
        target_object_id=target_id,
        confidence=mapping.confidence,
        assertions=tuple(assertions),
        provenance=(record.source,),
        temporal=TemporalContext(
            observed_at=record.source.observed_at,
            recorded_at=recorded_at,
        ),
    )


def _relation_endpoints(source: UUID, target: UUID, *, directed: bool) -> tuple[UUID, UUID]:
    if directed or source.int < target.int:
        return source, target
    return target, source

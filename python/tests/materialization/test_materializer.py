from collections.abc import Iterator
from datetime import UTC, datetime
from uuid import UUID

import pytest

from orus_ontology import (
    AssertionKind,
    BatchMaterializer,
    CanonicalRecord,
    MappingCompiler,
    MappingDefinition,
    MaterializationError,
    ObjectInstance,
    ObjectType,
    OntologyDefinition,
    PropertyType,
    RecordErrorPolicy,
    SourceContract,
    SourceField,
    SourceReference,
    ValueTarget,
    ValueType,
)

NOW = datetime(2026, 8, 15, 12, 0, tzinfo=UTC)
RUN_ID = UUID("aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")


def record(row_id: int, *, customer_id: object = " c-42 ") -> CanonicalRecord:
    return CanonicalRecord(
        values={
            "customer_id": customer_id,
            "customer_name": " Alice Martin ",
            "email": " ALICE@EXAMPLE.COM ",
            "email_verified": True,
        },
        source=SourceReference(
            source_id="customers.csv",
            batch_id=1,
            row_id=row_id,
            global_offset=row_id,
            run_id=RUN_ID,
            observed_at=NOW,
        ),
    )


def plan(
    ontology: OntologyDefinition,
    source_contract: SourceContract,
    mapping_definition: MappingDefinition,
):
    return MappingCompiler.compile(mapping_definition, ontology, source_contract)


def test_materialization_is_bounded_and_creates_objects_relations_and_assertions(
    ontology: OntologyDefinition,
    source_contract: SourceContract,
    mapping_definition: MappingDefinition,
) -> None:
    materializer = BatchMaterializer(
        plan(ontology, source_contract, mapping_definition),
        batch_size=1,
        recorded_at=NOW,
    )

    batches = list(materializer.materialize((record(1), record(2, customer_id="C-43"))))

    assert [batch.input_count for batch in batches] == [1, 1]
    assert all(len(batch.objects) == 2 for batch in batches)
    assert all(len(batch.relations) == 1 for batch in batches)
    customer = batches[0].objects[0]
    assert isinstance(customer, ObjectInstance)
    customer_id_assertion = next(
        assertion for assertion in customer.assertions if assertion.predicate == "customer_id"
    )
    assert customer_id_assertion.kind is AssertionKind.TRANSFORMED
    assert isinstance(customer_id_assertion.target, ValueTarget)
    assert customer_id_assertion.target.value == "C-42"
    assert customer_id_assertion.provenance[0].source_column == "customer_id"
    assert customer_id_assertion.provenance[0].transformation_ids == (
        "trim@1",
        "uppercase@1",
    )
    relation = batches[0].relations[0]
    assert relation.source_object_id == batches[0].objects[0].object_id
    assert relation.target_object_id == batches[0].objects[1].object_id
    assert relation.assertions[0].predicate == "verified"


def test_same_run_and_record_produce_stable_ids(
    ontology: OntologyDefinition,
    source_contract: SourceContract,
    mapping_definition: MappingDefinition,
) -> None:
    materializer = BatchMaterializer(
        plan(ontology, source_contract, mapping_definition),
        batch_size=10,
        recorded_at=NOW,
    )

    first = next(materializer.materialize((record(1),)))
    second = next(materializer.materialize((record(1),)))

    assert [item.object_id for item in first.objects] == [item.object_id for item in second.objects]
    assert first.relations[0].relation_id == second.relations[0].relation_id
    assert (
        first.objects[0].assertions[0].assertion_id == second.objects[0].assertions[0].assertion_id
    )


def test_quarantine_is_atomic_and_does_not_drop_error_context(
    ontology: OntologyDefinition,
    source_contract: SourceContract,
    mapping_definition: MappingDefinition,
) -> None:
    quarantine_definition = MappingDefinition.model_validate(
        {**mapping_definition.model_dump(), "error_policy": RecordErrorPolicy.QUARANTINE}
    )
    materializer = BatchMaterializer(
        plan(ontology, source_contract, quarantine_definition),
        batch_size=2,
        recorded_at=NOW,
    )

    batch = next(materializer.materialize((record(1), record(2, customer_id=None))))

    assert batch.input_count == 2
    assert len(batch.objects) == 2
    assert len(batch.relations) == 1
    assert len(batch.quarantined) == 1
    assert batch.quarantined[0].error_code == "materialization_error"
    assert "non-nullable" in batch.quarantined[0].message


def test_reject_policy_stops_on_first_invalid_record(
    ontology: OntologyDefinition,
    source_contract: SourceContract,
    mapping_definition: MappingDefinition,
) -> None:
    materializer = BatchMaterializer(
        plan(ontology, source_contract, mapping_definition),
        batch_size=2,
        recorded_at=NOW,
    )

    with pytest.raises(MaterializationError, match="non-nullable"):
        list(materializer.materialize((record(1), record(2, customer_id=None))))


def test_unknown_record_field_is_quarantined_explicitly(
    ontology: OntologyDefinition,
    source_contract: SourceContract,
    mapping_definition: MappingDefinition,
) -> None:
    definition = MappingDefinition.model_validate(
        {**mapping_definition.model_dump(), "error_policy": RecordErrorPolicy.QUARANTINE}
    )
    invalid = CanonicalRecord(
        values={**record(1).values, "unexpected": "value"},
        source=record(1).source,
    )
    batch = next(
        BatchMaterializer(
            plan(ontology, source_contract, definition),
            batch_size=1,
            recorded_at=NOW,
        ).materialize((invalid,))
    )

    assert not batch.objects
    assert len(batch.quarantined) == 1
    assert batch.quarantined[0].context["fields"] == ("unexpected",)


def test_source_contract_is_validated_before_mapping(
    ontology: OntologyDefinition,
    source_contract: SourceContract,
    mapping_definition: MappingDefinition,
) -> None:
    definition = MappingDefinition.model_validate(
        {**mapping_definition.model_dump(), "error_policy": RecordErrorPolicy.QUARANTINE}
    )
    invalid_values = dict(record(1).values)
    del invalid_values["email_verified"]
    invalid = CanonicalRecord(values=invalid_values, source=record(1).source)

    batch = next(
        BatchMaterializer(
            plan(ontology, source_contract, definition),
            batch_size=1,
            recorded_at=NOW,
        ).materialize((invalid,))
    )

    assert not batch.objects
    assert batch.quarantined[0].context["source_field"] == "email_verified"


def test_materializer_consumes_input_lazily_by_batch(
    ontology: OntologyDefinition,
    source_contract: SourceContract,
    mapping_definition: MappingDefinition,
) -> None:
    consumed = 0

    def records() -> Iterator[CanonicalRecord]:
        nonlocal consumed
        for row_id in range(5):
            consumed += 1
            yield record(row_id, customer_id=f"C-{row_id}")

    results = BatchMaterializer(
        plan(ontology, source_contract, mapping_definition),
        batch_size=2,
        recorded_at=NOW,
    ).materialize(records())

    first = next(results)
    assert first.input_count == 2
    assert consumed == 2


def test_missing_optional_source_uses_traced_property_default(
    ontology: OntologyDefinition,
    source_contract: SourceContract,
    mapping_definition: MappingDefinition,
) -> None:
    customer = ontology.get_object_type("Customer")
    assert customer is not None
    customer_id = customer.get_property("customer_id")
    name = customer.get_property("name")
    assert customer_id is not None
    assert name is not None
    name_with_default = PropertyType(
        property_id=name.property_id,
        name=name.name,
        value_type=ValueType.STRING,
        default_value="Unknown",
    )
    customer_with_default = ObjectType(
        type_id=customer.type_id,
        name=customer.name,
        version=customer.version,
        identity_spec=customer.identity_spec,
        properties=(customer_id, name_with_default),
    )
    published = OntologyDefinition(
        ontology_id=ontology.ontology_id,
        name=ontology.name,
        version=ontology.version,
        status=ontology.status,
        object_types=(customer_with_default, ontology.object_types[1]),
        relation_types=ontology.relation_types,
    )
    optional_contract = SourceContract(
        name=source_contract.name,
        version=source_contract.version,
        fields=tuple(
            SourceField(
                name=field.name,
                value_type=field.value_type,
                required=False if field.name == "customer_name" else field.required,
                nullable=field.nullable,
            )
            for field in source_contract.fields
        ),
    )
    values = dict(record(1).values)
    del values["customer_name"]
    missing_name = CanonicalRecord(values=values, source=record(1).source)

    batch = next(
        BatchMaterializer(
            plan(published, optional_contract, mapping_definition),
            batch_size=1,
            recorded_at=NOW,
        ).materialize((missing_name,))
    )
    assertion = next(item for item in batch.objects[0].assertions if item.predicate == "name")

    assert isinstance(assertion.target, ValueTarget)
    assert assertion.target.value == "Unknown"
    assert assertion.kind is AssertionKind.TRANSFORMED
    assert assertion.provenance[0].transformation_ids == ("trim@1", "default@1")

from types import MappingProxyType

import pytest
from pydantic import ValidationError

from orus_ontology import (
    IdentitySpec,
    MigrationPlan,
    MigrationStep,
    MigrationStrategy,
    ObjectType,
    OntologyStatus,
    PropertyType,
    RelationType,
    SchemaError,
    SchemaRegistry,
    ValueType,
    VersionError,
)


def make_customer(
    *, name: str = "Customer", properties: tuple[PropertyType, ...] = ()
) -> ObjectType:
    customer_id = PropertyType(
        name="customer_id",
        value_type=ValueType.STRING,
        required=True,
        nullable=False,
        unique=True,
        metadata={"classification": ["identifier"]},
    )
    return ObjectType(
        name=name,
        identity_spec=IdentitySpec(property_names=("customer_id",)),
        properties=(customer_id, *properties),
    )


def replace_object_type(
    original: ObjectType,
    *,
    name: str | None = None,
    properties: tuple[PropertyType, ...] | None = None,
) -> ObjectType:
    return ObjectType(
        type_id=original.type_id,
        name=name or original.name,
        display_name=original.display_name,
        description=original.description,
        version=original.version + 1,
        identity_spec=original.identity_spec,
        properties=properties or original.properties,
        constraints=original.constraints,
        metadata=original.metadata,
    )


def test_publish_creates_deeply_immutable_historical_snapshot() -> None:
    registry = SchemaRegistry("Commerce")
    customer = make_customer()
    registry.register_object_type(customer)

    published = registry.publish()

    assert published.status is OntologyStatus.PUBLISHED
    assert published.version == 1
    assert registry.draft_version == 2
    assert registry.latest_published_version == 1
    assert registry.get_version(1) is published
    assert isinstance(published.object_types[0].properties[0].metadata, MappingProxyType)

    with pytest.raises(ValidationError, match="frozen"):
        published.name = "Changed"  # type: ignore[misc]


def test_registry_replacement_does_not_leave_stale_name_alias() -> None:
    registry = SchemaRegistry("Commerce")
    customer = make_customer()
    registry.register_object_type(customer)
    renamed = replace_object_type(customer, name="Client")

    registry.register_object_type(renamed)

    assert registry.get_object_type("Customer") is None
    assert registry.get_object_type("Client") == renamed
    assert registry.get_object_type(customer.type_id) == renamed


def test_invalid_registration_is_rejected_without_mutating_draft() -> None:
    registry = SchemaRegistry("Commerce")
    customer = make_customer()
    registry.register_object_type(customer)
    duplicate_name = make_customer()

    with pytest.raises(SchemaError, match="structurally invalid"):
        registry.register_object_type(duplicate_name)

    assert registry.export_draft().object_types == (customer,)


def test_relation_must_reference_registered_object_types() -> None:
    registry = SchemaRegistry("Commerce")
    customer = make_customer()
    registry.register_object_type(customer)
    unknown_company = make_customer(name="Company")
    works_for = RelationType(
        name="WORKS_FOR",
        source_type_id=customer.type_id,
        target_type_id=unknown_company.type_id,
    )

    with pytest.raises(SchemaError, match="structurally invalid"):
        registry.register_relation_type(works_for)


def test_compatible_evolution_publishes_without_migration() -> None:
    registry = SchemaRegistry("Commerce")
    customer = make_customer()
    registry.register_object_type(customer)
    registry.publish()
    email = PropertyType(name="email", value_type=ValueType.STRING)
    registry.register_object_type(
        replace_object_type(customer, properties=(*customer.properties, email))
    )

    second = registry.publish()
    diff = registry.diff_versions(1, 2)

    assert second.version == 2
    assert diff.is_compatible
    assert len(diff.changes) == 1
    assert diff.changes[0].path.endswith(str(email.property_id))


def test_breaking_evolution_requires_exact_migration_coverage() -> None:
    registry = SchemaRegistry("Commerce")
    customer = make_customer()
    registry.register_object_type(customer)
    first = registry.publish()
    renamed = replace_object_type(customer, name="Client")
    registry.register_object_type(renamed)

    with pytest.raises(VersionError, match="requires a migration") as caught:
        registry.publish()

    path = f"object_types/{customer.type_id}/name"
    assert caught.value.context["breaking_paths"] == (path,)

    wrong_plan = MigrationPlan(
        ontology_id=registry.ontology_id,
        from_version=1,
        to_version=2,
        steps=(
            MigrationStep(
                change_path="object_types/unknown/name",
                strategy=MigrationStrategy.RENAME,
                description="Rename stored discriminator",
            ),
        ),
    )
    with pytest.raises(VersionError, match="invalid migration coverage"):
        registry.publish(migration=wrong_plan)

    plan = MigrationPlan(
        ontology_id=registry.ontology_id,
        from_version=1,
        to_version=2,
        steps=(
            MigrationStep(
                change_path=path,
                strategy=MigrationStrategy.RENAME,
                description="Rewrite the object type discriminator",
            ),
        ),
    )
    second = registry.publish(migration=plan)

    assert first.get_object_type("Customer") == customer
    assert first.get_object_type("Client") is None
    assert second.get_object_type("Client") == renamed
    assert registry.get_migration(1, 2) == plan


def test_compatible_evolution_rejects_unnecessary_migration() -> None:
    registry = SchemaRegistry("Commerce")
    customer = make_customer()
    registry.register_object_type(customer)
    registry.publish()
    email = PropertyType(name="email", value_type=ValueType.STRING)
    registry.register_object_type(
        replace_object_type(customer, properties=(*customer.properties, email))
    )
    plan = MigrationPlan(
        ontology_id=registry.ontology_id,
        from_version=1,
        to_version=2,
        steps=(
            MigrationStep(
                change_path="unused",
                strategy=MigrationStrategy.MANUAL,
                description="This should not be accepted",
            ),
        ),
    )

    with pytest.raises(VersionError, match="must not declare"):
        registry.publish(migration=plan)


def test_removal_preserves_registry_when_references_make_it_invalid() -> None:
    registry = SchemaRegistry("Commerce")
    customer = make_customer()
    company = make_customer(name="Company")
    registry.register_object_type(customer)
    registry.register_object_type(company)
    works_for = RelationType(
        name="WORKS_FOR",
        source_type_id=customer.type_id,
        target_type_id=company.type_id,
    )
    registry.register_relation_type(works_for)

    with pytest.raises(SchemaError, match="structurally invalid"):
        registry.remove_object_type(company.type_id)

    assert registry.get_object_type(company.type_id) == company


def test_diff_rejects_unpublished_versions() -> None:
    registry = SchemaRegistry("Commerce")

    with pytest.raises(VersionError, match="unpublished"):
        registry.diff_versions(1, 2)

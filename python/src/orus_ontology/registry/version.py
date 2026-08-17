"""Deterministic compatibility analysis between ontology versions."""

from enum import StrEnum

from pydantic import field_validator

from orus_ontology._schema import SchemaModel
from orus_ontology.metamodel.object_type import ObjectType
from orus_ontology.metamodel.ontology import OntologyDefinition
from orus_ontology.metamodel.property_type import PropertyType
from orus_ontology.metamodel.relation_type import RelationType


class ChangeCompatibility(StrEnum):
    COMPATIBLE = "compatible"
    BREAKING = "breaking"


class VersionChange(SchemaModel):
    """One stable, machine-readable schema evolution event."""

    path: str
    compatibility: ChangeCompatibility
    message: str

    @field_validator("path", "message")
    @classmethod
    def reject_blank_text(cls, value: str) -> str:
        if not value.strip():
            raise ValueError("version change fields must not be blank")
        return value


class VersionDiff(SchemaModel):
    """Ordered changes between two consecutive ontology snapshots."""

    from_version: int
    to_version: int
    changes: tuple[VersionChange, ...] = ()

    @property
    def breaking_changes(self) -> tuple[VersionChange, ...]:
        return tuple(
            change
            for change in self.changes
            if change.compatibility is ChangeCompatibility.BREAKING
        )

    @property
    def is_compatible(self) -> bool:
        return not self.breaking_changes


def compare_versions(previous: OntologyDefinition, current: OntologyDefinition) -> VersionDiff:
    """Compare snapshots using stable IDs rather than mutable display names."""
    if previous.ontology_id != current.ontology_id:
        raise ValueError("cannot compare definitions from different ontologies")
    if current.version != previous.version + 1:
        raise ValueError("ontology versions must be consecutive")

    changes: list[VersionChange] = []
    previous_objects = {item.type_id: item for item in previous.object_types}
    current_objects = {item.type_id: item for item in current.object_types}
    previous_relations = {item.type_id: item for item in previous.relation_types}
    current_relations = {item.type_id: item for item in current.relation_types}

    for type_id, old in previous_objects.items():
        path = f"object_types/{type_id}"
        new = current_objects.get(type_id)
        if new is None:
            changes.append(_breaking(path, f"object type '{old.name}' was removed"))
            continue
        changes.extend(_compare_object_type(path, old, new))
    for type_id, new in current_objects.items():
        if type_id not in previous_objects:
            changes.append(
                _compatible(f"object_types/{type_id}", f"object type '{new.name}' was added")
            )

    for type_id, old in previous_relations.items():
        path = f"relation_types/{type_id}"
        new = current_relations.get(type_id)
        if new is None:
            changes.append(_breaking(path, f"relation type '{old.name}' was removed"))
            continue
        changes.extend(_compare_relation_type(path, old, new))
    for type_id, new in current_relations.items():
        if type_id not in previous_relations:
            changes.append(
                _compatible(f"relation_types/{type_id}", f"relation type '{new.name}' was added")
            )

    return VersionDiff(
        from_version=previous.version,
        to_version=current.version,
        changes=tuple(changes),
    )


def _compare_object_type(path: str, old: ObjectType, new: ObjectType) -> list[VersionChange]:
    changes: list[VersionChange] = []
    if old.name != new.name:
        changes.append(
            _breaking(f"{path}/name", f"object type renamed from '{old.name}' to '{new.name}'")
        )
    if old.identity_spec != new.identity_spec:
        changes.append(_breaking(f"{path}/identity_spec", "object identity definition changed"))
    if old.constraints != new.constraints:
        changes.append(_breaking(f"{path}/constraints", "object constraints changed"))
    changes.extend(_compare_properties(path, old.properties, new.properties))
    return changes


def _compare_relation_type(path: str, old: RelationType, new: RelationType) -> list[VersionChange]:
    changes: list[VersionChange] = []
    if old.name != new.name:
        changes.append(
            _breaking(f"{path}/name", f"relation type renamed from '{old.name}' to '{new.name}'")
        )
    structural_fields = (
        "source_type_id",
        "target_type_id",
        "directed",
        "cardinality",
        "temporal",
        "constraints",
    )
    for field_name in structural_fields:
        if getattr(old, field_name) != getattr(new, field_name):
            changes.append(
                _breaking(f"{path}/{field_name}", f"relation field '{field_name}' changed")
            )
    changes.extend(_compare_properties(path, old.properties, new.properties))
    return changes


def _compare_properties(
    owner_path: str,
    old_properties: tuple[PropertyType, ...],
    new_properties: tuple[PropertyType, ...],
) -> list[VersionChange]:
    changes: list[VersionChange] = []
    old_by_id = {item.property_id: item for item in old_properties}
    new_by_id = {item.property_id: item for item in new_properties}

    for property_id, old in old_by_id.items():
        path = f"{owner_path}/properties/{property_id}"
        new = new_by_id.get(property_id)
        if new is None:
            changes.append(_breaking(path, f"property '{old.name}' was removed"))
            continue
        if old.name != new.name:
            changes.append(
                _breaking(f"{path}/name", f"property renamed from '{old.name}' to '{new.name}'")
            )
        fields = (
            "value_type",
            "nullable",
            "required",
            "unique",
            "cardinality",
            "reference_type_id",
            "constraints",
        )
        for field_name in fields:
            old_value = getattr(old, field_name)
            new_value = getattr(new, field_name)
            if old_value == new_value:
                continue
            compatibility = _property_field_compatibility(field_name, old_value, new_value)
            message = f"property field '{field_name}' changed"
            changes.append(
                VersionChange(
                    path=f"{path}/{field_name}",
                    compatibility=compatibility,
                    message=message,
                )
            )
        if old.default_value != new.default_value:
            changes.append(_compatible(f"{path}/default_value", "property default changed"))

    for property_id, new in new_by_id.items():
        if property_id in old_by_id:
            continue
        path = f"{owner_path}/properties/{property_id}"
        if new.required and new.default_value is None:
            changes.append(
                _breaking(path, f"required property '{new.name}' was added without a default")
            )
        else:
            changes.append(_compatible(path, f"property '{new.name}' was added"))
    return changes


def _property_field_compatibility(
    field_name: str, old_value: object, new_value: object
) -> ChangeCompatibility:
    if field_name == "nullable" and old_value is False and new_value is True:
        return ChangeCompatibility.COMPATIBLE
    if field_name == "required" and old_value is True and new_value is False:
        return ChangeCompatibility.COMPATIBLE
    if field_name == "unique" and old_value is True and new_value is False:
        return ChangeCompatibility.COMPATIBLE
    return ChangeCompatibility.BREAKING


def _breaking(path: str, message: str) -> VersionChange:
    return VersionChange(
        path=path,
        compatibility=ChangeCompatibility.BREAKING,
        message=message,
    )


def _compatible(path: str, message: str) -> VersionChange:
    return VersionChange(
        path=path,
        compatibility=ChangeCompatibility.COMPATIBLE,
        message=message,
    )

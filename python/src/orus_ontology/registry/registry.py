"""In-process registry for ontology drafts and immutable published snapshots."""

from uuid import UUID, uuid4

from pydantic import ValidationError

from orus_ontology.errors import SchemaError, VersionError
from orus_ontology.metamodel.object_type import ObjectType
from orus_ontology.metamodel.ontology import OntologyDefinition, OntologyStatus
from orus_ontology.metamodel.relation_type import RelationType
from orus_ontology.registry.migration import MigrationPlan
from orus_ontology.registry.version import VersionDiff, compare_versions


class SchemaRegistry:
    """Own the current draft, published history, and accepted migrations."""

    def __init__(self, name: str, *, ontology_id: UUID | None = None) -> None:
        self._ontology_id = ontology_id or uuid4()
        self._name = name
        self._draft_version = 1
        self._object_types: dict[UUID, ObjectType] = {}
        self._relation_types: dict[UUID, RelationType] = {}
        self._versions: dict[int, OntologyDefinition] = {}
        self._migrations: dict[tuple[int, int], MigrationPlan] = {}
        self._build_definition(OntologyStatus.DRAFT)

    @property
    def ontology_id(self) -> UUID:
        return self._ontology_id

    @property
    def draft_version(self) -> int:
        return self._draft_version

    @property
    def latest_published_version(self) -> int | None:
        return max(self._versions, default=None)

    def register_object_type(self, object_type: ObjectType) -> None:
        prospective = dict(self._object_types)
        prospective[object_type.type_id] = object_type
        self._validate_state(prospective, self._relation_types)
        self._object_types = prospective

    def register_relation_type(self, relation_type: RelationType) -> None:
        prospective = dict(self._relation_types)
        prospective[relation_type.type_id] = relation_type
        self._validate_state(self._object_types, prospective)
        self._relation_types = prospective

    def remove_relation_type(self, key: UUID | str) -> RelationType:
        relation = self.get_relation_type(key)
        if relation is None:
            raise SchemaError("relation type not found", context={"key": str(key)})
        prospective = dict(self._relation_types)
        del prospective[relation.type_id]
        self._validate_state(self._object_types, prospective)
        self._relation_types = prospective
        return relation

    def remove_object_type(self, key: UUID | str) -> ObjectType:
        object_type = self.get_object_type(key)
        if object_type is None:
            raise SchemaError("object type not found", context={"key": str(key)})
        prospective = dict(self._object_types)
        del prospective[object_type.type_id]
        self._validate_state(prospective, self._relation_types)
        self._object_types = prospective
        return object_type

    def get_object_type(self, key: UUID | str) -> ObjectType | None:
        return next(
            (
                item
                for item in self._object_types.values()
                if item.type_id == key or item.name == key
            ),
            None,
        )

    def get_relation_type(self, key: UUID | str) -> RelationType | None:
        return next(
            (
                item
                for item in self._relation_types.values()
                if item.type_id == key or item.name == key
            ),
            None,
        )

    def export_draft(self) -> OntologyDefinition:
        return self._build_definition(OntologyStatus.DRAFT)

    def publish(self, *, migration: MigrationPlan | None = None) -> OntologyDefinition:
        definition = self._build_definition(OntologyStatus.PUBLISHED)
        previous = self._versions.get(self._draft_version - 1)
        if previous is not None:
            diff = compare_versions(previous, definition)
            self._validate_migration(diff, migration)
        elif migration is not None:
            raise VersionError("the first ontology version cannot have a migration")

        self._versions[definition.version] = definition
        if migration is not None:
            self._migrations[(migration.from_version, migration.to_version)] = migration
        self._draft_version += 1
        return definition

    def get_version(self, version: int) -> OntologyDefinition | None:
        return self._versions.get(version)

    def get_migration(self, from_version: int, to_version: int) -> MigrationPlan | None:
        return self._migrations.get((from_version, to_version))

    def diff_versions(self, from_version: int, to_version: int) -> VersionDiff:
        previous = self._versions.get(from_version)
        current = self._versions.get(to_version)
        if previous is None or current is None:
            raise VersionError(
                "cannot diff unpublished ontology versions",
                context={"from_version": from_version, "to_version": to_version},
            )
        try:
            return compare_versions(previous, current)
        except ValueError as error:
            raise VersionError(str(error)) from error

    def _validate_state(
        self,
        object_types: dict[UUID, ObjectType],
        relation_types: dict[UUID, RelationType],
    ) -> None:
        self._build_definition(
            OntologyStatus.DRAFT,
            object_types=object_types,
            relation_types=relation_types,
        )

    def _build_definition(
        self,
        status: OntologyStatus,
        *,
        object_types: dict[UUID, ObjectType] | None = None,
        relation_types: dict[UUID, RelationType] | None = None,
    ) -> OntologyDefinition:
        try:
            return OntologyDefinition(
                ontology_id=self._ontology_id,
                name=self._name,
                version=self._draft_version,
                status=status,
                object_types=tuple(
                    (object_types if object_types is not None else self._object_types).values()
                ),
                relation_types=tuple(
                    (
                        relation_types if relation_types is not None else self._relation_types
                    ).values()
                ),
            )
        except ValidationError as error:
            raise SchemaError(
                "registry draft is structurally invalid",
                context={"details": error.errors(include_url=False)},
            ) from error

    def _validate_migration(
        self,
        diff: VersionDiff,
        migration: MigrationPlan | None,
    ) -> None:
        breaking_paths = tuple(change.path for change in diff.breaking_changes)
        if not breaking_paths:
            if migration is not None:
                raise VersionError("a compatible evolution must not declare a migration")
            return
        if migration is None:
            raise VersionError(
                "breaking ontology evolution requires a migration plan",
                context={"breaking_paths": breaking_paths},
            )
        if migration.ontology_id != self._ontology_id:
            raise VersionError("migration targets a different ontology")
        if migration.from_version != diff.from_version or migration.to_version != diff.to_version:
            raise VersionError("migration versions do not match the ontology evolution")
        try:
            migration.validate_coverage(diff)
        except ValueError as error:
            raise VersionError(str(error)) from error

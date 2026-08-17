"""Transactional PostgreSQL backend for the ontology storage contract."""

from collections.abc import Sequence
from hashlib import sha256
from importlib.resources import files
from typing import LiteralString, cast
from uuid import UUID

import psycopg
from psycopg import sql
from psycopg.rows import TupleRow, tuple_row
from psycopg.types.json import Jsonb

from orus_ontology.assertions.assertion import Assertion, ValueTarget
from orus_ontology.errors import StorageError
from orus_ontology.identity.resolution import ResolutionDecision, ResolutionOutcome
from orus_ontology.materialization.batch import (
    MaterializedBatch,
    ObjectInstance,
    RelationInstance,
)
from orus_ontology.metamodel.ontology import OntologyDefinition, OntologyStatus
from orus_ontology.storage.contracts import RelationDirection

_MIGRATION_VERSION = 1


class BatchWriteResult:
    def __init__(self, *, objects: int, relations: int, assertions: int) -> None:
        self.objects = objects
        self.relations = relations
        self.assertions = assertions


class PostgresStore:
    """Synchronous PostgreSQL backend owning one transactional connection."""

    def __init__(self, conninfo: str, *, application_name: str = "orus-ontology") -> None:
        try:
            self._connection = psycopg.connect(
                conninfo,
                autocommit=True,
                application_name=application_name,
                row_factory=tuple_row,
            )
            self._migrate()
        except psycopg.Error as error:
            raise _storage_error("failed to initialize PostgreSQL storage", error) from error

    def close(self) -> None:
        self._connection.close()

    def __enter__(self) -> "PostgresStore":
        return self

    def __exit__(self, *_: object) -> None:
        self.close()

    def put_schema(self, schema: OntologyDefinition) -> None:
        if schema.status is not OntologyStatus.PUBLISHED:
            raise StorageError("only published ontology schemas can be stored")
        document = Jsonb(schema.model_dump(mode="json"))
        self._insert_immutable(
            "orus_ontology_schemas",
            ("ontology_id", "version", "document"),
            (schema.ontology_id, schema.version, document),
            ("ontology_id", "version"),
            "schema identity collision",
        )

    def put_materialized_batch(self, batch: MaterializedBatch) -> BatchWriteResult:
        objects = _unique_objects(batch.objects)
        relations = _unique_relations(batch.relations)
        assertions = _unique_assertions(
            tuple(
                assertion
                for instance in (*batch.objects, *batch.relations)
                for assertion in instance.assertions
            )
        )
        schemas: dict[tuple[UUID, int], OntologyDefinition] = {}
        for instance in objects.values():
            key = (instance.ontology_id, instance.ontology_version)
            schema = schemas.get(key) or self._require_schema(*key)
            schemas[key] = schema
            if schema.get_object_type(instance.object_type_id) is None:
                raise StorageError("object instance references an unknown object type")
        endpoint_types = {
            object_id: instance.object_type_id for object_id, instance in objects.items()
        }
        for instance in relations.values():
            key = (instance.ontology_id, instance.ontology_version)
            schema = schemas.get(key) or self._require_schema(*key)
            schemas[key] = schema
            relation_type = schema.get_relation_type(instance.relation_type_id)
            if relation_type is None:
                raise StorageError("relation instance references an unknown relation type")
            source_type = endpoint_types.get(instance.source_object_id)
            target_type = endpoint_types.get(instance.target_object_id)
            if source_type is None:
                source = self.get_object(instance.source_object_id)
                source_type = source.object_type_id if source else None
            if target_type is None:
                target = self.get_object(instance.target_object_id)
                target_type = target.object_type_id if target else None
            if source_type is None or target_type is None:
                raise StorageError("relation endpoint does not exist")
            if (
                source_type != relation_type.source_type_id
                or target_type != relation_type.target_type_id
            ):
                raise StorageError("relation endpoints do not match the relation type")
        try:
            with self._connection.transaction():
                existing_objects = self._existing_object_shapes(tuple(objects))
                for object_id, instance in objects.items():
                    existing = existing_objects.get(object_id)
                    shape = (
                        instance.ontology_id,
                        instance.ontology_version,
                        instance.object_type_id,
                    )
                    if existing is not None and existing != shape:
                        raise StorageError(
                            "object identity collision", context={"object_id": object_id}
                        )
                new_objects = [
                    instance
                    for object_id, instance in objects.items()
                    if object_id not in existing_objects
                ]
                if new_objects:
                    self._connection.cursor().executemany(
                        "INSERT INTO orus_ontology_objects "
                        "(object_id, ontology_id, ontology_version, object_type_id, document) "
                        "VALUES (%s, %s, %s, %s, %s)",
                        [
                            (
                                item.object_id,
                                item.ontology_id,
                                item.ontology_version,
                                item.object_type_id,
                                Jsonb(item.model_dump(mode="json")),
                            )
                            for item in new_objects
                        ],
                    )

                existing_relations = self._existing_relation_shapes(tuple(relations))
                for relation_id, instance in relations.items():
                    existing = existing_relations.get(relation_id)
                    shape = (
                        instance.ontology_id,
                        instance.ontology_version,
                        instance.relation_type_id,
                        instance.source_object_id,
                        instance.target_object_id,
                    )
                    if existing is not None and existing != shape:
                        raise StorageError(
                            "relation identity collision", context={"relation_id": relation_id}
                        )
                new_relations = [
                    instance
                    for relation_id, instance in relations.items()
                    if relation_id not in existing_relations
                ]
                if new_relations:
                    self._connection.cursor().executemany(
                        "INSERT INTO orus_ontology_relations "
                        "(relation_id, ontology_id, ontology_version, relation_type_id, "
                        "source_object_id, target_object_id, document) "
                        "VALUES (%s, %s, %s, %s, %s, %s, %s)",
                        [
                            (
                                item.relation_id,
                                item.ontology_id,
                                item.ontology_version,
                                item.relation_type_id,
                                item.source_object_id,
                                item.target_object_id,
                                Jsonb(item.model_dump(mode="json")),
                            )
                            for item in new_relations
                        ],
                    )

                existing_assertions = self._existing_assertion_documents(tuple(assertions))
                for assertion_id, assertion in assertions.items():
                    existing = existing_assertions.get(assertion_id)
                    document = assertion.model_dump(mode="json")
                    if existing is not None and existing != document:
                        raise StorageError("assertion identity collision")
                new_assertions = [
                    assertion
                    for assertion_id, assertion in assertions.items()
                    if assertion_id not in existing_assertions
                ]
                if new_assertions:
                    self._connection.cursor().executemany(
                        "INSERT INTO orus_ontology_assertions "
                        "(assertion_id, subject_id, predicate, target_value, "
                        "supersedes_assertion_id, document) VALUES (%s, %s, %s, %s, %s, %s)",
                        [
                            (
                                item.assertion_id,
                                item.subject_id,
                                item.predicate,
                                _target_json(item),
                                item.supersedes_assertion_id,
                                Jsonb(item.model_dump(mode="json")),
                            )
                            for item in new_assertions
                        ],
                    )
        except psycopg.Error as error:
            raise _storage_error("failed to store materialized batch", error) from error
        return BatchWriteResult(
            objects=len(new_objects),
            relations=len(new_relations),
            assertions=len(new_assertions),
        )

    def statistics(self) -> dict[str, int]:
        tables = {
            "schemas": "orus_ontology_schemas",
            "objects": "orus_ontology_objects",
            "relations": "orus_ontology_relations",
            "assertions": "orus_ontology_assertions",
            "resolutions": "orus_ontology_resolutions",
        }
        result: dict[str, int] = {}
        for name, table in tables.items():
            row = self._connection.execute(
                sql.SQL("SELECT count(*) FROM {}").format(sql.Identifier(table))
            ).fetchone()
            result[name] = int(row[0]) if row else 0
        return result

    def get_schema(self, ontology_id: UUID, version: int) -> OntologyDefinition | None:
        row = self._fetchone(
            "SELECT document FROM orus_ontology_schemas WHERE ontology_id = %s AND version = %s",
            (ontology_id, version),
        )
        return OntologyDefinition.model_validate(row[0]) if row else None

    def latest_schema(self, ontology_id: UUID) -> OntologyDefinition | None:
        row = self._fetchone(
            "SELECT document FROM orus_ontology_schemas "
            "WHERE ontology_id = %s ORDER BY version DESC LIMIT 1",
            (ontology_id,),
        )
        return OntologyDefinition.model_validate(row[0]) if row else None

    def put_object(self, instance: ObjectInstance) -> None:
        self.put_materialized_batch(
            MaterializedBatch(input_count=1, objects=(instance,), relations=())
        )

    def get_object(self, object_id: UUID) -> ObjectInstance | None:
        row = self._fetchone(
            "SELECT document FROM orus_ontology_objects WHERE object_id = %s", (object_id,)
        )
        return ObjectInstance.model_validate(row[0]) if row else None

    def put_assertions(self, assertions: Sequence[Assertion]) -> None:
        try:
            with self._connection.transaction():
                self._put_assertions_in_transaction(assertions)
        except psycopg.Error as error:
            raise _storage_error("failed to store assertions", error) from error

    def assertions_for(self, subject_id: UUID) -> tuple[Assertion, ...]:
        rows = self._fetchall(
            "SELECT document FROM orus_ontology_assertions "
            "WHERE subject_id = %s ORDER BY assertion_id",
            (subject_id,),
        )
        return tuple(Assertion.model_validate(row[0]) for row in rows)

    def get_assertion(self, assertion_id: UUID) -> Assertion | None:
        row = self._fetchone(
            "SELECT document FROM orus_ontology_assertions WHERE assertion_id = %s",
            (assertion_id,),
        )
        return Assertion.model_validate(row[0]) if row else None

    def scan_objects(
        self, object_type_id: UUID | None, *, limit: int, offset: int
    ) -> tuple[ObjectInstance, ...]:
        _validate_page(limit, offset)
        if object_type_id is None:
            rows = self._fetchall(
                "SELECT document FROM orus_ontology_objects ORDER BY object_id LIMIT %s OFFSET %s",
                (limit, offset),
            )
        else:
            rows = self._fetchall(
                "SELECT document FROM orus_ontology_objects "
                "WHERE object_type_id = %s ORDER BY object_id LIMIT %s OFFSET %s",
                (object_type_id, limit, offset),
            )
        return tuple(ObjectInstance.model_validate(row[0]) for row in rows)

    def lookup_objects(
        self,
        predicate: str,
        value: object,
        object_type_id: UUID | None,
        *,
        limit: int,
        offset: int,
    ) -> tuple[ObjectInstance, ...]:
        _validate_page(limit, offset)
        if object_type_id is None:
            rows = self._fetchall(
                "SELECT DISTINCT o.document FROM orus_ontology_objects o "
                "JOIN orus_ontology_assertions a ON a.subject_id = o.object_id "
                "WHERE a.predicate = %s AND a.target_value = %s "
                "ORDER BY o.document LIMIT %s OFFSET %s",
                (predicate, Jsonb(value), limit, offset),
            )
        else:
            rows = self._fetchall(
                "SELECT DISTINCT o.object_id, o.document FROM orus_ontology_objects o "
                "JOIN orus_ontology_assertions a ON a.subject_id = o.object_id "
                "WHERE o.object_type_id = %s AND a.predicate = %s AND a.target_value = %s "
                "ORDER BY o.object_id LIMIT %s OFFSET %s",
                (object_type_id, predicate, Jsonb(value), limit, offset),
            )
            return tuple(ObjectInstance.model_validate(row[1]) for row in rows)
        return tuple(ObjectInstance.model_validate(row[0]) for row in rows)

    def put_relation(self, instance: RelationInstance) -> None:
        self.put_materialized_batch(
            MaterializedBatch(input_count=1, objects=(), relations=(instance,))
        )

    def get_relation(self, relation_id: UUID) -> RelationInstance | None:
        row = self._fetchone(
            "SELECT document FROM orus_ontology_relations WHERE relation_id = %s",
            (relation_id,),
        )
        return RelationInstance.model_validate(row[0]) if row else None

    def neighbors(
        self,
        object_id: UUID,
        relation_type_id: UUID | None,
        direction: RelationDirection,
        *,
        limit: int,
        offset: int,
    ) -> tuple[RelationInstance, ...]:
        _validate_page(limit, offset)
        clauses: list[sql.Composable] = []
        parameters: list[object] = []
        if direction is RelationDirection.OUTGOING:
            clauses.append(sql.SQL("source_object_id = %s"))
            parameters.append(object_id)
        elif direction is RelationDirection.INCOMING:
            clauses.append(sql.SQL("target_object_id = %s"))
            parameters.append(object_id)
        else:
            clauses.append(sql.SQL("(source_object_id = %s OR target_object_id = %s)"))
            parameters.extend((object_id, object_id))
        if relation_type_id is not None:
            clauses.append(sql.SQL("relation_type_id = %s"))
            parameters.append(relation_type_id)
        parameters.extend((limit, offset))
        query = sql.SQL("SELECT document FROM orus_ontology_relations WHERE {} ").format(
            sql.SQL(" AND ").join(clauses)
        ) + sql.SQL("ORDER BY relation_id LIMIT %s OFFSET %s")
        rows = self._fetchall(query, tuple(parameters))
        return tuple(RelationInstance.model_validate(row[0]) for row in rows)

    def put_resolution(self, decision: ResolutionDecision) -> None:
        if decision.outcome is not ResolutionOutcome.MERGE:
            return
        canonical_id = decision.canonical_object_id
        if canonical_id is None:
            raise StorageError("merge resolution has no canonical object ID")
        try:
            with self._connection.transaction():
                for source_id in decision.source_object_ids:
                    self._insert_immutable_in_transaction(
                        "orus_ontology_resolutions",
                        ("decision_id", "source_object_id", "canonical_object_id", "document"),
                        (
                            decision.decision_id,
                            source_id,
                            canonical_id,
                            Jsonb(decision.model_dump(mode="json")),
                        ),
                        ("source_object_id",),
                        "object has conflicting canonical resolutions",
                    )
        except psycopg.Error as error:
            raise _storage_error("failed to store resolution", error) from error

    def canonical_id(self, object_id: UUID) -> UUID:
        row = self._fetchone(
            "SELECT canonical_object_id FROM orus_ontology_resolutions WHERE source_object_id = %s",
            (object_id,),
        )
        return cast(UUID, row[0]) if row else object_id

    def _migrate(self) -> None:
        migration = (
            files("orus_ontology.storage.migrations").joinpath("001_initial.sql").read_text()
        )
        checksum = sha256(migration.encode()).hexdigest()
        with self._connection.transaction():
            self._connection.execute(
                "CREATE TABLE IF NOT EXISTS orus_ontology_schema_migrations "
                "(version integer PRIMARY KEY, checksum text NOT NULL, "
                "applied_at timestamptz NOT NULL DEFAULT now())"
            )
            self._connection.execute(
                "SELECT pg_advisory_xact_lock(hashtext('orus_ontology_migrations'))"
            )
            row = self._connection.execute(
                "SELECT checksum FROM orus_ontology_schema_migrations WHERE version = %s",
                (_MIGRATION_VERSION,),
            ).fetchone()
            if row is None:
                self._connection.execute(sql.SQL(cast(LiteralString, migration)))
                self._connection.execute(
                    "INSERT INTO orus_ontology_schema_migrations (version, checksum) "
                    "VALUES (%s, %s)",
                    (_MIGRATION_VERSION, checksum),
                )
            elif row[0] != checksum:
                raise StorageError("applied PostgreSQL migration checksum does not match")

    def _existing_object_shapes(
        self, object_ids: tuple[UUID, ...]
    ) -> dict[UUID, tuple[UUID, int, UUID]]:
        if not object_ids:
            return {}
        rows = self._connection.execute(
            "SELECT object_id, ontology_id, ontology_version, object_type_id "
            "FROM orus_ontology_objects WHERE object_id = ANY(%s)",
            (list(object_ids),),
        ).fetchall()
        return {row[0]: (row[1], row[2], row[3]) for row in rows}

    def _existing_relation_shapes(
        self, relation_ids: tuple[UUID, ...]
    ) -> dict[UUID, tuple[UUID, int, UUID, UUID, UUID]]:
        if not relation_ids:
            return {}
        rows = self._connection.execute(
            "SELECT relation_id, ontology_id, ontology_version, relation_type_id, "
            "source_object_id, target_object_id FROM orus_ontology_relations "
            "WHERE relation_id = ANY(%s)",
            (list(relation_ids),),
        ).fetchall()
        return {row[0]: (row[1], row[2], row[3], row[4], row[5]) for row in rows}

    def _existing_assertion_documents(self, assertion_ids: tuple[UUID, ...]) -> dict[UUID, object]:
        if not assertion_ids:
            return {}
        rows = self._connection.execute(
            "SELECT assertion_id, document FROM orus_ontology_assertions "
            "WHERE assertion_id = ANY(%s)",
            (list(assertion_ids),),
        ).fetchall()
        return {row[0]: row[1] for row in rows}

    def _require_schema(self, ontology_id: UUID, version: int) -> OntologyDefinition:
        schema = self.get_schema(ontology_id, version)
        if schema is None:
            raise StorageError("instance references an unpublished schema")
        return schema

    def _put_assertions_in_transaction(self, assertions: Sequence[Assertion]) -> None:
        for assertion in assertions:
            subject_exists = self._connection.execute(
                "SELECT EXISTS (SELECT 1 FROM orus_ontology_objects WHERE object_id = %s) "
                "OR EXISTS (SELECT 1 FROM orus_ontology_relations WHERE relation_id = %s)",
                (assertion.subject_id, assertion.subject_id),
            ).fetchone()
            if subject_exists is None or not subject_exists[0]:
                raise StorageError("assertion references an unknown subject")
            self._insert_immutable_in_transaction(
                "orus_ontology_assertions",
                (
                    "assertion_id",
                    "subject_id",
                    "predicate",
                    "target_value",
                    "supersedes_assertion_id",
                    "document",
                ),
                (
                    assertion.assertion_id,
                    assertion.subject_id,
                    assertion.predicate,
                    _target_json(assertion),
                    assertion.supersedes_assertion_id,
                    Jsonb(assertion.model_dump(mode="json")),
                ),
                ("assertion_id",),
                "assertion identity collision",
            )

    def _insert_immutable(
        self,
        table: str,
        columns: tuple[str, ...],
        values: tuple[object, ...],
        key_columns: tuple[str, ...],
        collision_message: str,
    ) -> None:
        try:
            with self._connection.transaction():
                self._insert_immutable_in_transaction(
                    table, columns, values, key_columns, collision_message
                )
        except psycopg.Error as error:
            raise _storage_error(f"failed to store {table}", error) from error

    def _insert_immutable_in_transaction(
        self,
        table: str,
        columns: tuple[str, ...],
        values: tuple[object, ...],
        key_columns: tuple[str, ...],
        collision_message: str,
    ) -> None:
        query = sql.SQL("INSERT INTO {} ({}) VALUES ({}) ON CONFLICT ({}) DO NOTHING").format(
            sql.Identifier(table),
            sql.SQL(", ").join(map(sql.Identifier, columns)),
            sql.SQL(", ").join(sql.Placeholder() * len(columns)),
            sql.SQL(", ").join(map(sql.Identifier, key_columns)),
        )
        cursor = self._connection.execute(query, values)
        if cursor.rowcount == 1:
            return
        where = sql.SQL(" AND ").join(
            sql.SQL("{} = %s").format(sql.Identifier(column)) for column in key_columns
        )
        key_values = tuple(values[columns.index(column)] for column in key_columns)
        row = self._connection.execute(
            sql.SQL("SELECT document FROM {} WHERE {}").format(sql.Identifier(table), where),
            key_values,
        ).fetchone()
        incoming = values[columns.index("document")]
        if row is None or row[0] != cast(Jsonb, incoming).obj:
            raise StorageError(collision_message)

    def _fetchone(
        self, query: str | sql.SQL | sql.Composed, parameters: tuple[object, ...]
    ) -> TupleRow | None:
        try:
            statement = sql.SQL(cast(LiteralString, query)) if isinstance(query, str) else query
            return self._connection.execute(statement, parameters).fetchone()
        except psycopg.Error as error:
            self._connection.rollback()
            raise _storage_error("PostgreSQL read failed", error) from error

    def _fetchall(
        self, query: str | sql.SQL | sql.Composed, parameters: tuple[object, ...]
    ) -> list[TupleRow]:
        try:
            statement = sql.SQL(cast(LiteralString, query)) if isinstance(query, str) else query
            return self._connection.execute(statement, parameters).fetchall()
        except psycopg.Error as error:
            self._connection.rollback()
            raise _storage_error("PostgreSQL read failed", error) from error


def _validate_page(limit: int, offset: int) -> None:
    if not 1 <= limit <= 10_000 or offset < 0:
        raise StorageError("invalid bounded page", context={"limit": limit, "offset": offset})


def _storage_error(message: str, error: psycopg.Error) -> StorageError:
    return StorageError(
        message,
        context={"sqlstate": error.sqlstate, "detail": str(error)},
    )


def _unique_objects(instances: tuple[ObjectInstance, ...]) -> dict[UUID, ObjectInstance]:
    result: dict[UUID, ObjectInstance] = {}
    for instance in instances:
        existing = result.get(instance.object_id)
        if existing is not None and (
            existing.ontology_id,
            existing.ontology_version,
            existing.object_type_id,
        ) != (
            instance.ontology_id,
            instance.ontology_version,
            instance.object_type_id,
        ):
            raise StorageError("object identity collision inside materialized batch")
        result.setdefault(instance.object_id, instance)
    return result


def _unique_relations(instances: tuple[RelationInstance, ...]) -> dict[UUID, RelationInstance]:
    result: dict[UUID, RelationInstance] = {}
    for instance in instances:
        existing = result.get(instance.relation_id)
        if existing is not None and (
            existing.ontology_id,
            existing.ontology_version,
            existing.relation_type_id,
            existing.source_object_id,
            existing.target_object_id,
        ) != (
            instance.ontology_id,
            instance.ontology_version,
            instance.relation_type_id,
            instance.source_object_id,
            instance.target_object_id,
        ):
            raise StorageError("relation identity collision inside materialized batch")
        result.setdefault(instance.relation_id, instance)
    return result


def _unique_assertions(instances: tuple[Assertion, ...]) -> dict[UUID, Assertion]:
    result: dict[UUID, Assertion] = {}
    for instance in instances:
        existing = result.get(instance.assertion_id)
        if existing is not None and existing != instance:
            raise StorageError("assertion identity collision inside materialized batch")
        result.setdefault(instance.assertion_id, instance)
    return result


def _target_json(assertion: Assertion) -> Jsonb | None:
    if not isinstance(assertion.target, ValueTarget):
        return None
    return Jsonb(assertion.target.model_dump(mode="json")["value"])

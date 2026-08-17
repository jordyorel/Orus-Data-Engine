import os
from datetime import UTC, datetime
from uuid import uuid4

import pytest

from orus_ontology import (
    BatchMaterializer,
    CanonicalRecord,
    MappingCompiler,
    MappingDefinition,
    OntologyDefinition,
    SourceContract,
    SourceReference,
)


def test_graph_survives_store_reconnection(
    ontology: OntologyDefinition,
    source_contract: SourceContract,
    mapping_definition: MappingDefinition,
) -> None:
    conninfo = os.environ.get("ORUS_ONTOLOGY_TEST_POSTGRES")
    if conninfo is None:
        pytest.skip("set ORUS_ONTOLOGY_TEST_POSTGRES to run PostgreSQL persistence")
    psycopg = pytest.importorskip("psycopg")
    from psycopg import sql

    from orus_ontology.storage.postgres import PostgresStore

    schema_name = f"orus_reconnect_{uuid4().hex}"
    now = datetime(2026, 8, 15, 12, tzinfo=UTC)
    record = CanonicalRecord(
        values={
            "customer_id": "C-RESTART",
            "customer_name": "Persisted",
            "email": "persisted@example.com",
            "email_verified": True,
        },
        source=SourceReference(
            source_id="restart.csv",
            row_id=0,
            global_offset=0,
            run_id=uuid4(),
            observed_at=now,
        ),
    )
    batch = next(
        BatchMaterializer(
            MappingCompiler.compile(mapping_definition, ontology, source_contract),
            batch_size=1,
            recorded_at=now,
        ).materialize((record,))
    )
    with psycopg.connect(conninfo, autocommit=True) as admin:
        admin.execute(sql.SQL("CREATE SCHEMA {}").format(sql.Identifier(schema_name)))
    scoped = f"{conninfo} options='-c search_path={schema_name}'"
    try:
        first = PostgresStore(scoped)
        first.put_schema(ontology)
        for instance in batch.objects:
            first.put_object(instance)
        for relation in batch.relations:
            first.put_relation(relation)
        object_id = batch.objects[0].object_id
        relation_id = batch.relations[0].relation_id
        first.close()

        reopened = PostgresStore(scoped)
        assert reopened.get_object(object_id) == batch.objects[0]
        assert reopened.get_relation(relation_id) == batch.relations[0]
        assert reopened.assertions_for(object_id) == tuple(
            sorted(batch.objects[0].assertions, key=lambda item: item.assertion_id.int)
        )
        reopened.close()
    finally:
        with psycopg.connect(conninfo, autocommit=True) as admin:
            admin.execute(sql.SQL("DROP SCHEMA {} CASCADE").format(sql.Identifier(schema_name)))

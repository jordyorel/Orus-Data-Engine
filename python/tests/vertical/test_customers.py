import os
from datetime import UTC, date, datetime
from pathlib import Path
from uuid import UUID, uuid4

import pytest

from orus_ontology import ObjectQuery, PropertyFilter, QueryService, RelationDirection, ValueTarget
from orus_ontology.vertical.customers import (
    CUSTOMER_TYPE_ID,
    ONTOLOGY_ID,
    customer_mapping,
    customer_ontology,
    customer_source_contract,
)


def test_customer_vertical_definitions_are_stable_and_compilable() -> None:
    ontology = customer_ontology()
    assert ontology.ontology_id == ONTOLOGY_ID
    customer = ontology.get_object_type("Customer")
    assert customer is not None
    assert customer.type_id == CUSTOMER_TYPE_ID
    assert len(ontology.object_types) == 3
    assert len(ontology.relation_types) == 2
    assert len(customer_source_contract().fields) == 12
    assert customer_mapping().mapping_id == UUID("8af80d1f-140a-5d42-8344-a86f7416ad71")


def test_real_customer_csv_streams_resumes_and_builds_queryable_graph(tmp_path: Path) -> None:
    conninfo = os.environ.get("ORUS_ONTOLOGY_TEST_POSTGRES")
    engine = os.environ.get("ORUS_DATA_ENGINE_BINARY")
    if conninfo is None or engine is None:
        pytest.skip("set PostgreSQL and Zig integration variables")
    psycopg = pytest.importorskip("psycopg")
    from psycopg import sql

    from orus_ontology.storage.postgres import PostgresStore
    from orus_ontology.vertical.importer import CustomerImporter

    csv_path = tmp_path / "customers.csv"
    csv_path.write_text(
        "Index,Customer Id,First Name,Last Name,Company,City,Country,Phone 1,"
        "Phone 2,Email,Subscription Date,Website\n"
        "1,C-1,Alice,Martin,Acme,Paris,France,+33-1,+33-2,alice@example.com,2020-01-02,"
        "https://example.com\n"
        "2,C-2,Bob,Martin,Acme,Lyon,France,+33-3,+33-4,bob@example.com,2020-02-03,"
        "https://example.org\n"
        "3,C-3,Chloe,Durand,Globex,Nantes,France,+33-5,+33-6,chloe@example.com,2020-03-04,"
        "https://example.net\n"
    )
    schema_name = f"orus_vertical_{uuid4().hex}"
    with psycopg.connect(conninfo, autocommit=True) as admin:
        admin.execute(sql.SQL("CREATE SCHEMA {}").format(sql.Identifier(schema_name)))
    scoped = f"{conninfo} options='-c search_path={schema_name}'"
    checkpoint = tmp_path / "checkpoint.json"
    run_id = UUID("aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")
    observed_at = datetime(2026, 8, 15, 12, tzinfo=UTC)
    try:
        with PostgresStore(scoped) as store:
            importer = CustomerImporter(store, engine)
            first = importer.run(
                csv_path,
                run_id=run_id,
                observed_at=observed_at,
                batch_size=1,
                max_rows=2,
                checkpoint_path=checkpoint,
            )
            second = importer.run(
                csv_path,
                run_id=run_id,
                observed_at=observed_at,
                batch_size=1,
                max_rows=1,
                checkpoint_path=checkpoint,
            )
            assert first.rows_processed == 2
            assert second.rows_processed == 1
            assert second.next_offset == 3
            assert second.store_statistics["objects"] == 8
            assert second.store_statistics["relations"] == 6
            assert second.store_statistics["assertions"] == 18

            service = QueryService(store)
            customer = service.find_objects(
                ObjectQuery(
                    object_type_id=CUSTOMER_TYPE_ID,
                    filters=(PropertyFilter(predicate="customer_id", value="C-3"),),
                )
            )[0]
            subscription = next(
                item
                for item in service.assertions(customer.object_id)
                if item.predicate == "subscription_date"
            )
            assert isinstance(subscription.target, ValueTarget)
            assert subscription.target.value == date(2020, 3, 4)
            assert (
                len(service.neighbors(customer.object_id, direction=RelationDirection.OUTGOING))
                == 2
            )
    finally:
        with psycopg.connect(conninfo, autocommit=True) as admin:
            admin.execute(sql.SQL("DROP SCHEMA {} CASCADE").format(sql.Identifier(schema_name)))

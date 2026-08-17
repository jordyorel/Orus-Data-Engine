import os
from collections.abc import Callable, Iterator
from datetime import UTC, datetime
from decimal import Decimal
from uuid import UUID, uuid4

import pytest

from orus_ontology import (
    BatchMaterializer,
    CanonicalRecord,
    FilterOperator,
    MappingCompiler,
    MappingDefinition,
    MemoryStore,
    ObjectQuery,
    OntologyDefinition,
    PropertyFilter,
    QueryService,
    RelationDirection,
    SourceContract,
    SourceReference,
    StorageError,
    TraversalHop,
    TraversalQuery,
)
from orus_ontology.storage import OntologyStore

NOW = datetime(2026, 8, 15, 12, tzinfo=UTC)
RUN_ID = UUID("aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")


def _record(row: int, customer_id: str, name: str, email: str) -> CanonicalRecord:
    return CanonicalRecord(
        values={
            "customer_id": customer_id,
            "customer_name": name,
            "email": email,
            "email_verified": True,
        },
        source=SourceReference(
            source_id="contract.csv",
            batch_id=0,
            row_id=row,
            global_offset=row,
            run_id=RUN_ID,
            observed_at=NOW,
        ),
    )


def _populated_store(
    request: pytest.FixtureRequest,
    ontology: OntologyDefinition,
    source_contract: SourceContract,
    mapping_definition: MappingDefinition,
) -> Iterator[OntologyStore]:
    plan = MappingCompiler.compile(mapping_definition, ontology, source_contract)
    records = (
        _record(0, "C-1", "Alice", "alice@example.com"),
        _record(1, "C-2", "Bob", "bob@example.com"),
        _record(2, "C-3", "Charlie", "charlie@example.com"),
    )
    batch = next(BatchMaterializer(plan, batch_size=3, recorded_at=NOW).materialize(records))
    backend = getattr(request, "param", "memory")
    cleanup: Callable[[], None] | None = None
    if backend == "postgres":
        conninfo = os.environ.get("ORUS_ONTOLOGY_TEST_POSTGRES")
        if conninfo is None:
            pytest.skip("set ORUS_ONTOLOGY_TEST_POSTGRES to run PostgreSQL contracts")
        psycopg = pytest.importorskip("psycopg")
        from psycopg import sql

        from orus_ontology.storage.postgres import PostgresStore

        schema_name = f"orus_test_{uuid4().hex}"
        with psycopg.connect(conninfo, autocommit=True) as admin:
            admin.execute(sql.SQL("CREATE SCHEMA {}").format(sql.Identifier(schema_name)))
        store: OntologyStore = PostgresStore(f"{conninfo} options='-c search_path={schema_name}'")

        def cleanup_store() -> None:
            assert isinstance(store, PostgresStore)
            store.close()
            with psycopg.connect(conninfo, autocommit=True) as admin:
                admin.execute(sql.SQL("DROP SCHEMA {} CASCADE").format(sql.Identifier(schema_name)))

        cleanup = cleanup_store

    else:
        store = MemoryStore()
    store.put_schema(ontology)
    for instance in batch.objects:
        store.put_object(instance)
    for relation in batch.relations:
        store.put_relation(relation)
    yield store
    if cleanup is not None:
        cleanup()


@pytest.fixture(params=("memory", "postgres"))
def contract_store(
    request: pytest.FixtureRequest,
    ontology: OntologyDefinition,
    source_contract: SourceContract,
    mapping_definition: MappingDefinition,
) -> Iterator[OntologyStore]:
    yield from _populated_store(request, ontology, source_contract, mapping_definition)


def test_memory_contract_is_idempotent_and_rejects_collisions(
    contract_store: OntologyStore,
) -> None:
    instance = contract_store.scan_objects(None, limit=1, offset=0)[0]
    contract_store.put_object(instance)
    changed = instance.model_copy(update={"object_type_id": UUID(int=1)})
    with pytest.raises(StorageError, match="unknown object type"):
        contract_store.put_object(changed)
    with pytest.raises(StorageError, match="bounded page"):
        contract_store.scan_objects(None, limit=0, offset=0)


@pytest.mark.parametrize(
    ("operator", "expected", "count"),
    [
        (FilterOperator.EQUALS, "Bob", 1),
        (FilterOperator.NOT_EQUALS, "Bob", 2),
        (FilterOperator.LESS_THAN, "Bob", 1),
        (FilterOperator.LESS_THAN_OR_EQUAL, "Bob", 2),
        (FilterOperator.GREATER_THAN, "Bob", 1),
        (FilterOperator.GREATER_THAN_OR_EQUAL, "Bob", 2),
        (FilterOperator.CONTAINS, "li", 2),
        (FilterOperator.IN, ("Alice", "Charlie"), 2),
    ],
)
def test_every_declared_filter_is_applied(
    contract_store: OntologyStore,
    ontology: OntologyDefinition,
    operator: FilterOperator,
    expected: object,
    count: int,
) -> None:
    customer_type = ontology.get_object_type("Customer")
    assert customer_type is not None
    result = QueryService(contract_store).find_objects(
        ObjectQuery(
            object_type_id=customer_type.type_id,
            filters=(PropertyFilter(predicate="name", operator=operator, value=expected),),
            limit=10,
        )
    )
    assert len(result) == count


def test_neighbors_provenance_and_bounded_traversal(contract_store: OntologyStore) -> None:
    service = QueryService(contract_store)
    customer = service.find_objects(
        ObjectQuery(filters=(PropertyFilter(predicate="customer_id", value="C-1"),))
    )[0]
    neighbors = service.neighbors(customer.object_id, direction=RelationDirection.OUTGOING)
    assert len(neighbors) == 1
    relation, email = neighbors[0]
    assert service.provenance(customer.object_id)[0].source_id == "contract.csv"
    assert service.provenance(relation.relation_id)[0].source_id == "contract.csv"
    assert email.object_id == relation.target_object_id
    traversal = service.traverse(
        TraversalQuery(
            start_object_id=customer.object_id,
            hops=(TraversalHop(direction=RelationDirection.OUTGOING),),
            limit=1,
        )
    )
    assert traversal.objects == (email,)
    assert traversal.relations == (relation,)


def test_relation_requires_existing_endpoints(contract_store: OntologyStore) -> None:
    customer = QueryService(contract_store).find_objects(
        ObjectQuery(filters=(PropertyFilter(predicate="customer_id", value="C-1"),))
    )[0]
    relation = contract_store.neighbors(
        customer.object_id,
        None,
        RelationDirection.OUTGOING,
        limit=1,
        offset=0,
    )[0]
    invalid = relation.model_copy(
        update={"target_object_id": UUID(int=42), "confidence": Decimal("1")}
    )
    with pytest.raises(StorageError, match="endpoint"):
        contract_store.put_relation(invalid)


def test_assertion_batch_rolls_back_atomically(contract_store: OntologyStore) -> None:
    instance = contract_store.scan_objects(None, limit=1, offset=0)[0]
    original = instance.assertions[0]
    valid = original.model_copy(update={"assertion_id": uuid4()})
    invalid = original.model_copy(update={"assertion_id": uuid4(), "subject_id": uuid4()})
    with pytest.raises(StorageError, match="unknown subject"):
        contract_store.put_assertions((valid, invalid))
    assert contract_store.get_assertion(valid.assertion_id) is None

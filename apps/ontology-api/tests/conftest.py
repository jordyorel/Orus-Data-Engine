import sys
from collections.abc import Iterator
from datetime import UTC, date, datetime
from pathlib import Path
from uuid import UUID

import pytest
from fastapi.testclient import TestClient
from orus_ontology import BatchMaterializer, CanonicalRecord, MappingCompiler, MemoryStore
from orus_ontology.assertions.provenance import SourceReference
from orus_ontology.vertical.customers import (
    customer_mapping,
    customer_ontology,
    customer_source_contract,
)

API_SRC = Path(__file__).parents[1] / "src"
if str(API_SRC) not in sys.path:
    sys.path.insert(0, str(API_SRC))

from orus_ontology_api import create_app  # noqa: E402


class TestStore(MemoryStore):
    __test__ = False

    def statistics(self) -> dict[str, int]:
        return {
            "schemas": len(self._schemas),
            "objects": len(self._objects),
            "relations": len(self._relations),
            "assertions": len(self._assertions),
            "resolutions": len(self._canonical),
        }


@pytest.fixture
def store() -> TestStore:
    result = TestStore()
    ontology = customer_ontology()
    result.put_schema(ontology)
    plan = MappingCompiler.compile(customer_mapping(), ontology, customer_source_contract())
    observed_at = datetime(2026, 8, 15, 12, tzinfo=UTC)
    source = SourceReference(
        source_id="fixtures/customer.csv",
        row_id=0,
        global_offset=0,
        run_id=UUID("aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"),
        observed_at=observed_at,
    )
    record = CanonicalRecord(
        values={
            "index": 1,
            "customer_id": "C-1",
            "first_name": "Alice",
            "last_name": "Martin",
            "company": "Acme",
            "city": "Paris",
            "country": "France",
            "phone_1": "+33-1",
            "phone_2": "+33-2",
            "email": "Alice@example.com",
            "subscription_date": date(2020, 1, 2),
            "website": "https://example.com",
        },
        source=source,
    )
    batch = next(
        BatchMaterializer(plan, batch_size=1, recorded_at=observed_at).materialize((record,))
    )
    for instance in batch.objects:
        result.put_object(instance)
    for relation in batch.relations:
        result.put_relation(relation)
    return result


@pytest.fixture
def client(store: TestStore) -> Iterator[TestClient]:
    with TestClient(create_app(store_factory=lambda: store)) as test_client:
        yield test_client

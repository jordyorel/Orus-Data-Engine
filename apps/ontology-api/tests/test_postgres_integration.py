import os

import pytest
from fastapi.testclient import TestClient
from orus_ontology.storage.postgres import PostgresStore
from orus_ontology.vertical.customers import CUSTOMER_TYPE_ID

from orus_ontology_api import create_app


def test_real_customer_store_is_queryable_over_http() -> None:
    conninfo = os.environ.get("ORUS_ONTOLOGY_API_TEST_POSTGRES")
    if conninfo is None:
        pytest.skip("set ORUS_ONTOLOGY_API_TEST_POSTGRES to run API integration")

    with TestClient(create_app(store_factory=lambda: PostgresStore(conninfo))) as client:
        statistics = client.get("/v1/statistics")
        search = client.post(
            "/v1/objects/search",
            json={
                "object_type_id": str(CUSTOMER_TYPE_ID),
                "filters": [{"predicate": "customer_id", "value": "4962FDBE6BFEE6D"}],
                "limit": 1,
            },
        )

    assert statistics.status_code == 200
    assert statistics.json()["objects"] >= 3
    assert search.status_code == 200
    assert len(search.json()["objects"]) == 1

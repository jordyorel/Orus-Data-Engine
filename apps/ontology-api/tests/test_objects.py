from fastapi.testclient import TestClient
from orus_ontology.vertical.customers import CUSTOMER_TYPE_ID


def test_search_and_read_customer_context(client: TestClient) -> None:
    search = client.post(
        "/v1/objects/search",
        json={
            "object_type_id": str(CUSTOMER_TYPE_ID),
            "filters": [{"predicate": "customer_id", "value": "C-1"}],
            "limit": 10,
        },
    )

    assert search.status_code == 200
    body = search.json()
    assert len(body["objects"]) == 1
    object_id = body["objects"][0]["object_id"]

    context = client.get(f"/v1/objects/{object_id}")

    assert context.status_code == 200
    predicates = {item["predicate"] for item in context.json()["assertions"]}
    assert predicates == {"customer_id", "first_name", "last_name", "subscription_date"}
    assert context.json()["provenance"][0]["global_offset"] == 0


def test_missing_object_is_not_found(client: TestClient) -> None:
    response = client.get("/v1/objects/00000000-0000-0000-0000-000000000000")

    assert response.status_code == 404
    assert response.json()["detail"] == "ontology object not found"


def test_search_limits_are_enforced_at_http_boundary(client: TestClient) -> None:
    response = client.post("/v1/objects/search", json={"limit": 201})

    assert response.status_code == 422

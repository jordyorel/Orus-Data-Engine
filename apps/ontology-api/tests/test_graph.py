from fastapi.testclient import TestClient
from orus_ontology.vertical.customers import CUSTOMER_TYPE_ID


def _customer_id(client: TestClient) -> str:
    response = client.post(
        "/v1/objects/search",
        json={
            "object_type_id": str(CUSTOMER_TYPE_ID),
            "filters": [{"predicate": "customer_id", "value": "C-1"}],
        },
    )
    return str(response.json()["objects"][0]["object_id"])


def test_neighbors_return_email_and_company(client: TestClient) -> None:
    object_id = _customer_id(client)

    response = client.get(
        f"/v1/objects/{object_id}/neighbors",
        params={"direction": "outgoing", "limit": 10},
    )

    assert response.status_code == 200
    assert len(response.json()["neighbors"]) == 2


def test_traversal_returns_a_bounded_graph(client: TestClient) -> None:
    object_id = _customer_id(client)

    response = client.post(
        "/v1/traversals",
        json={
            "start_object_id": object_id,
            "hops": [{"direction": "outgoing"}],
            "limit": 10,
        },
    )

    assert response.status_code == 200
    graph = response.json()
    assert graph["root"]["object_id"] == object_id
    assert len(graph["objects"]) == 2
    assert len(graph["relations"]) == 2
    assert graph["depth_reached"] == 1
    assert graph["truncated"] is False


def test_traversal_depth_is_capped(client: TestClient) -> None:
    object_id = _customer_id(client)
    hops = [{"direction": "outgoing"}] * 5

    response = client.post(
        "/v1/traversals",
        json={"start_object_id": object_id, "hops": hops},
    )

    assert response.status_code == 422

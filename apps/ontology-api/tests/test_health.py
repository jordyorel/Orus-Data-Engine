from typing import Never

from fastapi.testclient import TestClient
from orus_ontology import StorageError

from orus_ontology_api import create_app


def test_liveness_does_not_require_storage(client: TestClient) -> None:
    response = client.get("/health/live")

    assert response.status_code == 200
    assert response.json() == {"status": "ok"}


def test_readiness_and_statistics_verify_storage(client: TestClient) -> None:
    assert client.get("/health/ready").json() == {"status": "ready"}

    response = client.get("/v1/statistics")

    assert response.status_code == 200
    assert response.json() == {
        "schemas": 1,
        "objects": 3,
        "relations": 2,
        "assertions": 6,
        "resolutions": 0,
    }


def test_storage_failure_is_a_stable_service_unavailable_response() -> None:
    def unavailable() -> Never:
        raise StorageError("database unavailable", context={"retryable": True})

    with TestClient(create_app(store_factory=unavailable)) as client:
        response = client.get("/health/ready")

    assert response.status_code == 503
    assert response.json() == {
        "error": {
            "code": "storage_error",
            "message": "database unavailable",
            "context": {"retryable": True},
        }
    }


def test_local_explorer_origin_is_allowed(client: TestClient) -> None:
    response = client.options(
        "/v1/statistics",
        headers={
            "Origin": "http://127.0.0.1:5173",
            "Access-Control-Request-Method": "GET",
        },
    )

    assert response.status_code == 200
    assert response.headers["access-control-allow-origin"] == "http://127.0.0.1:5173"

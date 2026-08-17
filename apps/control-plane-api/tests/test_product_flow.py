import time
from pathlib import Path

from fastapi.testclient import TestClient

from orus_control_plane_api import create_app
from orus_control_plane_api.config import Settings


def test_project_upload_profile_and_report(client: TestClient) -> None:
    project_response = client.post("/v1/projects", json={"name": "Revenue quality"})
    assert project_response.status_code == 201
    project_id = project_response.json()["project_id"]

    source_response = client.post(
        f"/v1/projects/{project_id}/sources",
        files={"file": ("revenue.csv", b"id,amount\n1,10.50\n2,20.00\n", "text/csv")},
    )
    assert source_response.status_code == 201
    source = source_response.json()
    assert source["size_bytes"] == 26
    assert len(source["sha256"]) == 64

    preview = client.get(f"/v1/sources/{source['source_id']}/preview?limit=1")
    assert preview.json() == {
        "columns": ["id", "amount"],
        "rows": [["1", "10.50"]],
        "truncated": True,
    }

    run_response = client.post(f"/v1/sources/{source['source_id']}/profile-runs")
    assert run_response.status_code == 202
    run_id = run_response.json()["run_id"]
    status = "queued"
    for _ in range(100):
        run = client.get(f"/v1/profile-runs/{run_id}").json()
        status = run["status"]
        if status in {"succeeded", "failed"}:
            break
        time.sleep(0.01)
    assert status == "succeeded"

    report = client.get(f"/v1/profile-runs/{run_id}/report")
    assert report.status_code == 200
    assert report.json()["rows_processed"] == 2
    assert report.json()["columns"][0]["name"] == "id"


def test_upload_rejects_non_csv_and_unknown_project(client: TestClient) -> None:
    missing = client.post(
        "/v1/projects/00000000-0000-0000-0000-000000000000/sources",
        files={"file": ("data.csv", b"id\n1\n", "text/csv")},
    )
    assert missing.status_code == 404

    project_id = client.post("/v1/projects", json={"name": "Project"}).json()["project_id"]
    unsupported = client.post(
        f"/v1/projects/{project_id}/sources",
        files={"file": ("data.json", b"{}", "application/json")},
    )
    assert unsupported.status_code == 415


def test_metadata_survives_application_recreation(
    client: TestClient, settings: Settings
) -> None:
    client.post("/v1/projects", json={"name": "Persistent project"})

    with TestClient(create_app(settings)) as restarted:
        projects = restarted.get("/v1/projects")

    assert projects.status_code == 200
    assert projects.json()[0]["name"] == "Persistent project"


def test_failed_engine_is_persisted_and_has_no_report(tmp_path: Path) -> None:
    engine = tmp_path / "failing-engine"
    engine.write_text("#!/bin/sh\necho broken >&2\nexit 2\n", encoding="utf-8")
    engine.chmod(0o755)
    settings = Settings(data_dir=tmp_path / "failed-data", engine_path=engine)
    with TestClient(create_app(settings)) as client:
        project = client.post("/v1/projects", json={"name": "Failure"}).json()
        source = client.post(
            f"/v1/projects/{project['project_id']}/sources",
            files={"file": ("data.csv", b"id\n1\n", "text/csv")},
        ).json()
        run = client.post(f"/v1/sources/{source['source_id']}/profile-runs").json()
        for _ in range(100):
            run = client.get(f"/v1/profile-runs/{run['run_id']}").json()
            if run["status"] == "failed":
                break
            time.sleep(0.01)

        assert run["status"] == "failed"
        assert "broken" in run["error"]
        assert client.get(f"/v1/profile-runs/{run['run_id']}/report").status_code == 409

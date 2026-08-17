"""FastAPI application for the Orus product control plane."""

# pyright: reportUnusedFunction=false

import csv
import hashlib
import json
from collections.abc import AsyncGenerator
from contextlib import asynccontextmanager
from datetime import UTC, datetime
from pathlib import Path
from typing import Annotated, cast
from uuid import UUID, uuid4

from fastapi import FastAPI, File, HTTPException, Query, UploadFile
from fastapi.middleware.cors import CORSMiddleware

from orus_control_plane_api.config import Settings
from orus_control_plane_api.jobs import ProfileRunner
from orus_control_plane_api.models import (
    ProfileReport,
    ProfileRun,
    Project,
    ProjectCreate,
    RunStatus,
    Source,
    SourcePreview,
)
from orus_control_plane_api.store import ControlStore


def create_app(settings: Settings | None = None) -> FastAPI:
    resolved = settings or Settings.from_environment()
    resolved.data_dir.mkdir(parents=True, exist_ok=True)
    store = ControlStore(resolved.data_dir / "control.sqlite3")
    runner = ProfileRunner(
        store,
        resolved.engine_path,
        resolved.data_dir / "artifacts",
        resolved.batch_size,
        resolved.profile_timeout_seconds,
    )

    @asynccontextmanager
    async def lifespan(_: FastAPI) -> AsyncGenerator[None]:
        yield
        runner.close()

    app = FastAPI(title="Orus Control Plane", version="0.1.0", lifespan=lifespan)
    app.state.store = store
    app.state.runner = runner
    app.state.settings = resolved
    app.add_middleware(
        CORSMiddleware,
        allow_origins=list(resolved.cors_origins),
        allow_methods=["GET", "POST", "OPTIONS"],
        allow_headers=["Content-Type"],
    )

    @app.get("/health/ready")
    def ready() -> dict[str, str]:
        if not resolved.engine_path.is_file():
            raise HTTPException(503, "Orus Data Engine binary is unavailable")
        return {"status": "ready"}

    @app.post("/v1/projects", response_model=Project, status_code=201)
    def create_project(body: ProjectCreate) -> Project:
        project = Project(project_id=uuid4(), name=body.name.strip(), created_at=datetime.now(UTC))
        store.create_project(project)
        return project

    @app.get("/v1/projects", response_model=list[Project])
    def list_projects() -> tuple[Project, ...]:
        return store.list_projects()

    @app.post("/v1/projects/{project_id}/sources", response_model=Source, status_code=201)
    async def upload_source(
        project_id: UUID,
        file: Annotated[UploadFile, File()],
    ) -> Source:
        if store.get_project(project_id) is None:
            raise HTTPException(404, "project not found")
        filename = Path(file.filename or "").name
        if not filename.lower().endswith(".csv"):
            raise HTTPException(415, "only CSV sources are supported in product phase P1")
        source_id = uuid4()
        source_dir = resolved.data_dir / "sources" / str(project_id)
        source_dir.mkdir(parents=True, exist_ok=True)
        final_path = source_dir / f"{source_id}.csv"
        temporary = final_path.with_suffix(".upload")
        digest = hashlib.sha256()
        size = 0
        try:
            with temporary.open("xb") as output:
                while chunk := await file.read(1024 * 1024):
                    size += len(chunk)
                    if size > resolved.max_upload_bytes:
                        raise HTTPException(413, "source exceeds the configured upload limit")
                    digest.update(chunk)
                    output.write(chunk)
            temporary.replace(final_path)
        except Exception:
            temporary.unlink(missing_ok=True)
            raise
        finally:
            await file.close()
        source = Source(
            source_id=source_id,
            project_id=project_id,
            filename=filename,
            media_type="text/csv",
            size_bytes=size,
            sha256=digest.hexdigest(),
            created_at=datetime.now(UTC),
        )
        store.create_source(source, final_path)
        return source

    @app.get("/v1/projects/{project_id}/sources", response_model=list[Source])
    def list_sources(project_id: UUID) -> tuple[Source, ...]:
        if store.get_project(project_id) is None:
            raise HTTPException(404, "project not found")
        return store.list_sources(project_id)

    @app.get("/v1/sources/{source_id}/preview", response_model=SourcePreview)
    def preview_source(
        source_id: UUID,
        limit: Annotated[int, Query(ge=1, le=50)] = 10,
    ) -> SourcePreview:
        stored = store.get_source(source_id)
        if stored is None:
            raise HTTPException(404, "source not found")
        _, path = stored
        with path.open(newline="", encoding="utf-8-sig") as stream:
            reader = csv.reader(stream)
            columns = next(reader, cast(list[str], []))
            rows: list[list[str]] = []
            for _, row in zip(range(limit + 1), reader, strict=False):
                rows.append(row)
        return SourcePreview(columns=columns, rows=rows[:limit], truncated=len(rows) > limit)

    @app.post("/v1/sources/{source_id}/profile-runs", response_model=ProfileRun, status_code=202)
    def start_profile(source_id: UUID) -> ProfileRun:
        stored = store.get_source(source_id)
        if stored is None:
            raise HTTPException(404, "source not found")
        if not resolved.engine_path.is_file():
            raise HTTPException(503, "Orus Data Engine binary is unavailable")
        run = ProfileRun(
            run_id=uuid4(), source_id=source_id, status=RunStatus.QUEUED,
            created_at=datetime.now(UTC),
        )
        store.create_run(run)
        runner.submit(run.run_id, stored[1])
        return run

    @app.get("/v1/sources/{source_id}/profile-runs", response_model=list[ProfileRun])
    def list_runs(source_id: UUID) -> tuple[ProfileRun, ...]:
        if store.get_source(source_id) is None:
            raise HTTPException(404, "source not found")
        return store.list_runs(source_id)

    @app.get("/v1/profile-runs/{run_id}", response_model=ProfileRun)
    def get_run(run_id: UUID) -> ProfileRun:
        stored = store.get_run(run_id)
        if stored is None:
            raise HTTPException(404, "profile run not found")
        return stored[0]

    @app.get("/v1/profile-runs/{run_id}/report", response_model=ProfileReport)
    def get_report(run_id: UUID) -> ProfileReport:
        stored = store.get_run(run_id)
        if stored is None:
            raise HTTPException(404, "profile run not found")
        run, path = stored
        if run.status is not RunStatus.SUCCEEDED or path is None:
            raise HTTPException(409, "profile report is not available")
        return ProfileReport.model_validate(json.loads(path.read_text(encoding="utf-8")))

    return app

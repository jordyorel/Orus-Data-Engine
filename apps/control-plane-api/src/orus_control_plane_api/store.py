"""SQLite metadata store with short, explicit transactions."""

import sqlite3
from datetime import UTC, datetime
from pathlib import Path
from uuid import UUID

from orus_control_plane_api.models import ProfileRun, Project, RunStatus, Source


class ControlStore:
    def __init__(self, path: Path) -> None:
        self._path = path
        path.parent.mkdir(parents=True, exist_ok=True)
        self._migrate()

    def _connect(self) -> sqlite3.Connection:
        connection = sqlite3.connect(self._path, timeout=30)
        connection.row_factory = sqlite3.Row
        connection.execute("PRAGMA foreign_keys = ON")
        connection.execute("PRAGMA journal_mode = WAL")
        return connection

    def _migrate(self) -> None:
        with self._connect() as connection:
            connection.executescript(
                """
                CREATE TABLE IF NOT EXISTS projects (
                    project_id TEXT PRIMARY KEY, name TEXT NOT NULL, created_at TEXT NOT NULL
                );
                CREATE TABLE IF NOT EXISTS sources (
                    source_id TEXT PRIMARY KEY,
                    project_id TEXT NOT NULL REFERENCES projects(project_id),
                    filename TEXT NOT NULL, media_type TEXT NOT NULL,
                    size_bytes INTEGER NOT NULL, sha256 TEXT NOT NULL,
                    storage_path TEXT NOT NULL UNIQUE, created_at TEXT NOT NULL
                );
                CREATE INDEX IF NOT EXISTS sources_project ON sources(project_id, created_at);
                CREATE TABLE IF NOT EXISTS profile_runs (
                    run_id TEXT PRIMARY KEY,
                    source_id TEXT NOT NULL REFERENCES sources(source_id),
                    status TEXT NOT NULL, report_path TEXT,
                    created_at TEXT NOT NULL, started_at TEXT, completed_at TEXT, error TEXT
                );
                CREATE INDEX IF NOT EXISTS runs_source ON profile_runs(source_id, created_at);
                """
            )
            connection.execute(
                "UPDATE profile_runs SET status = ?, completed_at = ?, error = ? "
                "WHERE status IN (?, ?)",
                (
                    RunStatus.FAILED,
                    _now(),
                    "control plane restarted before the run completed",
                    RunStatus.QUEUED,
                    RunStatus.RUNNING,
                ),
            )

    def create_project(self, project: Project) -> None:
        with self._connect() as connection:
            connection.execute(
                "INSERT INTO projects VALUES (?, ?, ?)",
                (str(project.project_id), project.name, project.created_at.isoformat()),
            )

    def list_projects(self) -> tuple[Project, ...]:
        with self._connect() as connection:
            rows = connection.execute("SELECT * FROM projects ORDER BY created_at DESC").fetchall()
        return tuple(_project(row) for row in rows)

    def get_project(self, project_id: UUID) -> Project | None:
        with self._connect() as connection:
            row = connection.execute(
                "SELECT * FROM projects WHERE project_id = ?", (str(project_id),)
            ).fetchone()
        return _project(row) if row else None

    def create_source(self, source: Source, storage_path: Path) -> None:
        with self._connect() as connection:
            connection.execute(
                "INSERT INTO sources VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
                (
                    str(source.source_id), str(source.project_id), source.filename,
                    source.media_type, source.size_bytes, source.sha256, str(storage_path),
                    source.created_at.isoformat(),
                ),
            )

    def list_sources(self, project_id: UUID) -> tuple[Source, ...]:
        with self._connect() as connection:
            rows = connection.execute(
                "SELECT * FROM sources WHERE project_id = ? ORDER BY created_at DESC",
                (str(project_id),),
            ).fetchall()
        return tuple(_source(row) for row in rows)

    def get_source(self, source_id: UUID) -> tuple[Source, Path] | None:
        with self._connect() as connection:
            row = connection.execute(
                "SELECT * FROM sources WHERE source_id = ?", (str(source_id),)
            ).fetchone()
        return (_source(row), Path(str(row["storage_path"]))) if row else None

    def create_run(self, run: ProfileRun) -> None:
        with self._connect() as connection:
            connection.execute(
                "INSERT INTO profile_runs "
                "(run_id, source_id, status, created_at) VALUES (?, ?, ?, ?)",
                (str(run.run_id), str(run.source_id), run.status, run.created_at.isoformat()),
            )

    def update_run(
        self,
        run_id: UUID,
        status: RunStatus,
        *,
        report_path: Path | None = None,
        error: str | None = None,
    ) -> None:
        now = _now()
        with self._connect() as connection:
            if status is RunStatus.RUNNING:
                connection.execute(
                    "UPDATE profile_runs SET status = ?, started_at = ? WHERE run_id = ?",
                    (status, now, str(run_id)),
                )
            else:
                connection.execute(
                    "UPDATE profile_runs SET status = ?, completed_at = ?, report_path = ?, "
                    "error = ? WHERE run_id = ?",
                    (status, now, str(report_path) if report_path else None, error, str(run_id)),
                )

    def get_run(self, run_id: UUID) -> tuple[ProfileRun, Path | None] | None:
        with self._connect() as connection:
            row = connection.execute(
                "SELECT * FROM profile_runs WHERE run_id = ?", (str(run_id),)
            ).fetchone()
        if row is None:
            return None
        report_path = Path(str(row["report_path"])) if row["report_path"] else None
        return _run(row), report_path

    def list_runs(self, source_id: UUID) -> tuple[ProfileRun, ...]:
        with self._connect() as connection:
            rows = connection.execute(
                "SELECT * FROM profile_runs WHERE source_id = ? ORDER BY created_at DESC",
                (str(source_id),),
            ).fetchall()
        return tuple(_run(row) for row in rows)


def _now() -> str:
    return datetime.now(UTC).isoformat()


def _project(row: sqlite3.Row) -> Project:
    return Project(
        project_id=UUID(row["project_id"]),
        name=row["name"],
        created_at=row["created_at"],
    )


def _source(row: sqlite3.Row) -> Source:
    return Source(
        source_id=UUID(row["source_id"]), project_id=UUID(row["project_id"]),
        filename=row["filename"], media_type=row["media_type"],
        size_bytes=row["size_bytes"], sha256=row["sha256"], created_at=row["created_at"],
    )


def _run(row: sqlite3.Row) -> ProfileRun:
    return ProfileRun(
        run_id=UUID(row["run_id"]), source_id=UUID(row["source_id"]), status=row["status"],
        created_at=row["created_at"], started_at=row["started_at"],
        completed_at=row["completed_at"], error=row["error"],
    )

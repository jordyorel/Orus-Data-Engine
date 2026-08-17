"""Bounded background execution of Orus Data Engine commands."""

import json
import subprocess
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from uuid import UUID

from orus_control_plane_api.models import ProfileReport, RunStatus
from orus_control_plane_api.store import ControlStore


class ProfileRunner:
    def __init__(
        self,
        store: ControlStore,
        engine_path: Path,
        artifact_dir: Path,
        batch_size: int,
        timeout_seconds: int,
    ) -> None:
        self._store = store
        self._engine_path = engine_path
        self._artifact_dir = artifact_dir
        self._batch_size = batch_size
        self._timeout_seconds = timeout_seconds
        self._executor = ThreadPoolExecutor(max_workers=2, thread_name_prefix="orus-profile")
        artifact_dir.mkdir(parents=True, exist_ok=True)

    def submit(self, run_id: UUID, source_path: Path) -> None:
        self._executor.submit(self._execute, run_id, source_path)

    def close(self) -> None:
        self._executor.shutdown(wait=False, cancel_futures=False)

    def _execute(self, run_id: UUID, source_path: Path) -> None:
        self._store.update_run(run_id, RunStatus.RUNNING)
        try:
            process = subprocess.run(
                [str(self._engine_path), "profile", str(source_path), str(self._batch_size)],
                check=False,
                capture_output=True,
                text=True,
                timeout=self._timeout_seconds,
            )
            if process.returncode != 0:
                detail = process.stderr.strip()[-4000:] or (
                    f"engine exited with {process.returncode}"
                )
                self._store.update_run(run_id, RunStatus.FAILED, error=detail)
                return
            document = json.loads(process.stdout)
            ProfileReport.model_validate(document)
            final_path = self._artifact_dir / f"{run_id}.profile.json"
            temporary = final_path.with_suffix(".tmp")
            temporary.write_text(json.dumps(document, indent=2), encoding="utf-8")
            temporary.replace(final_path)
            self._store.update_run(run_id, RunStatus.SUCCEEDED, report_path=final_path)
        except subprocess.TimeoutExpired:
            self._store.update_run(
                run_id,
                RunStatus.FAILED,
                error=f"profiling exceeded {self._timeout_seconds} seconds",
            )
        except Exception as error:
            self._store.update_run(run_id, RunStatus.FAILED, error=str(error)[:4000])

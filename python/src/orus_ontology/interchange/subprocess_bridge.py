"""Deadlock-safe streaming subprocess boundary for Orus Data Engine."""

import os
import subprocess
from collections import deque
from collections.abc import Iterator, Mapping, Sequence
from enum import StrEnum
from pathlib import Path
from threading import Thread

from orus_ontology.errors import BridgeError
from orus_ontology.interchange.jsonl import read_jsonl
from orus_ontology.materialization.batch import CanonicalRecord


class RunStatus(StrEnum):
    RUNNING = "running"
    COMPLETE = "complete"
    FAILED = "failed"


class BridgeRun:
    def __init__(self, process: subprocess.Popen[bytes], *, max_line_bytes: int) -> None:
        if process.stdout is None or process.stderr is None:
            raise ValueError("bridge process requires stdout and stderr pipes")
        self._process = process
        self._max_line_bytes = max_line_bytes
        self._stderr_chunks: deque[bytes] = deque(maxlen=64)
        self._stderr_thread = Thread(target=self._drain_stderr, daemon=True)
        self._stderr_thread.start()
        self.status = RunStatus.RUNNING
        self.records_emitted = 0
        self.return_code: int | None = None
        self._iterated = False

    @property
    def records_valid(self) -> bool:
        return self.status is RunStatus.COMPLETE

    @property
    def stderr(self) -> str:
        return b"".join(self._stderr_chunks).decode(errors="replace")

    def __iter__(self) -> Iterator[CanonicalRecord]:
        if self._iterated:
            raise BridgeError("bridge output can only be consumed once")
        self._iterated = True
        try:
            assert self._process.stdout is not None
            for record in read_jsonl(self._process.stdout, max_line_bytes=self._max_line_bytes):
                self.records_emitted += 1
                yield record
        except BaseException:
            self._stop()
            self.status = RunStatus.FAILED
            raise
        self.return_code = self._process.wait()
        self._stderr_thread.join()
        if self.return_code != 0:
            self.status = RunStatus.FAILED
            raise BridgeError(
                "Orus Data Engine process failed; emitted records are invalid",
                context={
                    "return_code": self.return_code,
                    "records_emitted": self.records_emitted,
                    "stderr": self.stderr,
                },
            )
        self.status = RunStatus.COMPLETE

    def _drain_stderr(self) -> None:
        assert self._process.stderr is not None
        while chunk := self._process.stderr.read(4096):
            self._stderr_chunks.append(chunk)

    def _stop(self) -> None:
        if self._process.poll() is None:
            self._process.terminate()
        self.return_code = self._process.wait()
        self._stderr_thread.join()


class SubprocessBridge:
    def __init__(
        self,
        executable: str | Path,
        *,
        cwd: str | Path | None = None,
        environment: Mapping[str, str] | None = None,
        max_line_bytes: int = 16 * 1024 * 1024,
    ) -> None:
        self._executable = str(executable)
        self._cwd = str(cwd) if cwd is not None else None
        self._environment = {**os.environ, **environment} if environment is not None else None
        self._max_line_bytes = max_line_bytes

    def run(self, arguments: Sequence[str]) -> BridgeRun:
        try:
            process = subprocess.Popen(
                [self._executable, *arguments],
                cwd=self._cwd,
                env=self._environment,
                stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
            )
        except OSError as error:
            raise BridgeError(
                "failed to start Orus Data Engine",
                context={"executable": self._executable, "detail": str(error)},
            ) from error
        return BridgeRun(process, max_line_bytes=self._max_line_bytes)

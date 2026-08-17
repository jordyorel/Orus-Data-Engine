"""Control-plane configuration."""

import os
from pathlib import Path

from pydantic import BaseModel, ConfigDict, Field


class Settings(BaseModel):
    model_config = ConfigDict(frozen=True, extra="forbid")

    data_dir: Path
    engine_path: Path
    max_upload_bytes: int = Field(default=10 * 1024 * 1024 * 1024, ge=1)
    batch_size: int = Field(default=8192, ge=1, le=1_000_000)
    profile_timeout_seconds: int = Field(default=6 * 60 * 60, ge=1)
    host: str = "127.0.0.1"
    port: int = Field(default=8081, ge=1, le=65_535)
    cors_origins: tuple[str, ...] = ("http://127.0.0.1:5174", "http://localhost:5174")

    @classmethod
    def from_environment(cls) -> "Settings":
        root = Path(__file__).resolve().parents[4]
        return cls(
            data_dir=Path(
                os.environ.get("ORUS_CONTROL_DATA_DIR", root / ".orus-control")
            ).resolve(),
            engine_path=Path(
                os.environ.get("ORUS_CONTROL_ENGINE", root / "zig-out/bin/orusdata")
            ).resolve(),
            max_upload_bytes=int(
                os.environ.get("ORUS_CONTROL_MAX_UPLOAD_BYTES", str(10 * 1024**3))
            ),
            batch_size=int(os.environ.get("ORUS_CONTROL_BATCH_SIZE", "8192")),
            profile_timeout_seconds=int(
                os.environ.get("ORUS_CONTROL_PROFILE_TIMEOUT_SECONDS", str(6 * 60 * 60))
            ),
            host=os.environ.get("ORUS_CONTROL_HOST", "127.0.0.1"),
            port=int(os.environ.get("ORUS_CONTROL_PORT", "8081")),
        )

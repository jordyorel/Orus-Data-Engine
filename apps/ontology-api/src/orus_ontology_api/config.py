"""Environment-backed API configuration."""

import os

from pydantic import BaseModel, ConfigDict, Field


class Settings(BaseModel):
    model_config = ConfigDict(frozen=True, extra="forbid")

    postgres_dsn: str = Field(min_length=1)
    host: str = Field(default="127.0.0.1", min_length=1)
    port: int = Field(default=8080, ge=1, le=65_535)
    log_level: str = Field(default="info", pattern="^(critical|error|warning|info|debug|trace)$")
    cors_origins: tuple[str, ...] = ("http://127.0.0.1:5173", "http://localhost:5173")

    @classmethod
    def from_environment(cls) -> "Settings":
        return cls(
            postgres_dsn=os.environ.get(
                "ORUS_ONTOLOGY_API_POSTGRES_DSN",
                "host=/tmp port=55439 dbname=postgres",
            ),
            host=os.environ.get("ORUS_ONTOLOGY_API_HOST", "127.0.0.1"),
            port=int(os.environ.get("ORUS_ONTOLOGY_API_PORT", "8080")),
            log_level=os.environ.get("ORUS_ONTOLOGY_API_LOG_LEVEL", "info"),
            cors_origins=tuple(
                item.strip()
                for item in os.environ.get(
                    "ORUS_ONTOLOGY_API_CORS_ORIGINS",
                    "http://127.0.0.1:5173,http://localhost:5173",
                ).split(",")
                if item.strip()
            ),
        )

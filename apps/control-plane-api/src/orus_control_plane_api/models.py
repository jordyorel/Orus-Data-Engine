"""Stable control-plane HTTP models."""

from datetime import datetime
from enum import StrEnum
from typing import Any
from uuid import UUID

from pydantic import BaseModel, ConfigDict, Field


class ApiModel(BaseModel):
    model_config = ConfigDict(extra="forbid")


class RunStatus(StrEnum):
    QUEUED = "queued"
    RUNNING = "running"
    SUCCEEDED = "succeeded"
    FAILED = "failed"


class ProjectCreate(ApiModel):
    name: str = Field(min_length=1, max_length=120)


class Project(ApiModel):
    project_id: UUID
    name: str
    created_at: datetime


class Source(ApiModel):
    source_id: UUID
    project_id: UUID
    filename: str
    media_type: str
    size_bytes: int = Field(ge=0)
    sha256: str
    created_at: datetime


class ProfileRun(ApiModel):
    run_id: UUID
    source_id: UUID
    status: RunStatus
    created_at: datetime
    started_at: datetime | None = None
    completed_at: datetime | None = None
    error: str | None = None


class ProfileReport(ApiModel):
    columns: list[dict[str, Any]]
    rows_processed: int
    batches_processed: int
    source_id: int
    schema_hash: int


class SourcePreview(ApiModel):
    columns: list[str]
    rows: list[list[str]]
    truncated: bool

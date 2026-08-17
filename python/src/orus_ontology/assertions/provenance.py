"""Source references carried by observed and derived assertions."""

from datetime import datetime
from uuid import UUID

from pydantic import Field, field_validator, model_validator

from orus_ontology._schema import ImmutableModel
from orus_ontology.assertions.temporal import normalize_utc


class SourceReference(ImmutableModel):
    """Stable pointer from an assertion back to a canonical source record."""

    source_id: str
    source_version: str | None = None
    batch_id: int | None = Field(default=None, ge=0)
    row_id: int | None = Field(default=None, ge=0)
    global_offset: int | None = Field(default=None, ge=0)
    source_column: str | None = None
    run_id: UUID
    transformation_ids: tuple[str, ...] = ()
    observed_at: datetime
    checksum: str | None = None

    @field_validator("source_id")
    @classmethod
    def validate_source_id(cls, value: str) -> str:
        if not value.strip():
            raise ValueError("source_id must not be blank")
        return value

    @field_validator("source_version", "source_column", "checksum")
    @classmethod
    def reject_blank_optional_text(cls, value: str | None) -> str | None:
        if value is not None and not value.strip():
            raise ValueError("optional provenance text must not be blank")
        return value

    @field_validator("transformation_ids")
    @classmethod
    def validate_transformations(cls, values: tuple[str, ...]) -> tuple[str, ...]:
        if any(not value.strip() for value in values):
            raise ValueError("transformation IDs must not be blank")
        if len(values) != len(set(values)):
            raise ValueError("transformation IDs must be unique")
        return values

    @field_validator("observed_at")
    @classmethod
    def normalize_observed_at(cls, value: datetime) -> datetime:
        return normalize_utc(value)

    @model_validator(mode="after")
    def require_record_position(self) -> "SourceReference":
        if self.row_id is None and self.global_offset is None:
            raise ValueError("source reference requires row_id or global_offset")
        return self

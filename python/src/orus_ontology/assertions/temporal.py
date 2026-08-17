"""Temporal dimensions shared by ontology assertions."""

from datetime import UTC, datetime

from pydantic import Field, field_validator, model_validator

from orus_ontology._schema import ImmutableModel


def normalize_utc(value: datetime) -> datetime:
    """Require timezone-aware input and normalize it to UTC."""
    if value.tzinfo is None or value.utcoffset() is None:
        raise ValueError("datetime must include a timezone")
    return value.astimezone(UTC)


class TemporalContext(ImmutableModel):
    """Observation, business validity, and recording times for an assertion."""

    observed_at: datetime
    valid_from: datetime | None = None
    valid_to: datetime | None = None
    recorded_at: datetime = Field(default_factory=lambda: datetime.now(UTC))

    @field_validator("observed_at", "valid_from", "valid_to", "recorded_at")
    @classmethod
    def normalize_datetime(cls, value: datetime | None) -> datetime | None:
        return normalize_utc(value) if value is not None else None

    @model_validator(mode="after")
    def validate_interval(self) -> "TemporalContext":
        if self.recorded_at < self.observed_at:
            raise ValueError("recorded_at must not be before observed_at")
        if (
            self.valid_from is not None
            and self.valid_to is not None
            and self.valid_from > self.valid_to
        ):
            raise ValueError("valid_from must not be after valid_to")
        return self

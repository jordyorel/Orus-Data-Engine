"""Explicit declarations covering breaking ontology changes."""

from enum import StrEnum
from uuid import UUID, uuid4

from pydantic import Field, field_validator, model_validator

from orus_ontology._schema import SchemaModel
from orus_ontology.registry.version import VersionDiff


class MigrationStrategy(StrEnum):
    RENAME = "rename"
    DEFAULT = "default"
    TRANSFORM = "transform"
    DROP = "drop"
    MANUAL = "manual"


class MigrationStep(SchemaModel):
    """Declared handling strategy for one breaking change path."""

    change_path: str
    strategy: MigrationStrategy
    description: str

    @field_validator("change_path", "description")
    @classmethod
    def reject_blank_text(cls, value: str) -> str:
        if not value.strip():
            raise ValueError("migration step fields must not be blank")
        return value


class MigrationPlan(SchemaModel):
    """Immutable migration declaration between consecutive schema versions."""

    migration_id: UUID = Field(default_factory=uuid4)
    ontology_id: UUID
    from_version: int = Field(ge=1)
    to_version: int = Field(ge=2)
    steps: tuple[MigrationStep, ...]

    @model_validator(mode="after")
    def validate_plan(self) -> "MigrationPlan":
        if self.to_version != self.from_version + 1:
            raise ValueError("migration versions must be consecutive")
        if not self.steps:
            raise ValueError("migration plan must contain at least one step")
        paths = [step.change_path for step in self.steps]
        if len(paths) != len(set(paths)):
            raise ValueError("migration change paths must be unique")
        return self

    def validate_coverage(self, diff: VersionDiff) -> None:
        expected = {change.path for change in diff.breaking_changes}
        declared = {step.change_path for step in self.steps}
        missing = expected - declared
        unknown = declared - expected
        if missing or unknown:
            details: list[str] = []
            if missing:
                details.append(f"missing paths: {', '.join(sorted(missing))}")
            if unknown:
                details.append(f"unknown paths: {', '.join(sorted(unknown))}")
            raise ValueError("invalid migration coverage; " + "; ".join(details))

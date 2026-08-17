"""Internal primitives enforcing schema naming and deep immutability."""

import re
from collections.abc import Mapping, Sequence
from decimal import Decimal
from math import isfinite
from types import MappingProxyType
from typing import cast

from pydantic import BaseModel, ConfigDict, Field, field_serializer, field_validator

TECHNICAL_NAME = re.compile(r"^[A-Za-z][A-Za-z0-9_]*$")


def validate_technical_name(value: str, *, field_name: str) -> str:
    if not TECHNICAL_NAME.fullmatch(value):
        raise ValueError(
            f"{field_name} must start with a letter and contain only letters, digits, "
            "or underscores"
        )
    return value


def freeze_json(value: object) -> object:
    """Copy JSON-compatible input into deeply immutable containers."""
    if value is None or isinstance(value, str | bool | int):
        return value
    if isinstance(value, float):
        if not isfinite(value):
            raise ValueError("JSON numbers must be finite")
        return value
    if isinstance(value, Decimal):
        raise ValueError("Decimal is not a JSON metadata value")
    if isinstance(value, Mapping):
        mapping = cast(Mapping[object, object], value)
        frozen: dict[str, object] = {}
        for key, item in mapping.items():
            if not isinstance(key, str):
                raise ValueError("JSON object keys must be strings")
            frozen[key] = freeze_json(item)
        return MappingProxyType(frozen)
    if isinstance(value, list | tuple):
        sequence = cast(Sequence[object], value)
        return tuple(freeze_json(item) for item in sequence)
    raise ValueError(f"value of type '{type(value).__name__}' is not JSON-compatible")


def thaw_json(value: object) -> object:
    """Convert immutable JSON containers to serialization-friendly containers."""
    if isinstance(value, Mapping):
        mapping = cast(Mapping[str, object], value)
        return {key: thaw_json(item) for key, item in mapping.items()}
    if isinstance(value, tuple):
        sequence = cast(Sequence[object], value)
        return [thaw_json(item) for item in sequence]
    return value


class ImmutableModel(BaseModel):
    """Deeply immutable base for ontology contracts with JSON metadata."""

    model_config = ConfigDict(
        frozen=True,
        extra="forbid",
        arbitrary_types_allowed=True,
        validate_default=True,
    )

    metadata: Mapping[str, object] = Field(default_factory=dict)

    @field_validator("metadata", mode="after")
    @classmethod
    def freeze_metadata(cls, value: Mapping[str, object]) -> Mapping[str, object]:
        frozen = freeze_json(value)
        if not isinstance(frozen, Mapping):
            raise ValueError("metadata must be a JSON object")
        return cast(Mapping[str, object], frozen)

    @field_serializer("metadata")
    def serialize_metadata(self, value: Mapping[str, object]) -> dict[str, object]:
        return {key: thaw_json(item) for key, item in value.items()}


class SchemaModel(ImmutableModel):
    """Marker base for versioned schema declarations."""

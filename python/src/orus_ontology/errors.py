"""Stable exception hierarchy for Orus Ontology boundaries."""

from collections.abc import Mapping
from enum import StrEnum
from types import MappingProxyType


class ErrorCode(StrEnum):
    """Stable machine-readable categories exposed by ontology errors."""

    ONTOLOGY = "ontology_error"
    SCHEMA = "schema_error"
    VERSION = "version_error"
    IDENTITY = "identity_error"
    MAPPING = "mapping_error"
    MATERIALIZATION = "materialization_error"
    STORAGE = "storage_error"
    QUERY = "query_error"
    BRIDGE = "bridge_error"
    REASONING = "reasoning_error"


class OntologyError(Exception):
    """Base error carrying a stable code and immutable diagnostic context."""

    default_code = ErrorCode.ONTOLOGY

    def __init__(
        self,
        message: str,
        *,
        code: ErrorCode | None = None,
        context: Mapping[str, object] | None = None,
    ) -> None:
        if not message.strip():
            raise ValueError("ontology error message must not be empty")

        super().__init__(message)
        self.message = message
        self.code = code or self.default_code
        self.context = MappingProxyType(dict(context or {}))


class SchemaError(OntologyError):
    """Ontology schema is invalid or internally inconsistent."""

    default_code = ErrorCode.SCHEMA


class VersionError(OntologyError):
    """Ontology version lookup, publication, or evolution failed."""

    default_code = ErrorCode.VERSION


class IdentityError(OntologyError):
    """Identity generation or entity resolution failed."""

    default_code = ErrorCode.IDENTITY


class MappingError(OntologyError):
    """A declarative mapping is invalid or cannot be compiled."""

    default_code = ErrorCode.MAPPING


class MaterializationError(OntologyError):
    """A canonical record cannot be materialized safely."""

    default_code = ErrorCode.MATERIALIZATION


class StorageError(OntologyError):
    """An ontology storage operation failed."""

    default_code = ErrorCode.STORAGE


class QueryError(OntologyError):
    """An ontology query is invalid or cannot be completed."""

    default_code = ErrorCode.QUERY


class BridgeError(OntologyError):
    """The interchange boundary with Orus Data Engine failed."""

    default_code = ErrorCode.BRIDGE


class ReasoningError(OntologyError):
    """A reasoning rule or bounded inference execution failed."""

    default_code = ErrorCode.REASONING

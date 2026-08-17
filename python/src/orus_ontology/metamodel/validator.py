"""Structural validation shared by ontology schema declarations."""

from __future__ import annotations

from collections.abc import Sequence
from typing import TYPE_CHECKING
from uuid import UUID

from orus_ontology.errors import SchemaError

if TYPE_CHECKING:
    from orus_ontology.metamodel.property_type import PropertyType


def validate_unique_properties(properties: Sequence[PropertyType], *, owner: str) -> None:
    names = [prop.name for prop in properties]
    identifiers = [prop.property_id for prop in properties]
    if len(names) != len(set(names)):
        raise ValueError(f"property names must be unique in '{owner}'")
    if len(identifiers) != len(set(identifiers)):
        raise ValueError(f"property IDs must be unique in '{owner}'")


class SchemaValidator:
    """Explicit validation boundary returning domain errors to callers."""

    @staticmethod
    def validate(definition: object) -> None:
        from orus_ontology.metamodel.ontology import OntologyDefinition

        if not isinstance(definition, OntologyDefinition):
            raise SchemaError(
                "expected an OntologyDefinition",
                context={"received_type": type(definition).__name__},
            )


def validate_unique_ids(values: Sequence[UUID], *, label: str) -> None:
    if len(values) != len(set(values)):
        raise ValueError(f"{label} IDs must be unique")

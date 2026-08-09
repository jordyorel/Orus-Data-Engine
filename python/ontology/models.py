"""
Orus Data Engine - Ontology Models
Defines Business Objects, Properties, Relations, and Schema Mapping.
"""

from dataclasses import dataclass, field
from typing import Any, Dict, List, Optional, Set
import json
import uuid


@dataclass
class RowId:
    """Reflects the engine's streaming RowId for audit and provenance tracking."""
    source_id: int
    batch_id: int
    row_in_batch: int
    global_offset: int

    def to_dict(self) -> Dict[str, Any]:
        return {
            "source_id": self.source_id,
            "batch_id": self.batch_id,
            "row_in_batch": self.row_in_batch,
            "global_offset": self.global_offset,
        }


@dataclass
class EntityProperty:
    """A business property attached to an Entity instance."""
    name: str
    value: Any
    physical_type: str = "string"
    source_column: Optional[str] = None
    provenance: Optional[RowId] = None

    def to_dict(self) -> Dict[str, Any]:
        return {
            "name": self.name,
            "value": self.value,
            "physical_type": self.physical_type,
            "source_column": self.source_column,
            "provenance": self.provenance.to_dict() if self.provenance else None,
        }


@dataclass
class EntityInstance:
    """A business domain object (e.g. Customer, Invoice, Contract)."""
    canonical_id: str
    entity_type: str
    properties: Dict[str, EntityProperty] = field(default_factory=dict)
    source_row_ids: List[RowId] = field(default_factory=list)
    tags: Set[str] = field(default_factory=set)

    def set_property(
        self,
        name: str,
        value: Any,
        physical_type: str = "string",
        source_column: Optional[str] = None,
        provenance: Optional[RowId] = None,
    ) -> None:
        self.properties[name] = EntityProperty(
            name=name,
            value=value,
            physical_type=physical_type,
            source_column=source_column,
            provenance=provenance,
        )
        if provenance and provenance not in self.source_row_ids:
            self.source_row_ids.append(provenance)

    def get(self, name: str, default: Any = None) -> Any:
        prop = self.properties.get(name)
        return prop.value if prop else default

    def to_dict(self) -> Dict[str, Any]:
        return {
            "canonical_id": self.canonical_id,
            "entity_type": self.entity_type,
            "properties": {k: v.to_dict() for k, v in self.properties.items()},
            "source_row_ids": [r.to_dict() for r in self.source_row_ids],
            "tags": list(self.tags),
        }


@dataclass
class Relation:
    """A directed edge in the Knowledge Graph between two Business Entities."""
    relation_id: str
    subject_id: str
    predicate: str
    object_id: str
    confidence: float = 1.0
    metadata: Dict[str, Any] = field(default_factory=dict)

    def to_dict(self) -> Dict[str, Any]:
        return {
            "relation_id": self.relation_id,
            "subject_id": self.subject_id,
            "predicate": self.predicate,
            "object_id": self.object_id,
            "confidence": self.confidence,
            "metadata": self.metadata,
        }


@dataclass
class EntityTypeSpec:
    """Schema declaration for a business entity type."""
    name: str
    primary_key_field: str
    property_mappings: Dict[str, str] = field(default_factory=dict)  # column_name -> property_name

    def to_dict(self) -> Dict[str, Any]:
        return {
            "name": self.name,
            "primary_key_field": self.primary_key_field,
            "property_mappings": self.property_mappings,
        }


class OntologySchema:
    """Registry of Entity Specs and Relationship Rules."""

    def __init__(self) -> None:
        self.entity_specs: Dict[str, EntityTypeSpec] = {}
        self.allowed_relations: Set[str] = set()

    def register_entity_type(self, spec: EntityTypeSpec) -> None:
        self.entity_specs[spec.name] = spec

    def register_relation_rule(self, subject_type: str, predicate: str, object_type: str) -> None:
        self.allowed_relations.add(f"{subject_type}:{predicate}:{object_type}")

    def is_relation_allowed(self, subject_type: str, predicate: str, object_type: str) -> bool:
        return f"{subject_type}:{predicate}:{object_type}" in self.allowed_relations

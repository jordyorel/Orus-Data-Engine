"""
Orus Data Engine - Python Knowledge Graph Manager
Manages Business Entities, Relationship Edges, Canonical Resolution, and Graph Traversal.
"""

from typing import Any, Dict, List, Optional, Set, Tuple
from python.ontology.models import EntityInstance, Relation, RowId


class KnowledgeGraph:
    """In-memory Knowledge Graph representing Business Domain Entities and Relationship Edges."""

    def __init__(self) -> None:
        self.entities: Dict[str, EntityInstance] = {}  # canonical_id -> EntityInstance
        self.relations: Dict[str, Relation] = {}  # relation_id -> Relation
        self.outgoing_edges: Dict[str, Set[str]] = {}  # subject_id -> set of relation_ids
        self.incoming_edges: Dict[str, Set[str]] = {}  # object_id -> set of relation_ids
        self.canonical_aliases: Dict[str, str] = {}  # alias_id -> canonical_id

    def add_entity(self, entity: EntityInstance) -> str:
        """Adds or updates an entity instance in the Knowledge Graph."""
        canonical_id = self.canonical_aliases.get(entity.canonical_id, entity.canonical_id)

        if canonical_id in self.entities:
            existing = self.entities[canonical_id]
            # Merge properties & provenance
            for prop_name, prop_val in entity.properties.items():
                existing.set_property(
                    name=prop_name,
                    value=prop_val.value,
                    physical_type=prop_val.physical_type,
                    source_column=prop_val.source_column,
                    provenance=prop_val.provenance,
                )
            for row_id in entity.source_row_ids:
                if row_id not in existing.source_row_ids:
                    existing.source_row_ids.append(row_id)
            return canonical_id
        else:
            self.entities[canonical_id] = entity
            self.outgoing_edges.setdefault(canonical_id, set())
            self.incoming_edges.setdefault(canonical_id, set())
            return canonical_id

    def add_relation(
        self,
        subject_id: str,
        predicate: str,
        object_id: str,
        confidence: float = 1.0,
        metadata: Optional[Dict[str, Any]] = None,
    ) -> Relation:
        """Adds a directed relationship edge between two entities."""
        sub_canon = self.canonical_aliases.get(subject_id, subject_id)
        obj_canon = self.canonical_aliases.get(object_id, object_id)

        relation_id = f"{sub_canon}:{predicate}:{obj_canon}"
        relation = Relation(
            relation_id=relation_id,
            subject_id=sub_canon,
            predicate=predicate,
            object_id=obj_canon,
            confidence=confidence,
            metadata=metadata or {},
        )

        self.relations[relation_id] = relation
        self.outgoing_edges.setdefault(sub_canon, set()).add(relation_id)
        self.incoming_edges.setdefault(obj_canon, set()).add(relation_id)
        return relation

    def resolve_entity_match(
        self,
        primary_canonical_id: str,
        alias_canonical_id: str,
        confidence: float = 1.0,
    ) -> None:
        """Merges two matched entity records (e.g. from engine fuzzy matching) into a single Canonical Entity ID."""
        if primary_canonical_id == alias_canonical_id:
            return

        self.canonical_aliases[alias_canonical_id] = primary_canonical_id

        # Merge alias entity into primary if it exists
        if alias_canonical_id in self.entities:
            alias_entity = self.entities.pop(alias_canonical_id)
            self.add_entity(alias_entity)

    def get_entity(self, canonical_id: str) -> Optional[EntityInstance]:
        resolved_id = self.canonical_aliases.get(canonical_id, canonical_id)
        return self.entities.get(resolved_id)

    def get_related_entities(
        self,
        canonical_id: str,
        predicate: Optional[str] = None,
        direction: str = "outgoing",
    ) -> List[Tuple[Relation, EntityInstance]]:
        """Returns related entities along with the connecting relationship edge."""
        resolved_id = self.canonical_aliases.get(canonical_id, canonical_id)
        results = []

        if direction in ("outgoing", "both"):
            for rel_id in self.outgoing_edges.get(resolved_id, set()):
                rel = self.relations[rel_id]
                if predicate is None or rel.predicate == predicate:
                    target = self.get_entity(rel.object_id)
                    if target:
                        results.append((rel, target))

        if direction in ("incoming", "both"):
            for rel_id in self.incoming_edges.get(resolved_id, set()):
                rel = self.relations[rel_id]
                if predicate is None or rel.predicate == predicate:
                    source = self.get_entity(rel.subject_id)
                    if source:
                        results.append((rel, source))

        return results

    def to_dict(self) -> Dict[str, Any]:
        """Serializes the entire Knowledge Graph to a JSON-compatible dictionary."""
        return {
            "entity_count": len(self.entities),
            "relation_count": len(self.relations),
            "entities": {k: v.to_dict() for k, v in self.entities.items()},
            "relations": {k: v.to_dict() for k, v in self.relations.items()},
            "canonical_aliases": self.canonical_aliases,
        }

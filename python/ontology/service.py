"""
Orus Data Engine - Python Ontology Service
Orchestrates streaming data ingestion from unmodified Orus Data Engine into the Knowledge Graph.
"""

from pathlib import Path
from typing import Any, Dict, List, Optional
from python.ontology.engine_bridge import OrusEngineBridge
from python.ontology.graph import KnowledgeGraph
from python.ontology.models import EntityTypeSpec, OntologySchema


class OntologyService:
    """High-level service orchestrating the Orus Data Engine and the Python Ontology Knowledge Graph."""

    def __init__(self, workspace_root: Optional[Path] = None) -> None:
        self.bridge = OrusEngineBridge(workspace_root=workspace_root)
        self.schema = OntologySchema()
        self.graph = KnowledgeGraph()

    def register_entity_spec(
        self,
        name: str,
        primary_key_field: str,
        property_mappings: Dict[str, str],
    ) -> EntityTypeSpec:
        """Registers a Business Domain Entity definition."""
        spec = EntityTypeSpec(
            name=name,
            primary_key_field=primary_key_field,
            property_mappings=property_mappings,
        )
        self.schema.register_entity_type(spec)
        return spec

    def register_relation_rule(
        self,
        subject_type: str,
        predicate: str,
        object_type: str,
    ) -> None:
        """Registers an allowed relationship between two entity types."""
        self.schema.register_relation_rule(subject_type, predicate, object_type)

    def ingest_csv_to_ontology(
        self,
        csv_path: Path,
        entity_name: str,
        clean_column: Optional[str] = None,
        clean_operation: Optional[str] = None,
    ) -> List[str]:
        """Runs the dataset through the engine, cleans it if specified, and populates the Knowledge Graph."""
        spec = self.schema.entity_specs.get(entity_name)
        if not spec:
            raise ValueError(f"Entity type '{entity_name}' not registered in Ontology Schema.")

        target_csv = csv_path
        if clean_column and clean_operation:
            output_clean_path = str(csv_path.parent / f"cleaned_{csv_path.name}")
            self.bridge.run_clean(
                csv_path=str(csv_path),
                output_csv_path=output_clean_path,
                column_name=clean_column,
                operation=clean_operation,
            )
            target_csv = Path(output_clean_path)

        entities = self.bridge.map_csv_to_entities(csv_path=target_csv, entity_spec=spec)
        added_ids = []
        for entity in entities:
            canon_id = self.graph.add_entity(entity)
            added_ids.append(canon_id)

        return added_ids

    def link_entities(
        self,
        subject_id: str,
        predicate: str,
        object_id: str,
        confidence: float = 1.0,
    ) -> Any:
        """Creates a directed relationship link between two business entity instances."""
        sub = self.graph.get_entity(subject_id)
        obj = self.graph.get_entity(object_id)
        if sub and obj:
            if not self.schema.is_relation_allowed(sub.entity_type, predicate, obj.entity_type):
                # Auto-register relation rule for flexible dynamic ontology creation
                self.register_relation_rule(sub.entity_type, predicate, obj.entity_type)
        return self.graph.add_relation(subject_id, predicate, object_id, confidence)

    def query_entity_context(self, canonical_id: str) -> Dict[str, Any]:
        """Returns the full business context, properties, provenance, and relationships for an entity."""
        entity = self.graph.get_entity(canonical_id)
        if not entity:
            return {"error": f"Entity '{canonical_id}' not found"}

        related = self.graph.get_related_entities(canonical_id, direction="both")
        relations_info = []
        for rel, tgt in related:
            relations_info.append({
                "predicate": rel.predicate,
                "target_canonical_id": tgt.canonical_id,
                "target_type": tgt.entity_type,
                "confidence": rel.confidence,
            })

        return {
            "entity": entity.to_dict(),
            "relationships": relations_info,
        }

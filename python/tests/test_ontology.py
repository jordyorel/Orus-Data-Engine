"""
Orus Data Engine - Python Ontology Test Suite
Validates the Python Ontology Layer interacting with the unmodified Zig Engine.
"""

from pathlib import Path
import sys
import unittest

# Add workspace root to Python path
workspace_root = Path(__file__).resolve().parents[2]
if str(workspace_root) not in sys.path:
    sys.path.insert(0, str(workspace_root))

from python.ontology.models import EntityInstance, EntityTypeSpec, OntologySchema, RowId
from python.ontology.graph import KnowledgeGraph
from python.ontology.engine_bridge import OrusEngineBridge
from python.ontology.service import OntologyService


class TestPythonOntologyLayer(unittest.TestCase):

    @classmethod
    def setUpClass(cls) -> None:
        cls.workspace_root = workspace_root
        cls.bridge = OrusEngineBridge(workspace_root=cls.workspace_root)
        cls.bridge.ensure_binary_built()

    def test_01_engine_bridge_infer_and_profile(self) -> None:
        """Tests that the Python bridge executes the unmodified Zig engine binary."""
        sample_csv = self.workspace_root / "fixtures" / "sample.csv"
        self.assertTrue(sample_csv.exists(), "Sample CSV fixture missing")

        infer_res = self.bridge.run_infer(str(sample_csv))
        self.assertEqual(infer_res["rows"], 3)
        self.assertTrue(len(infer_res["fields"]) > 0)

        profile_res = self.bridge.run_profile(str(sample_csv))
        self.assertEqual(profile_res["rows_processed"], 3)
        self.assertIn("columns", profile_res)

    def test_02_engine_bridge_clean_operation(self) -> None:
        """Tests streaming cleaning via the unmodified engine."""
        sample_csv = self.workspace_root / "fixtures" / "sample.csv"
        out_clean = self.workspace_root / ".zig-cache" / "python_clean_output.csv"
        out_clean.parent.mkdir(parents=True, exist_ok=True)

        res = self.bridge.run_clean(
            csv_path=str(sample_csv),
            output_csv_path=str(out_clean),
            column_name="name",
            operation="trim",
        )
        self.assertTrue(Path(res["output_csv"]).exists())

    def test_03_ontology_entity_mapping_and_knowledge_graph(self) -> None:
        """Tests mapping CSV rows to Business Entities and building Graph Relations."""
        service = OntologyService(workspace_root=self.workspace_root)

        # Register Customer spec
        service.register_entity_spec(
            name="Customer",
            primary_key_field="id",
            property_mappings={
                "id": "customer_id",
                "name": "full_name",
                "score": "credit_score",
            },
        )

        sample_csv = self.workspace_root / "fixtures" / "sample.csv"
        added_ids = service.ingest_csv_to_ontology(sample_csv, entity_name="Customer")
        self.assertTrue(len(added_ids) > 0)

        # Verify entity properties
        first_cust_id = added_ids[0]
        cust_context = service.query_entity_context(first_cust_id)
        self.assertIn("entity", cust_context)
        self.assertEqual(cust_context["entity"]["entity_type"], "Customer")
        self.assertIn("full_name", cust_context["entity"]["properties"])

        # Manually register an Invoice entity and link it to Customer
        service.register_entity_spec(
            name="Invoice",
            primary_key_field="inv_num",
            property_mappings={"inv_num": "invoice_number", "amount": "total_amount"},
        )
        inv = EntityInstance(canonical_id="Invoice:INV-9901", entity_type="Invoice")
        inv.set_property("total_amount", 1250.50, physical_type="decimal")
        service.graph.add_entity(inv)

        # Link Customer to Invoice
        service.link_entities(
            subject_id=first_cust_id,
            predicate="ISSUED_INVOICE",
            object_id="Invoice:INV-9901",
            confidence=1.0,
        )

        # Query relationship
        updated_context = service.query_entity_context(first_cust_id)
        self.assertEqual(len(updated_context["relationships"]), 1)
        self.assertEqual(updated_context["relationships"][0]["predicate"], "ISSUED_INVOICE")
        self.assertEqual(updated_context["relationships"][0]["target_canonical_id"], "Invoice:INV-9901")

    def test_04_canonical_entity_resolution(self) -> None:
        """Tests merging matched entity records into a unified Canonical Entity ID."""
        graph = KnowledgeGraph()

        cust_a = EntityInstance(canonical_id="CRM:101", entity_type="Customer")
        cust_a.set_property("email", "john@example.com")

        cust_b = EntityInstance(canonical_id="Billing:405", entity_type="Customer")
        cust_b.set_property("phone", "+1-555-0199")

        graph.add_entity(cust_a)
        graph.add_entity(cust_b)

        # Perform canonical resolution (merging Billing:405 into CRM:101)
        graph.resolve_entity_match(primary_canonical_id="CRM:101", alias_canonical_id="Billing:405")

        merged = graph.get_entity("Billing:405")
        self.assertIsNotNone(merged)
        self.assertEqual(merged.canonical_id, "CRM:101")
        self.assertEqual(merged.get("email"), "john@example.com")
        self.assertEqual(merged.get("phone"), "+1-555-0199")


if __name__ == "__main__":
    unittest.main()

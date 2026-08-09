"""
Orus Data Engine - Python Engine Bridge
Interfaces with the unmodified Orus Data Engine (Zig binary) via subprocess streaming.
"""

import json
import os
import subprocess
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

from python.ontology.models import EntityInstance, EntityTypeSpec, RowId


class OrusEngineBridge:
    """Bridge to execute and stream results from the unmodified Orus Data Engine binary."""

    def __init__(self, workspace_root: Optional[Path] = None) -> None:
        self.workspace_root = workspace_root or Path(__file__).resolve().parents[2]
        self.binary_path = self.workspace_root / "zig-out" / "bin" / "orusdata"

    def ensure_binary_built(self) -> Path:
        """Builds the Zig engine executable if not present."""
        if not self.binary_path.exists():
            cmd = ["zig", "build", "-Doptimize=ReleaseFast"]
            res = subprocess.run(cmd, cwd=self.workspace_root, capture_output=True, text=True)
            if res.returncode != 0:
                raise RuntimeError(f"Failed to build Orus Data Engine: {res.stderr}")
        return self.binary_path

    def run_infer(self, csv_path: str, batch_size: int = 8192) -> Dict[str, Any]:
        """Runs schema inference on a CSV dataset via Orus Data Engine."""
        self.ensure_binary_built()
        cmd = [str(self.binary_path), "infer", csv_path, str(batch_size)]
        res = subprocess.run(cmd, cwd=self.workspace_root, capture_output=True, text=True)
        if res.returncode != 0:
            raise RuntimeError(f"Engine infer command failed: {res.stderr}")
        
        # Parse stdout lines
        fields = []
        rows = 0
        batches = 0
        invalid_values = 0
        for line in res.stdout.strip().splitlines():
            if line.startswith("rows="):
                parts = line.split()
                rows = int(parts[0].split("=")[1])
                batches = int(parts[1].split("=")[1])
                invalid_values = int(parts[2].split("=")[1])
            elif ": type=" in line:
                name, rest = line.split(": type=")
                type_name, nullable = rest.split(" nullable=")
                fields.append({"name": name, "type": type_name, "nullable": nullable == "true"})

        return {
            "file": csv_path,
            "rows": rows,
            "batches": batches,
            "invalid_values": invalid_values,
            "fields": fields,
        }

    def run_profile(self, csv_path: str, batch_size: int = 8192) -> Dict[str, Any]:
        """Runs dataset profiling via Orus Data Engine and returns the JSON profile report."""
        self.ensure_binary_built()
        cmd = [str(self.binary_path), "profile", csv_path, str(batch_size)]
        res = subprocess.run(cmd, cwd=self.workspace_root, capture_output=True, text=True)
        if res.returncode != 0:
            raise RuntimeError(f"Engine profile command failed: {res.stderr}")
        return json.loads(res.stdout)

    def run_clean(
        self,
        csv_path: str,
        output_csv_path: str,
        column_name: str,
        operation: str,
        batch_size: int = 8192,
    ) -> Dict[str, Any]:
        """Runs columnar cleaning transform via Orus Data Engine, producing cleaned CSV & audit JSONL."""
        self.ensure_binary_built()
        cmd = [
            str(self.binary_path),
            "clean",
            csv_path,
            output_csv_path,
            column_name,
            operation,
            str(batch_size),
        ]
        res = subprocess.run(cmd, cwd=self.workspace_root, capture_output=True, text=True)
        if res.returncode != 0:
            raise RuntimeError(f"Engine clean command failed: {res.stderr}")

        audit_path = f"{output_csv_path}.audit.jsonl"
        return {
            "output_csv": output_csv_path,
            "audit_jsonl": audit_path,
            "stdout": res.stderr or res.stdout,
        }

    def map_csv_to_entities(
        self,
        csv_path: Path,
        entity_spec: EntityTypeSpec,
        delimiter: str = ",",
    ) -> List[EntityInstance]:
        """Reads a CSV output produced or processed by the engine and maps rows to Business Entities."""
        entities = []
        if not csv_path.exists():
            return entities

        with open(csv_path, "r", encoding="utf-8", errors="replace") as f:
            header_line = f.readline()
            if not header_line:
                return entities
            
            headers = [h.strip().strip('"') for h in header_line.strip().split(delimiter)]
            
            global_offset = 0
            batch_id = 0
            for line_idx, line in enumerate(f):
                if not line.strip():
                    continue
                values = [v.strip().strip('"') for v in line.strip().split(delimiter)]
                row_dict = dict(zip(headers, values))

                pk_col = entity_spec.primary_key_field
                pk_val = row_dict.get(pk_col, f"row-{line_idx}")
                canonical_id = f"{entity_spec.name}:{pk_val}"

                provenance = RowId(
                    source_id=hash(str(csv_path)) & 0xFFFFFFFF,
                    batch_id=batch_id,
                    row_in_batch=line_idx % 1000,
                    global_offset=global_offset,
                )

                entity = EntityInstance(canonical_id=canonical_id, entity_type=entity_spec.name)

                for col, prop_name in entity_spec.property_mappings.items():
                    if col in row_dict:
                        entity.set_property(
                            name=prop_name,
                            value=row_dict[col],
                            source_column=col,
                            provenance=provenance,
                        )

                entities.append(entity)
                global_offset += 1
                if global_offset % 1000 == 0:
                    batch_id += 1

        return entities

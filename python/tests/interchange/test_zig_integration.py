import os
from datetime import UTC, datetime
from pathlib import Path
from uuid import UUID

import pytest

from orus_ontology import (
    BatchMaterializer,
    MappingCompiler,
    MappingDefinition,
    OntologyDefinition,
    SourceContract,
)
from orus_ontology.interchange import RunStatus, SubprocessBridge

RUN_ID = UUID("aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")
NOW = datetime(2026, 8, 15, 12, tzinfo=UTC)


def test_csv_crosses_zig_bridge_and_materializes_traceable_graph(
    tmp_path: Path,
    ontology: OntologyDefinition,
    source_contract: SourceContract,
    mapping_definition: MappingDefinition,
) -> None:
    executable = os.environ.get("ORUS_DATA_ENGINE_BINARY")
    if executable is None:
        pytest.skip("set ORUS_DATA_ENGINE_BINARY to run the Zig integration")
    csv_path = tmp_path / "customers.csv"
    csv_path.write_text(
        "customer_id,customer_name,email,email_verified\n"
        "C-42,Alice,alice@example.com,true\n"
        "C-43,Bob,bob@example.com,false\n"
    )
    run = SubprocessBridge(executable).run(
        (
            "export-jsonl",
            str(csv_path),
            "customers.csv",
            str(RUN_ID),
            NOW.isoformat(),
            "1",
        )
    )
    plan = MappingCompiler.compile(mapping_definition, ontology, source_contract)
    batches = tuple(BatchMaterializer(plan, batch_size=1, recorded_at=NOW).materialize(run))
    assert run.status is RunStatus.COMPLETE
    assert len(batches) == 2
    assert all(len(batch.objects) == 2 and len(batch.relations) == 1 for batch in batches)
    assert batches[0].objects[0].assertions[0].provenance[0].source_id == "customers.csv"

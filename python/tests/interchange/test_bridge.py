import io
import json
import sys
from datetime import UTC, datetime

import pytest

from orus_ontology.errors import BridgeError
from orus_ontology.interchange import RunStatus, SubprocessBridge, read_jsonl

RUN_ID = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"


def _line(record: dict[str, object], *, version: int = 1) -> str:
    return json.dumps(
        {
            "contract_version": version,
            "record": record,
            "source": {
                "source_id": "fixture.csv",
                "batch_id": 0,
                "row_id": 0,
                "global_offset": 0,
                "observed_at": datetime(2026, 8, 15, tzinfo=UTC).isoformat(),
            },
            "run_id": RUN_ID,
        }
    )


def test_jsonl_rejects_unknown_contract_version_and_large_lines() -> None:
    with pytest.raises(BridgeError, match="invalid interchange"):
        list(read_jsonl(io.BytesIO((_line({"id": 1}, version=2) + "\n").encode())))
    with pytest.raises(BridgeError, match="configured limit"):
        list(read_jsonl(io.BytesIO(b'{"long":"value"}\n'), max_line_bytes=4))


def test_bridge_drains_stderr_and_completes() -> None:
    script = (
        "import sys; "
        "sys.stderr.write('x' * 200000); sys.stderr.flush(); "
        f"print({_line({'id': 7})!r})"
    )
    run = SubprocessBridge(sys.executable).run(("-c", script))
    records = list(run)
    assert records[0].values["id"] == 7
    assert run.status is RunStatus.COMPLETE
    assert run.records_valid
    assert run.records_emitted == 1


def test_bridge_marks_partial_output_invalid_on_process_failure() -> None:
    script = f"import sys; print({_line({'id': 7})!r}, flush=True); sys.exit(9)"
    run = SubprocessBridge(sys.executable).run(("-c", script))
    with pytest.raises(BridgeError, match="emitted records are invalid"):
        list(run)
    assert run.status is RunStatus.FAILED
    assert not run.records_valid
    assert run.records_emitted == 1
    assert run.return_code == 9

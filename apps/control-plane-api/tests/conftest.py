import stat
import sys
from collections.abc import Iterator
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

API_SRC = Path(__file__).parents[1] / "src"
if str(API_SRC) not in sys.path:
    sys.path.insert(0, str(API_SRC))

from orus_control_plane_api import create_app  # noqa: E402
from orus_control_plane_api.config import Settings  # noqa: E402


@pytest.fixture
def settings(tmp_path: Path) -> Settings:
    engine = tmp_path / "orusdata"
    engine.write_text(
        "#!/bin/sh\n"
        "printf '%s\\n' '{\"columns\":[{\"name\":\"id\",\"tag\":\"i64\","
        "\"nullable\":false,\"null_count\":0,\"null_rate\":0,\"distinct_count\":2,"
        "\"cardinality_mode\":\"exact\",\"numeric\":null,\"decimal\":null,"
        "\"length\":null,\"detected_pattern\":null}],\"rows_processed\":2,"
        "\"batches_processed\":1,\"source_id\":1,\"schema_hash\":2}'\n",
        encoding="utf-8",
    )
    engine.chmod(engine.stat().st_mode | stat.S_IXUSR)
    return Settings(data_dir=tmp_path / "data", engine_path=engine)


@pytest.fixture
def client(settings: Settings) -> Iterator[TestClient]:
    with TestClient(create_app(settings)) as test_client:
        yield test_client

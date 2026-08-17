from datetime import UTC, datetime, timedelta, timezone
from types import MappingProxyType
from uuid import uuid4

import pytest
from pydantic import ValidationError

from orus_ontology import SourceReference


def test_source_reference_is_immutable_normalized_and_serializable() -> None:
    metadata = {"partition": ["2026", "08"]}
    reference = SourceReference(
        source_id="customers.csv",
        source_version="sha256:abc",
        batch_id=4,
        row_id=42,
        global_offset=32810,
        source_column="Customer Id",
        run_id=uuid4(),
        transformation_ids=("trim@1", "lowercase@1"),
        observed_at=datetime(
            2026,
            8,
            15,
            14,
            0,
            tzinfo=timezone(timedelta(hours=2)),
        ),
        metadata=metadata,
    )
    metadata["partition"].append("mutated")

    assert reference.observed_at == datetime(2026, 8, 15, 12, 0, tzinfo=UTC)
    assert isinstance(reference.metadata, MappingProxyType)
    assert reference.metadata["partition"] == ("2026", "08")
    assert SourceReference.model_validate_json(reference.model_dump_json()) == reference


def test_source_reference_requires_position_and_unique_transformations() -> None:
    run_id = uuid4()
    observed_at = datetime(2026, 8, 15, 12, 0, tzinfo=UTC)
    with pytest.raises(ValidationError, match="requires row_id or global_offset"):
        SourceReference(
            source_id="customers.csv",
            run_id=run_id,
            observed_at=observed_at,
        )

    with pytest.raises(ValidationError, match="must be unique"):
        SourceReference(
            source_id="customers.csv",
            run_id=run_id,
            observed_at=observed_at,
            row_id=1,
            transformation_ids=("trim@1", "trim@1"),
        )

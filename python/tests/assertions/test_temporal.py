from datetime import UTC, datetime, timedelta, timezone

import pytest
from pydantic import ValidationError

from orus_ontology import TemporalContext


def test_temporal_context_normalizes_all_timestamps_to_utc() -> None:
    plus_two = timezone(timedelta(hours=2))
    temporal = TemporalContext(
        observed_at=datetime(2026, 8, 15, 14, 0, tzinfo=plus_two),
        valid_from=datetime(2026, 8, 15, 12, 0, tzinfo=UTC),
        valid_to=datetime(2026, 8, 16, 12, 0, tzinfo=UTC),
        recorded_at=datetime(2026, 8, 15, 12, 1, tzinfo=UTC),
    )

    assert temporal.observed_at == datetime(2026, 8, 15, 12, 0, tzinfo=UTC)
    assert temporal.observed_at.tzinfo is UTC


def test_temporal_context_rejects_naive_and_incoherent_times() -> None:
    with pytest.raises(ValidationError, match="must include a timezone"):
        TemporalContext(observed_at=datetime(2026, 8, 15, 12, 0))

    with pytest.raises(ValidationError, match="recorded_at must not be before"):
        TemporalContext(
            observed_at=datetime(2026, 8, 15, 12, 0, tzinfo=UTC),
            recorded_at=datetime(2026, 8, 15, 11, 59, tzinfo=UTC),
        )

    with pytest.raises(ValidationError, match="valid_from must not be after"):
        TemporalContext(
            observed_at=datetime(2026, 8, 15, 12, 0, tzinfo=UTC),
            valid_from=datetime(2026, 8, 16, 0, 0, tzinfo=UTC),
            valid_to=datetime(2026, 8, 15, 0, 0, tzinfo=UTC),
        )

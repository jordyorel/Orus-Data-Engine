from datetime import UTC, datetime
from decimal import Decimal
from uuid import UUID, uuid4

import pytest
from pydantic import ValidationError

from orus_ontology import (
    MatchCandidate,
    ResolutionDecision,
    ResolutionOutcome,
)

NOW = datetime(2026, 8, 15, 12, 0, tzinfo=UTC)


def make_candidate(left: UUID | None = None, right: UUID | None = None) -> MatchCandidate:
    left_id = left or uuid4()
    right_id = right or uuid4()
    return MatchCandidate.create(
        ontology_id=uuid4(),
        left_object_id=left_id,
        right_object_id=right_id,
        confidence=Decimal("0.93"),
        method="email_phone_match",
        matcher_version=1,
        evidence_assertion_ids=(uuid4(),),
        created_at=NOW,
    )


def test_candidate_is_deterministic_independent_of_pair_order() -> None:
    ontology_id = uuid4()
    left = uuid4()
    right = uuid4()
    first = MatchCandidate.create(
        ontology_id=ontology_id,
        left_object_id=left,
        right_object_id=right,
        confidence=Decimal("0.93"),
        method="email_match",
        matcher_version=2,
        created_at=NOW,
    )
    second = MatchCandidate.create(
        ontology_id=ontology_id,
        left_object_id=right,
        right_object_id=left,
        confidence=Decimal("0.93"),
        method="email_match",
        matcher_version=2,
        created_at=NOW,
    )

    assert first.candidate_id == second.candidate_id
    assert first.object_ids == second.object_ids


def test_candidate_rejects_same_object_and_float_confidence() -> None:
    object_id = uuid4()
    with pytest.raises(ValidationError, match="distinct objects"):
        MatchCandidate.create(
            ontology_id=uuid4(),
            left_object_id=object_id,
            right_object_id=object_id,
            confidence=Decimal("1"),
            method="exact_match",
            matcher_version=1,
            created_at=NOW,
        )

    with pytest.raises(ValidationError, match="exact decimal"):
        MatchCandidate.create(
            ontology_id=uuid4(),
            left_object_id=uuid4(),
            right_object_id=uuid4(),
            confidence=0.9,  # type: ignore[arg-type]
            method="exact_match",
            matcher_version=1,
            created_at=NOW,
        )


def test_merge_decision_preserves_sources_and_is_reproducible() -> None:
    candidate = make_candidate()
    first = ResolutionDecision.from_candidate(
        candidate,
        ontology_version=1,
        outcome=ResolutionOutcome.MERGE,
        resolver_version=1,
        decided_at=NOW,
        actor_id="reviewer-42",
    )
    second = ResolutionDecision.from_candidate(
        candidate,
        ontology_version=1,
        outcome=ResolutionOutcome.MERGE,
        resolver_version=1,
        decided_at=NOW,
        actor_id="reviewer-42",
    )

    assert first.source_object_ids == candidate.object_ids
    assert first.canonical_object_id == second.canonical_object_id
    assert first.canonical_object_id not in first.source_object_ids
    assert first.actor_id == "reviewer-42"


def test_rejection_does_not_create_canonical_identity() -> None:
    decision = ResolutionDecision.from_candidate(
        make_candidate(),
        ontology_version=1,
        outcome=ResolutionOutcome.REJECT,
        resolver_version=1,
        decided_at=NOW,
    )

    assert decision.canonical_object_id is None
    assert len(decision.source_object_ids) == 2

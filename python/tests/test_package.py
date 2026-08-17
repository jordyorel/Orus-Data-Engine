from types import MappingProxyType

import pytest

import orus_ontology
from orus_ontology import ErrorCode, OntologyError, SchemaError


def test_package_exposes_only_completed_phase_one_api() -> None:
    assert orus_ontology.__version__ == "0.1.0"
    assert set(orus_ontology.__all__) == {
        "Assertion",
        "AssertionKind",
        "AssertionTarget",
        "BatchMaterializer",
        "BridgeRun",
        "BridgeError",
        "CONTRACT_VERSION",
        "ChangeCompatibility",
        "ConditionOperator",
        "CanonicalRecord",
        "CyclePolicy",
        "ErrorCode",
        "FilterOperator",
        "IdentityError",
        "IdentityGenerator",
        "IdentityNormalizer",
        "IdentitySpec",
        "InferenceExplanation",
        "InferenceRule",
        "InterchangeEnvelope",
        "InterchangeSource",
        "MappingError",
        "MappingCompiler",
        "MappingDefinition",
        "MappingPlan",
        "MatchCandidate",
        "MaterializationError",
        "MigrationPlan",
        "MigrationStep",
        "MigrationStrategy",
        "MaterializedBatch",
        "MemoryStore",
        "ObjectInstance",
        "ObjectMapping",
        "ObjectQuery",
        "ObjectTarget",
        "ObjectType",
        "OntologyDefinition",
        "OntologyError",
        "OntologyStatus",
        "PropertyCardinality",
        "PropertyConstraints",
        "PropertyFilter",
        "PropertyMapping",
        "PropertyType",
        "QueryError",
        "QueryService",
        "ReasoningEngine",
        "ReasoningError",
        "ReasoningLimits",
        "ReasoningResult",
        "QuarantinedRecord",
        "RecordErrorPolicy",
        "RelationCardinality",
        "RelationDirection",
        "RelationInstance",
        "RelationMapping",
        "RelationType",
        "ResolutionDecision",
        "ResolutionOutcome",
        "RunStatus",
        "RuleConclusion",
        "RuleCondition",
        "SchemaError",
        "SchemaRegistry",
        "SchemaValidator",
        "SourceReference",
        "SourceContract",
        "SourceField",
        "StorageError",
        "SubprocessBridge",
        "TargetKind",
        "TemporalContext",
        "TransformName",
        "TraversalHop",
        "TraversalQuery",
        "TraversalResult",
        "ValueTarget",
        "ValueType",
        "VersionChange",
        "VersionDiff",
        "VersionError",
        "compare_versions",
        "encode_jsonl",
        "read_jsonl",
    }


def test_specialized_error_has_stable_code_and_immutable_context() -> None:
    error = SchemaError(
        "duplicate object type",
        context={"type_name": "Customer"},
    )

    assert isinstance(error, OntologyError)
    assert error.code is ErrorCode.SCHEMA
    assert error.message == "duplicate object type"
    assert isinstance(error.context, MappingProxyType)
    assert error.context == {"type_name": "Customer"}

    with pytest.raises(TypeError):
        error.context["type_name"] = "Company"  # type: ignore[index]


def test_error_copies_caller_context() -> None:
    context: dict[str, object] = {"version": 1}
    error = OntologyError("publication failed", context=context)

    context["version"] = 2

    assert error.context["version"] == 1


def test_error_rejects_empty_message() -> None:
    with pytest.raises(ValueError, match="must not be empty"):
        OntologyError("   ")

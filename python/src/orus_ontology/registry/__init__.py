"""Ontology registry, version comparison, and migration contracts."""

from orus_ontology.registry.migration import MigrationPlan, MigrationStep, MigrationStrategy
from orus_ontology.registry.registry import SchemaRegistry
from orus_ontology.registry.version import (
    ChangeCompatibility,
    VersionChange,
    VersionDiff,
    compare_versions,
)

__all__ = [
    "ChangeCompatibility",
    "MigrationPlan",
    "MigrationStep",
    "MigrationStrategy",
    "SchemaRegistry",
    "VersionChange",
    "VersionDiff",
    "compare_versions",
]

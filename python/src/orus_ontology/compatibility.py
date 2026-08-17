"""Published compatibility identifiers for the ontology v1 contracts."""

import json
from hashlib import sha256

from orus_ontology._schema import ImmutableModel
from orus_ontology.interchange.contract import CONTRACT_VERSION
from orus_ontology.vertical.customers import customer_mapping, customer_ontology

PUBLIC_API_VERSION = "1.0"
STORAGE_SCHEMA_VERSION = 1


class CompatibilityManifest(ImmutableModel):
    public_api_version: str
    interchange_contract_version: int
    storage_schema_version: int
    customer_ontology_digest: str
    customer_mapping_digest: str


def compatibility_manifest() -> CompatibilityManifest:
    return CompatibilityManifest(
        public_api_version=PUBLIC_API_VERSION,
        interchange_contract_version=CONTRACT_VERSION,
        storage_schema_version=STORAGE_SCHEMA_VERSION,
        customer_ontology_digest=_digest(customer_ontology().model_dump(mode="json")),
        customer_mapping_digest=_digest(customer_mapping().model_dump(mode="json")),
    )


def _digest(value: object) -> str:
    canonical = json.dumps(value, sort_keys=True, separators=(",", ":"))
    return sha256(canonical.encode()).hexdigest()

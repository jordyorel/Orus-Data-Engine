from orus_ontology.compatibility import compatibility_manifest


def test_v1_compatibility_manifest_is_stable() -> None:
    manifest = compatibility_manifest()
    assert manifest.public_api_version == "1.0"
    assert manifest.interchange_contract_version == 1
    assert manifest.storage_schema_version == 1
    assert manifest.customer_ontology_digest == (
        "93b4afa4ce1635e723487b9b96d11b5efeb92ff3f60db84451723853518b9a56"
    )
    assert manifest.customer_mapping_digest == (
        "5776137670cc15660c87dba705f2b698fd63e395434d73f350686886a085c686"
    )

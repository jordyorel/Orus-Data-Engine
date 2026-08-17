CREATE TABLE IF NOT EXISTS orus_ontology_schemas (
    ontology_id uuid NOT NULL,
    version integer NOT NULL CHECK (version > 0),
    document jsonb NOT NULL,
    PRIMARY KEY (ontology_id, version)
);

CREATE TABLE IF NOT EXISTS orus_ontology_objects (
    object_id uuid PRIMARY KEY,
    ontology_id uuid NOT NULL,
    ontology_version integer NOT NULL,
    object_type_id uuid NOT NULL,
    document jsonb NOT NULL,
    FOREIGN KEY (ontology_id, ontology_version)
        REFERENCES orus_ontology_schemas (ontology_id, version)
);
CREATE INDEX IF NOT EXISTS orus_ontology_objects_type_idx
    ON orus_ontology_objects (object_type_id, object_id);

CREATE TABLE IF NOT EXISTS orus_ontology_relations (
    relation_id uuid PRIMARY KEY,
    ontology_id uuid NOT NULL,
    ontology_version integer NOT NULL,
    relation_type_id uuid NOT NULL,
    source_object_id uuid NOT NULL REFERENCES orus_ontology_objects (object_id),
    target_object_id uuid NOT NULL REFERENCES orus_ontology_objects (object_id),
    document jsonb NOT NULL,
    FOREIGN KEY (ontology_id, ontology_version)
        REFERENCES orus_ontology_schemas (ontology_id, version)
);
CREATE INDEX IF NOT EXISTS orus_ontology_relations_source_idx
    ON orus_ontology_relations (source_object_id, relation_type_id, relation_id);
CREATE INDEX IF NOT EXISTS orus_ontology_relations_target_idx
    ON orus_ontology_relations (target_object_id, relation_type_id, relation_id);

CREATE TABLE IF NOT EXISTS orus_ontology_assertions (
    assertion_id uuid PRIMARY KEY,
    subject_id uuid NOT NULL,
    predicate text NOT NULL,
    target_value jsonb NULL,
    supersedes_assertion_id uuid NULL REFERENCES orus_ontology_assertions (assertion_id),
    document jsonb NOT NULL
);
CREATE INDEX IF NOT EXISTS orus_ontology_assertions_subject_idx
    ON orus_ontology_assertions (subject_id, assertion_id);
CREATE INDEX IF NOT EXISTS orus_ontology_assertions_predicate_idx
    ON orus_ontology_assertions (subject_id, predicate);
CREATE INDEX IF NOT EXISTS orus_ontology_assertions_lookup_idx
    ON orus_ontology_assertions (predicate, target_value);

CREATE TABLE IF NOT EXISTS orus_ontology_resolutions (
    decision_id uuid NOT NULL,
    source_object_id uuid NOT NULL,
    canonical_object_id uuid NOT NULL,
    document jsonb NOT NULL,
    PRIMARY KEY (decision_id, source_object_id),
    UNIQUE (source_object_id)
);
CREATE INDEX IF NOT EXISTS orus_ontology_resolutions_canonical_idx
    ON orus_ontology_resolutions (canonical_object_id);

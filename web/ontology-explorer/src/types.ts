export type ValueTarget = {
  target_kind: "value";
  value_type: string;
  value: unknown;
};

export type SourceReference = {
  source_id: string;
  global_offset: number | null;
  source_column: string | null;
  observed_at: string;
  transformation_ids: string[];
};

export type Assertion = {
  assertion_id: string;
  predicate: string;
  target: ValueTarget | { target_kind: "object"; object_id: string };
  kind: string;
  confidence: string;
  provenance: SourceReference[];
};

export type OntologyObject = {
  object_id: string;
  ontology_id: string;
  ontology_version: number;
  object_type_id: string;
  assertions: Assertion[];
};

export type Relation = {
  relation_id: string;
  relation_type_id: string;
  source_object_id: string;
  target_object_id: string;
  confidence: string;
};

export type Statistics = {
  schemas: number;
  objects: number;
  relations: number;
  assertions: number;
  resolutions: number;
};

export type ObjectContext = {
  object: OntologyObject;
  assertions: Assertion[];
  provenance: SourceReference[];
};

export type Neighbor = { relation: Relation; object: OntologyObject };

export type NeighborList = {
  object_id: string;
  direction: string;
  neighbors: Neighbor[];
  limit: number;
};

import { describe, expect, it } from "vitest";

import { CUSTOMER_TYPE_ID, graphElements, nodeLabel, relationName, typeName } from "./domain";
import type { OntologyObject, Relation } from "./types";

const customer: OntologyObject = {
  object_id: "customer-1",
  ontology_id: "ontology-1",
  ontology_version: 1,
  object_type_id: CUSTOMER_TYPE_ID,
  assertions: [
    {
      assertion_id: "assertion-1",
      predicate: "customer_id",
      target: { target_kind: "value", value_type: "string", value: "C-1" },
      kind: "observed",
      confidence: "1",
      provenance: [],
    },
  ],
};

describe("ontology graph adapter", () => {
  it("uses domain labels instead of opaque UUIDs", () => {
    expect(typeName(CUSTOMER_TYPE_ID)).toBe("Customer");
    expect(nodeLabel(customer)).toBe("C-1");
  });

  it("produces Cytoscape nodes and directed edges", () => {
    const relation: Relation = {
      relation_id: "relation-1",
      relation_type_id: "9062a09b-b6a7-51a8-9647-92775d8a7958",
      source_object_id: "customer-1",
      target_object_id: "company-1",
      confidence: "1",
    };
    const elements = graphElements([customer], [relation]);

    expect(elements).toHaveLength(2);
    expect(elements[1]?.data).toMatchObject({
      source: "customer-1",
      target: "company-1",
      label: "WORKS_FOR",
    });
    expect(relationName(relation.relation_type_id)).toBe("WORKS_FOR");
  });
});

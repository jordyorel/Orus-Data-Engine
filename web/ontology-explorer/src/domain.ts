import type { Assertion, OntologyObject, Relation } from "./types";

export const CUSTOMER_TYPE_ID = "c45a055a-b2e7-51c4-99e8-763f5560c312";
export const EMAIL_TYPE_ID = "cf510978-675d-5e6b-ab2f-8c820891c356";
export const COMPANY_TYPE_ID = "103f7270-712d-5373-b228-3b50ed1258e6";
export const OWNS_EMAIL_TYPE_ID = "9846f937-d9cf-5c25-98c8-996872911990";
export const WORKS_FOR_TYPE_ID = "9062a09b-b6a7-51a8-9647-92775d8a7958";

export function typeName(typeId: string): string {
  return {
    [CUSTOMER_TYPE_ID]: "Customer",
    [EMAIL_TYPE_ID]: "Email",
    [COMPANY_TYPE_ID]: "Company",
  }[typeId] ?? "Object";
}

export function relationName(typeId: string): string {
  return {
    [OWNS_EMAIL_TYPE_ID]: "OWNS_EMAIL",
    [WORKS_FOR_TYPE_ID]: "WORKS_FOR",
  }[typeId] ?? "RELATED_TO";
}

export function assertionValue(assertion: Assertion): string {
  if (assertion.target.target_kind === "object") return assertion.target.object_id;
  const value = assertion.target.value;
  if (value === null || value === undefined) return "null";
  if (typeof value === "object") return JSON.stringify(value);
  return String(value);
}

export function nodeLabel(object: OntologyObject): string {
  const preferred = ["customer_id", "name", "address", "first_name"];
  for (const predicate of preferred) {
    const assertion = object.assertions.find((item) => item.predicate === predicate);
    if (assertion) return assertionValue(assertion);
  }
  return object.object_id.slice(0, 8);
}

export function graphElements(objects: OntologyObject[], relations: Relation[]) {
  return [
    ...objects.map((object) => ({
      group: "nodes" as const,
      data: {
        id: object.object_id,
        label: nodeLabel(object),
        type: typeName(object.object_type_id),
      },
    })),
    ...relations.map((relation) => ({
      group: "edges" as const,
      data: {
        id: relation.relation_id,
        source: relation.source_object_id,
        target: relation.target_object_id,
        label: relationName(relation.relation_type_id),
      },
    })),
  ];
}

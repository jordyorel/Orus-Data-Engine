import type { NeighborList, ObjectContext, OntologyObject, Statistics } from "./types";

const API_BASE = import.meta.env.VITE_API_BASE_URL ?? "/api";

async function request<T>(path: string, init?: RequestInit): Promise<T> {
  const response = await fetch(`${API_BASE}${path}`, {
    ...init,
    headers: { "Content-Type": "application/json", ...init?.headers },
  });
  if (!response.ok) {
    const body = (await response.json().catch(() => null)) as unknown;
    const detail =
      body && typeof body === "object" && "detail" in body ? String(body.detail) : null;
    throw new Error(detail ?? `API request failed (${response.status})`);
  }
  return (await response.json()) as T;
}

export const api = {
  statistics: () => request<Statistics>("/v1/statistics"),
  context: (objectId: string) => request<ObjectContext>(`/v1/objects/${objectId}`),
  neighbors: (objectId: string) =>
    request<NeighborList>(`/v1/objects/${objectId}/neighbors?direction=both&limit=100`),
  searchCustomer: async (customerId: string): Promise<OntologyObject | null> => {
    const result = await request<{ objects: OntologyObject[] }>("/v1/objects/search", {
      method: "POST",
      body: JSON.stringify({
        object_type_id: "c45a055a-b2e7-51c4-99e8-763f5560c312",
        filters: [{ predicate: "customer_id", operator: "equals", value: customerId }],
        limit: 1,
      }),
    });
    return result.objects[0] ?? null;
  },
};

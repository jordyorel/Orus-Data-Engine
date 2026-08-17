import type { Preview, ProfileReport, ProfileRun, Project, Source } from "./types";

const BASE = import.meta.env.VITE_CONTROL_API_URL ?? "/api";

async function request<T>(path: string, init?: RequestInit): Promise<T> {
  const response = await fetch(`${BASE}${path}`, init);
  if (!response.ok) {
    const body = (await response.json().catch(() => null)) as { detail?: string } | null;
    throw new Error(body?.detail ?? `Request failed (${response.status})`);
  }
  return (await response.json()) as T;
}

export const api = {
  ready: () => request<{ status: string }>("/health/ready"),
  projects: () => request<Project[]>("/v1/projects"),
  createProject: (name: string) => request<Project>("/v1/projects", {
    method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ name }),
  }),
  sources: (projectId: string) => request<Source[]>(`/v1/projects/${projectId}/sources`),
  upload: (projectId: string, file: File) => {
    const body = new FormData(); body.append("file", file);
    return request<Source>(`/v1/projects/${projectId}/sources`, { method: "POST", body });
  },
  preview: (sourceId: string) => request<Preview>(`/v1/sources/${sourceId}/preview?limit=8`),
  runs: (sourceId: string) => request<ProfileRun[]>(`/v1/sources/${sourceId}/profile-runs`),
  startProfile: (sourceId: string) => request<ProfileRun>(`/v1/sources/${sourceId}/profile-runs`, { method: "POST" }),
  run: (runId: string) => request<ProfileRun>(`/v1/profile-runs/${runId}`),
  report: (runId: string) => request<ProfileReport>(`/v1/profile-runs/${runId}/report`),
};

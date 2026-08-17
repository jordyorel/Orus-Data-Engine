export type Project = { project_id: string; name: string; created_at: string };
export type Source = {
  source_id: string;
  project_id: string;
  filename: string;
  media_type: string;
  size_bytes: number;
  sha256: string;
  created_at: string;
};
export type ProfileRun = {
  run_id: string;
  source_id: string;
  status: "queued" | "running" | "succeeded" | "failed";
  created_at: string;
  started_at: string | null;
  completed_at: string | null;
  error: string | null;
};
export type ColumnProfile = {
  name: string;
  tag: string;
  nullable: boolean;
  null_count: number;
  null_rate: number;
  distinct_count: number;
  cardinality_mode: string;
  detected_pattern: string | null;
};
export type ProfileReport = {
  columns: ColumnProfile[];
  rows_processed: number;
  batches_processed: number;
  source_id: number;
  schema_hash: number;
};
export type Preview = { columns: string[]; rows: string[][]; truncated: boolean };

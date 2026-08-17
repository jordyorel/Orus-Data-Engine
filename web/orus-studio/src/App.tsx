import { Activity, Database, FilePlus2, Files, Network, Play, Plus, RefreshCw, Search, ShieldCheck } from "lucide-react";
import { useEffect, useRef, useState, type ReactNode } from "react";

import { api } from "./api";
import type { Preview, ProfileReport, ProfileRun, Project, Source } from "./types";

export default function App() {
  const [projects, setProjects] = useState<Project[]>([]);
  const [project, setProject] = useState<Project | null>(null);
  const [sources, setSources] = useState<Source[]>([]);
  const [source, setSource] = useState<Source | null>(null);
  const [preview, setPreview] = useState<Preview | null>(null);
  const [runs, setRuns] = useState<ProfileRun[]>([]);
  const [report, setReport] = useState<ProfileReport | null>(null);
  const [view, setView] = useState<"sources" | "quality" | "runs">("sources");
  const [projectDialog, setProjectDialog] = useState(false);
  const [projectName, setProjectName] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [engineReady, setEngineReady] = useState<boolean | null>(null);
  const fileInput = useRef<HTMLInputElement>(null);

  useEffect(() => {
    void api.ready().then(() => setEngineReady(true)).catch(() => setEngineReady(false));
    void loadProjects();
  }, []);
  useEffect(() => { if (project) void loadSources(project); }, [project]);

  async function loadProjects() {
    try {
      const items = await api.projects(); setProjects(items); setProject((current) => current ?? items[0] ?? null);
    } catch (reason) { setError(message(reason)); }
  }

  async function loadSources(selected: Project) {
    try {
      const items = await api.sources(selected.project_id); setSources(items);
      if (items[0]) await selectSource(items[0]); else { setSource(null); setPreview(null); setRuns([]); setReport(null); }
    } catch (reason) { setError(message(reason)); }
  }

  async function selectSource(selected: Source) {
    try {
      setSource(selected); setReport(null);
      const [nextPreview, nextRuns] = await Promise.all([api.preview(selected.source_id), api.runs(selected.source_id)]);
      setPreview(nextPreview); setRuns(nextRuns);
      const complete = nextRuns.find((run) => run.status === "succeeded");
      if (complete) setReport(await api.report(complete.run_id));
    } catch (reason) { setError(message(reason)); }
  }

  async function createProject() {
    if (!projectName.trim()) return;
    setBusy(true); setError(null);
    try {
      const created = await api.createProject(projectName.trim());
      setProjects((current) => [created, ...current]); setProject(created);
      setProjectName(""); setProjectDialog(false);
    } catch (reason) { setError(message(reason)); } finally { setBusy(false); }
  }

  async function upload(file: File) {
    if (!project) return;
    setBusy(true); setError(null);
    try {
      const created = await api.upload(project.project_id, file);
      setSources((current) => [created, ...current]); await selectSource(created);
    } catch (reason) { setError(message(reason)); } finally { setBusy(false); }
  }

  async function profile() {
    if (!source) return;
    setBusy(true); setError(null); setReport(null);
    try {
      let run = await api.startProfile(source.source_id); setRuns((current) => [run, ...current]);
      while (run.status === "queued" || run.status === "running") {
        await new Promise((resolve) => window.setTimeout(resolve, 500)); run = await api.run(run.run_id);
        setRuns((current) => current.map((item) => item.run_id === run.run_id ? run : item));
      }
      if (run.status === "failed") throw new Error(run.error ?? "Profiling failed");
      setReport(await api.report(run.run_id)); setView("quality");
    } catch (reason) { setError(message(reason)); } finally { setBusy(false); }
  }

  return (
    <main className="studio">
      <aside className="sidebar">
        <div className="logo"><Network size={21} /><strong>Orus</strong></div>
        <nav>
          <button className={view === "sources" ? "active" : ""} onClick={() => setView("sources")}><Files size={17} />Sources</button>
          <button className={view === "quality" ? "active" : ""} onClick={() => setView("quality")}><ShieldCheck size={17} />Quality</button>
          <button className={view === "runs" ? "active" : ""} onClick={() => setView("runs")}><Activity size={17} />Runs</button>
          <a href="http://127.0.0.1:5173" target="_blank" rel="noreferrer"><Network size={17} />Explorer</a>
        </nav>
        <div className="sidebar-foot">Local workspace</div>
      </aside>

      <section className="main-area">
        <header className="product-bar">
          <select aria-label="Projet" value={project?.project_id ?? ""} onChange={(event) => setProject(projects.find((item) => item.project_id === event.target.value) ?? null)}>
            {!project && <option value="">Aucun projet</option>}
            {projects.map((item) => <option key={item.project_id} value={item.project_id}>{item.name}</option>)}
          </select>
          <button className="icon-button" title="Nouveau projet" onClick={() => setProjectDialog(true)}><Plus size={17} /></button>
          <div className="global-search"><Search size={16} /><span>Data workspace</span></div>
          <span className={`engine-status ${engineReady === false ? "unavailable" : ""}`}><i />{engineReady === null ? "Checking engine" : engineReady ? "Engine ready" : "Engine unavailable"}</span>
        </header>

        <div className="content">
          <div className="page-heading"><div><span>Data sources</span><h1>{project?.name ?? "Workspace"}</h1></div><button className="primary" onClick={() => fileInput.current?.click()} disabled={!project || busy}><FilePlus2 size={16} />Importer un CSV</button><input ref={fileInput} hidden type="file" accept=".csv,text/csv" onChange={(event) => { const file = event.target.files?.[0]; if (file) void upload(file); event.target.value = ""; }} /></div>

          {!project ? <Empty icon={<Database />} title="Aucun projet" action="Créer un projet" onAction={() => setProjectDialog(true)} /> : sources.length === 0 ? <Empty icon={<FilePlus2 />} title="Aucune source" action="Importer un CSV" onAction={() => fileInput.current?.click()} /> : (
            <div className="data-layout">
              <section className="source-list"><header><span>Sources</span><strong>{sources.length}</strong></header>{sources.map((item) => <button key={item.source_id} className={source?.source_id === item.source_id ? "selected" : ""} onClick={() => void selectSource(item)}><Files size={16} /><span><strong>{item.filename}</strong><small>{formatBytes(item.size_bytes)}</small></span></button>)}</section>
              <section className="source-detail">
                <header className="source-header"><div><span>CSV source</span><h2>{source?.filename}</h2><small>{source ? `${formatBytes(source.size_bytes)} · SHA ${source.sha256.slice(0, 10)}` : ""}</small></div><button className="run-button" onClick={() => void profile()} disabled={busy || engineReady !== true}>{busy ? <RefreshCw className="spin" size={16} /> : <Play size={16} />}Profile data</button></header>
                <div className="tabs"><button className={view === "sources" ? "active" : ""} onClick={() => setView("sources")}>Preview</button><button className={view === "quality" ? "active" : ""} onClick={() => setView("quality")}>Quality profile</button><button className={view === "runs" ? "active" : ""} onClick={() => setView("runs")}>Runs</button><span>{runs[0]?.status ?? "not profiled"}</span></div>
                {view === "quality" ? (report ? <Quality report={report} /> : <PanelEmpty label="No quality profile" />) : view === "runs" ? <Runs runs={runs} /> : <PreviewTable preview={preview} />}
              </section>
            </div>
          )}
        </div>
      </section>
      {error && <div className="toast">{error}<button onClick={() => setError(null)}>Fermer</button></div>}
      {projectDialog && <div className="modal-backdrop" role="presentation"><form className="modal" onSubmit={(event) => { event.preventDefault(); void createProject(); }}><span>New workspace</span><h2>Create a project</h2><label>Project name<input autoFocus value={projectName} onChange={(event) => setProjectName(event.target.value)} placeholder="Revenue quality" /></label><div><button type="button" onClick={() => setProjectDialog(false)}>Cancel</button><button className="primary" type="submit" disabled={!projectName.trim() || busy}>Create project</button></div></form></div>}
    </main>
  );
}

function PreviewTable({ preview }: { preview: Preview | null }) {
  if (!preview) return null;
  return <div className="table-wrap"><table><thead><tr>{preview.columns.map((column) => <th key={column}>{column}</th>)}</tr></thead><tbody>{preview.rows.map((row, index) => <tr key={index}>{preview.columns.map((column, cell) => <td key={column}>{row[cell] ?? ""}</td>)}</tr>)}</tbody></table></div>;
}

function Quality({ report }: { report: ProfileReport }) {
  const nulls = report.columns.reduce((total, column) => total + column.null_count, 0);
  return <div className="quality"><div className="quality-metrics"><Metric label="Rows" value={report.rows_processed} /><Metric label="Columns" value={report.columns.length} /><Metric label="Null values" value={nulls} /><Metric label="Batches" value={report.batches_processed} /></div><div className="table-wrap"><table><thead><tr><th>Column</th><th>Type</th><th>Null rate</th><th>Distinct</th><th>Pattern</th></tr></thead><tbody>{report.columns.map((column) => <tr key={column.name}><td><strong>{column.name}</strong></td><td><span className="type-chip">{column.tag}</span></td><td>{(column.null_rate * 100).toFixed(2)}%</td><td>{column.distinct_count.toLocaleString("fr-FR")}{column.cardinality_mode === "approximate" ? " ~" : ""}</td><td>{column.detected_pattern ?? "—"}</td></tr>)}</tbody></table></div></div>;
}

function Runs({ runs }: { runs: ProfileRun[] }) { return runs.length === 0 ? <PanelEmpty label="No runs" /> : <div className="run-list">{runs.map((run) => <div key={run.run_id}><Activity size={16} /><span><strong>Profile data</strong><small>{new Date(run.created_at).toLocaleString("fr-FR")}</small></span><b className={`run-status ${run.status}`}>{run.status}</b></div>)}</div>; }
function PanelEmpty({ label }: { label: string }) { return <div className="panel-empty"><Activity size={24} /><strong>{label}</strong></div>; }

function Metric({ label, value }: { label: string; value: number }) { return <div className="metric"><span>{label}</span><strong>{value.toLocaleString("fr-FR")}</strong></div>; }
function Empty({ icon, title, action, onAction }: { icon: ReactNode; title: string; action: string; onAction: () => void }) { return <div className="empty">{icon}<strong>{title}</strong><button onClick={onAction}>{action}</button></div>; }
function formatBytes(value: number) { return value >= 1024 ** 2 ? `${(value / 1024 ** 2).toFixed(1)} MB` : `${(value / 1024).toFixed(1)} KB`; }
function message(reason: unknown) { return reason instanceof Error ? reason.message : "Unexpected error"; }

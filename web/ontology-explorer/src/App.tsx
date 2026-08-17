import { AlertCircle, Network, RefreshCw, Search } from "lucide-react";
import { useCallback, useEffect, useMemo, useState, type FormEvent } from "react";

import { api } from "./api";
import { GraphCanvas } from "./components/GraphCanvas";
import { Inspector } from "./components/Inspector";
import type { ObjectContext, OntologyObject, Relation, Statistics } from "./types";

const DEFAULT_CUSTOMER = "4962FDBE6BFEE6D";

export default function App() {
  const [query, setQuery] = useState(DEFAULT_CUSTOMER);
  const [statistics, setStatistics] = useState<Statistics | null>(null);
  const [objects, setObjects] = useState<Map<string, OntologyObject>>(new Map());
  const [relations, setRelations] = useState<Map<string, Relation>>(new Map());
  const [selectedId, setSelectedId] = useState<string | null>(null);
  const [context, setContext] = useState<ObjectContext | null>(null);
  const [expanded, setExpanded] = useState<Set<string>>(new Set());
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const refreshStatistics = useCallback(async () => {
    try {
      setStatistics(await api.statistics());
    } catch {
      setStatistics(null);
    }
  }, []);

  useEffect(() => void refreshStatistics(), [refreshStatistics]);

  const selectObject = useCallback(async (objectId: string) => {
    setSelectedId(objectId);
    setContext(null);
    try {
      setContext(await api.context(objectId));
    } catch (reason) {
      setError(message(reason));
    }
  }, []);

  async function search(event: FormEvent) {
    event.preventDefault();
    const normalized = query.trim().toUpperCase();
    if (!normalized) return;
    setBusy(true);
    setError(null);
    try {
      const customer = await api.searchCustomer(normalized);
      if (!customer) throw new Error("Client introuvable");
      setObjects(new Map([[customer.object_id, customer]]));
      setRelations(new Map());
      setExpanded(new Set());
      await selectObject(customer.object_id);
    } catch (reason) {
      setError(message(reason));
    } finally {
      setBusy(false);
    }
  }

  async function expandSelected() {
    if (!selectedId || expanded.has(selectedId)) return;
    setBusy(true);
    setError(null);
    try {
      const result = await api.neighbors(selectedId);
      setObjects((current) => {
        const next = new Map(current);
        for (const item of result.neighbors) next.set(item.object.object_id, item.object);
        return next;
      });
      setRelations((current) => {
        const next = new Map(current);
        for (const item of result.neighbors) next.set(item.relation.relation_id, item.relation);
        return next;
      });
      setExpanded((current) => new Set(current).add(selectedId));
    } catch (reason) {
      setError(message(reason));
    } finally {
      setBusy(false);
    }
  }

  const graphObjects = useMemo(() => [...objects.values()], [objects]);
  const graphRelations = useMemo(() => [...relations.values()], [relations]);

  return (
    <main className="app-shell">
      <header className="topbar">
        <div className="brand"><Network size={20} /><strong>Orus</strong><span>Ontology Explorer</span></div>
        <form className="search-form" onSubmit={search}>
          <Search size={17} />
          <input aria-label="Customer ID" value={query} onChange={(event) => setQuery(event.target.value)} placeholder="Customer ID" />
          <button type="submit" disabled={busy}>{busy ? <RefreshCw className="spin" size={17} /> : "Rechercher"}</button>
        </form>
        <div className="status"><i className={statistics ? "online" : "offline"} />{statistics ? "Connecté" : "Indisponible"}</div>
      </header>

      <section className="metrics-band" aria-label="Statistiques">
        <Metric label="Objets" value={statistics?.objects} />
        <Metric label="Relations" value={statistics?.relations} />
        <Metric label="Assertions" value={statistics?.assertions} />
        <div className="scope"><span>Graphe courant</span><strong>{objects.size} nœuds · {relations.size} liens</strong></div>
      </section>

      <div className="workspace">
        <GraphCanvas objects={graphObjects} relations={graphRelations} selectedId={selectedId} onSelect={selectObject} />
        <Inspector context={context} expanded={selectedId ? expanded.has(selectedId) : false} busy={busy} onExpand={expandSelected} onClose={() => { setSelectedId(null); setContext(null); }} />
        {objects.size === 0 && !busy && <div className="empty-state"><Network size={31} /><strong>Aucun contexte chargé</strong></div>}
        {error && <div className="error-toast"><AlertCircle size={18} /><span>{error}</span><button onClick={() => setError(null)}>Fermer</button></div>}
      </div>
    </main>
  );
}

function Metric({ label, value }: { label: string; value?: number }) {
  return <div className="metric"><span>{label}</span><strong>{value === undefined ? "—" : new Intl.NumberFormat("fr-FR").format(value)}</strong></div>;
}

function message(reason: unknown): string {
  return reason instanceof Error ? reason.message : "Erreur inattendue";
}

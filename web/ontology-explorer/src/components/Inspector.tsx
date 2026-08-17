import { ChevronRight, Database, ExternalLink, X } from "lucide-react";

import { assertionValue, typeName } from "../domain";
import type { ObjectContext } from "../types";

type Props = {
  context: ObjectContext | null;
  expanded: boolean;
  busy: boolean;
  onExpand: () => void;
  onClose: () => void;
};

export function Inspector({ context, expanded, busy, onExpand, onClose }: Props) {
  return (
    <aside className={`inspector ${context ? "is-open" : ""}`} aria-label="Inspecteur">
      <header className="inspector-header">
        <div>
          <span className="eyebrow">{context ? typeName(context.object.object_type_id) : "Sélection"}</span>
          <h2>{context ? primaryLabel(context) : "Aucun objet"}</h2>
        </div>
        {context && <button className="icon-button" title="Fermer" onClick={onClose}><X size={18} /></button>}
      </header>
      {context && (
        <div className="inspector-content">
          <section className="property-list">
            <h3>Propriétés</h3>
            {context.assertions.map((assertion) => (
              <div className="property-row" key={assertion.assertion_id}>
                <span>{assertion.predicate}</span>
                <strong>{assertionValue(assertion)}</strong>
                <small>{assertion.kind} · {assertion.confidence}</small>
              </div>
            ))}
          </section>
          <button className="expand-button" onClick={onExpand} disabled={busy || expanded}>
            <ExternalLink size={16} />
            {expanded ? "Voisinage chargé" : busy ? "Chargement…" : "Développer le voisinage"}
            <ChevronRight size={16} />
          </button>
          <section className="provenance-list">
            <h3><Database size={15} /> Provenance</h3>
            {context.provenance.map((source, index) => (
              <div className="source-row" key={`${source.source_id}-${source.global_offset}-${index}`}>
                <strong>Ligne {source.global_offset ?? "—"}</strong>
                <span>{source.source_column ?? "record"}</span>
                <small title={source.source_id}>{source.source_id.split("/").at(-1)}</small>
              </div>
            ))}
          </section>
          <footer className="object-id">{context.object.object_id}</footer>
        </div>
      )}
    </aside>
  );
}

function primaryLabel(context: ObjectContext): string {
  const assertion = context.assertions.find((item) =>
    ["customer_id", "name", "address"].includes(item.predicate),
  );
  return assertion ? assertionValue(assertion) : context.object.object_id.slice(0, 12);
}

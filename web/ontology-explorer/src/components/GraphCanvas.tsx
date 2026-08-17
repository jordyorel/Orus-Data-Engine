import cytoscape, { type Core } from "cytoscape";
import { Maximize2, Minus, Plus } from "lucide-react";
import { useEffect, useRef } from "react";

import { graphElements } from "../domain";
import type { OntologyObject, Relation } from "../types";

type Props = {
  objects: OntologyObject[];
  relations: Relation[];
  selectedId: string | null;
  onSelect: (objectId: string) => void;
};

export function GraphCanvas({ objects, relations, selectedId, onSelect }: Props) {
  const container = useRef<HTMLDivElement>(null);
  const instance = useRef<Core | null>(null);

  useEffect(() => {
    if (!container.current) return;
    const cy = cytoscape({
      container: container.current,
      elements: [],
      minZoom: 0.35,
      maxZoom: 2.5,
      style: [
        {
          selector: "node",
          style: {
            width: 52,
            height: 52,
            "background-color": "#ffffff",
            "border-width": 2,
            "border-color": "#87918d",
            label: "data(label)",
            color: "#202725",
            "font-size": 11,
            "font-family": "Inter, ui-sans-serif, system-ui",
            "text-valign": "bottom",
            "text-margin-y": 8,
            "text-max-width": "110px",
            "text-wrap": "ellipsis",
          },
        },
        { selector: 'node[type="Customer"]', style: { "border-color": "#0b766e", "background-color": "#dff3ef" } },
        { selector: 'node[type="Email"]', style: { "border-color": "#4c6a92", "background-color": "#e7eef7", shape: "round-rectangle" } },
        { selector: 'node[type="Company"]', style: { "border-color": "#b65d42", "background-color": "#f7e7df", shape: "diamond" } },
        { selector: "node:selected", style: { "border-width": 4, "border-color": "#111816" } },
        {
          selector: "edge",
          style: {
            width: 1.5,
            "line-color": "#a7afac",
            "target-arrow-color": "#707a76",
            "target-arrow-shape": "triangle",
            "curve-style": "bezier",
            label: "data(label)",
            color: "#59625f",
            "font-size": 9,
            "text-background-color": "#f7f8f6",
            "text-background-opacity": 1,
            "text-background-padding": "3px",
          },
        },
      ],
    });
    cy.on("tap", "node", (event) => onSelect(String(event.target.id())));
    instance.current = cy;
    return () => {
      cy.destroy();
      instance.current = null;
    };
  }, [onSelect]);

  useEffect(() => {
    const cy = instance.current;
    if (!cy) return;
    cy.elements().remove();
    cy.add(graphElements(objects, relations));
    cy.layout({ name: "cose", animate: false, fit: true, padding: 70 }).run();
  }, [objects, relations]);

  useEffect(() => {
    const cy = instance.current;
    if (!cy) return;
    cy.nodes().unselect();
    if (selectedId) cy.getElementById(selectedId).select();
  }, [selectedId]);

  return (
    <section className="graph-panel" aria-label="Graphe ontologique">
      <div ref={container} className="graph-canvas" />
      <div className="graph-tools" aria-label="Contrôles du graphe">
        <button title="Zoom avant" onClick={() => instance.current?.zoom(instance.current.zoom() * 1.2)}><Plus size={17} /></button>
        <button title="Zoom arrière" onClick={() => instance.current?.zoom(instance.current.zoom() / 1.2)}><Minus size={17} /></button>
        <button title="Ajuster" onClick={() => instance.current?.fit(undefined, 70)}><Maximize2 size={17} /></button>
      </div>
      <div className="legend" aria-label="Légende">
        <span><i className="customer-dot" />Customer</span>
        <span><i className="email-dot" />Email</span>
        <span><i className="company-dot" />Company</span>
      </div>
    </section>
  );
}

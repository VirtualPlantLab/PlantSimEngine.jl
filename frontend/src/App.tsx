import { useCallback, useEffect, useState } from "react";
import {
  Background,
  BackgroundVariant,
  Controls,
  MiniMap,
  ReactFlow,
  addEdge,
  useEdgesState,
  useNodesState,
  type Connection,
  type Edge,
  type Node,
} from "@xyflow/react";
import "@xyflow/react/dist/style.css";
import { AlertTriangle, GitPullRequestArrow, RotateCcw, ScissorsLineDashed } from "lucide-react";
import { ModelNode } from "./ModelNode";
import { layoutGraph } from "./layout";
import { sampleGraph } from "./sampleGraph";
import type { DependencyGraphView, GraphEdgeData, GraphNodeData } from "./types";
import "./styles.css";

const nodeTypes = { model: ModelNode };

export default function App() {
  const [graph] = useState<DependencyGraphView>(loadInitialGraph());
  const [selected, setSelected] = useState<GraphNodeData | null>(null);
  const [nodes, setNodes, onNodesChange] = useNodesState<Node<GraphNodeData>>([]);
  const [edges, setEdges, onEdgesChange] = useEdgesState<Edge<GraphEdgeData>>([]);

  useEffect(() => {
    const nextNodes = graph.nodes.map((node) => ({
      id: node.id,
      type: "model",
      position: { x: 0, y: 0 },
      data: node,
    }));
    const nextEdges = graph.edges.map((edge) => ({
      id: edge.id,
      source: edge.source,
      target: edge.target,
      sourceHandle: edge.sourcePort ?? undefined,
      targetHandle: edge.targetPort ?? undefined,
      label: edge.label,
      animated: edge.scaleRelation === "multiscale",
      className: `${edge.kind} ${edge.scaleRelation}`,
      data: edge,
    }));
    layoutGraph(nextNodes, nextEdges).then((layouted) => {
      setNodes(layouted);
      setEdges(nextEdges);
    });
  }, [graph, setEdges, setNodes]);

  const onConnect = useCallback((connection: Connection) => {
    setEdges((current) => addEdge({ ...connection, type: "smoothstep", animated: true }, current));
  }, [setEdges]);

  const relayout = useCallback(() => {
    layoutGraph(nodes, edges).then(setNodes);
  }, [edges, nodes, setNodes]);

  return (
    <main className="app-shell">
      <section className="graph-panel">
        <div className="topbar">
          <div>
            <div className="eyebrow">PlantSimEngine</div>
            <h1>Dependency Graph</h1>
          </div>
          <div className="metrics">
            <span>{graph.nodes.length} models</span>
            <span>{graph.edges.length} links</span>
            {graph.cyclic && <span className="warn"><AlertTriangle size={14} /> cycle</span>}
          </div>
          <button className="icon-button" onClick={relayout} title="Run layout">
            <RotateCcw size={17} />
          </button>
        </div>
        <ReactFlow
          nodes={nodes}
          edges={edges}
          nodeTypes={nodeTypes}
          onNodesChange={onNodesChange}
          onEdgesChange={onEdgesChange}
          onConnect={onConnect}
          onNodeClick={(_, node) => setSelected(node.data)}
          fitView
        >
          <Background variant={BackgroundVariant.Dots} gap={22} size={1.2} />
          <Controls />
          <MiniMap pannable zoomable nodeStrokeWidth={3} />
        </ReactFlow>
      </section>
      <aside className="inspector">
        <header>
          <GitPullRequestArrow size={19} />
          <h2>Inspector</h2>
        </header>
        {selected ? (
          <div className="details">
            <Row label="Process" value={selected.process} />
            <Row label="Model" value={selected.modelType} />
            <Row label="Scale" value={selected.scale} />
            <Row label="Rate" value={selected.rate} />
            <Row label="Inputs" value={selected.inputs.map((port) => port.name).join(", ") || "none" } />
            <Row label="Outputs" value={selected.outputs.map((port) => port.name).join(", ") || "none" } />
            {selected.inputs.filter((port) => port.previousTimeStep).map((port) => (
              <div className="edit-suggestion" key={port.id}><ScissorsLineDashed size={14} /> {port.name} uses previous timestep</div>
            ))}
          </div>
        ) : (
          <div className="empty-state">Select a model node.</div>
        )}
        <h3>Diagnostics</h3>
        {graph.diagnostics.length > 0 ? graph.diagnostics.map((item) => <div className="diagnostic" key={item}>{item}</div>) : <div className="empty-state">No diagnostics.</div>}
      </aside>
    </main>
  );
}

function Row({ label, value }: { label: string; value: string }) {
  return <div className="row"><span>{label}</span><strong>{value}</strong></div>;
}

function loadInitialGraph() {
  const embedded = document.getElementById("pse-graph-data");
  if (embedded?.textContent) return JSON.parse(embedded.textContent) as DependencyGraphView;
  const fromWindow = (window as Window & { PlantSimEngineGraph?: DependencyGraphView }).PlantSimEngineGraph;
  return fromWindow ?? sampleGraph;
}

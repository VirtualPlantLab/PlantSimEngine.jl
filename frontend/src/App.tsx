import { useCallback, useEffect, useMemo, useState } from "react";
import {
  Background,
  Controls,
  MiniMap,
  ReactFlow,
  addEdge,
  MarkerType,
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
import type { DependencyGraphView, GraphEdgeData, GraphNodeData, GraphPort, RuntimeGraphNodeData } from "./types";
import "./styles.css";

const nodeTypes = { model: ModelNode };
const edgeColors = {
  base: "#a99a8c",
  accent: "#1f7a53",
};

export default function App() {
  const [graph] = useState<DependencyGraphView>(loadInitialGraph());
  const [selected, setSelected] = useState<GraphNodeData | null>(null);
  const [activePort, setActivePort] = useState<GraphPort | null>(null);
  const [nodes, setNodes, onNodesChange] = useNodesState<Node<RuntimeGraphNodeData>>([]);
  const [edges, setEdges, onEdgesChange] = useEdgesState<Edge<GraphEdgeData>>([]);
  const highlight = useMemo(() => deriveHighlight(graph, activePort), [activePort, graph]);

  useEffect(() => {
    const nextNodes = graph.nodes.map((node) => ({
      id: node.id,
      type: "model",
      position: { x: 0, y: 0 },
      data: runtimeNodeData(node, null, new Set<string>(), setActivePort),
    }));
    const nextEdges = graph.edges.map((edge) => flowEdge(edge, new Set<string>(), false));
    layoutGraph(nextNodes, nextEdges).then((layouted) => {
      setNodes(layouted);
      setEdges(nextEdges);
    });
  }, [graph, setEdges, setNodes]);

  useEffect(() => {
    setNodes((current) => current.map((node) => ({
      ...node,
      data: runtimeNodeData(node.data, activePort, highlight.ports, setActivePort),
    })));
    setEdges((current) => current.map((edge) => edge.data ? flowEdge(edge.data, highlight.edges, Boolean(activePort)) : edge));
  }, [activePort, highlight.edges, highlight.ports, setEdges, setNodes]);

  const onConnect = useCallback((connection: Connection) => {
    setEdges((current) => addEdge({
      ...connection,
      type: "smoothstep",
      animated: true,
      markerEnd: edgeMarker(false),
      style: edgeStyle(false),
      zIndex: 30,
    }, current));
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
          <Background color="transparent" />
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

function runtimeNodeData(
  node: GraphNodeData,
  activePort: GraphPort | null,
  highlightedPortIds: Set<string>,
  setActivePort: (port: GraphPort | null) => void,
): RuntimeGraphNodeData {
  return {
    ...node,
    activePortId: activePort?.id ?? null,
    highlightedPortIds: [...highlightedPortIds],
    onPortEnter: setActivePort,
    onPortLeave: () => setActivePort(null),
  };
}

function flowEdge(edge: GraphEdgeData, highlightedEdgeIds: Set<string>, hasActivePort: boolean): Edge<GraphEdgeData> {
  const highlighted = highlightedEdgeIds.has(edge.id);

  return {
    id: edge.id,
    source: edge.source,
    target: edge.target,
    sourceHandle: edge.sourcePort ?? undefined,
    targetHandle: edge.targetPort ?? undefined,
    label: edge.label,
    labelBgBorderRadius: 7,
    labelBgPadding: [7, 4],
    labelBgStyle: {
      fill: highlighted ? "#fffaf2" : "#fffdfa",
      stroke: highlighted ? edgeColors.accent : "#ded2c3",
      strokeWidth: highlighted ? 1.25 : 1,
    },
    labelStyle: {
      fill: "#312721",
      fontFamily: "ui-monospace, SFMono-Regular, Menlo, monospace",
      fontSize: 12,
      fontWeight: 560,
    },
    markerEnd: edgeMarker(highlighted),
    type: "smoothstep",
    animated: edge.scaleRelation === "multiscale",
    className: `${edge.kind} ${edge.scaleRelation} ${highlighted ? "highlighted" : hasActivePort ? "dimmed" : ""}`,
    style: edgeStyle(highlighted),
    zIndex: highlighted ? 40 : 30,
    data: edge,
  };
}

function edgeMarker(highlighted: boolean) {
  return {
    type: MarkerType.ArrowClosed,
    color: highlighted ? edgeColors.accent : edgeColors.base,
    width: highlighted ? 10 : 9,
    height: highlighted ? 10 : 9,
    markerUnits: "userSpaceOnUse",
    strokeWidth: 1.2,
  };
}

function edgeStyle(highlighted: boolean) {
  return {
    stroke: highlighted ? edgeColors.accent : edgeColors.base,
    strokeWidth: highlighted ? 3 : 2.2,
  };
}

function deriveHighlight(graph: DependencyGraphView, activePort: GraphPort | null) {
  const result = {
    edges: new Set<string>(),
    nodes: new Set<string>(),
    ports: new Set<string>(),
  };
  if (!activePort) return result;

  result.ports.add(activePort.id);
  const visitedPorts = new Set<string>([activePort.id]);
  const queue = [activePort.id];

  while (queue.length > 0) {
    const portId = queue.shift()!;
    for (const edge of graph.edges) {
      const sourcePort = edge.sourcePort;
      const targetPort = edge.targetPort;
      if (!sourcePort || !targetPort) continue;
      if (sourcePort !== portId && targetPort !== portId) continue;

      result.edges.add(edge.id);
      result.nodes.add(edge.source);
      result.nodes.add(edge.target);
      result.ports.add(sourcePort);
      result.ports.add(targetPort);

      const nextPort = sourcePort === portId ? targetPort : sourcePort;
      if (!visitedPorts.has(nextPort)) {
        visitedPorts.add(nextPort);
        queue.push(nextPort);
      }
    }
  }

  return result;
}

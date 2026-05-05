import { useCallback, useEffect, useMemo, useState, type ReactNode } from "react";
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
  type ReactFlowInstance,
} from "@xyflow/react";
import "@xyflow/react/dist/style.css";
import {
  AlertTriangle,
  CircleAlert,
  Filter,
  GitPullRequestArrow,
  Network,
  RotateCcw,
  Route,
  ScissorsLineDashed,
  Search,
  X,
} from "lucide-react";
import { DependencyEdge } from "./DependencyEdge";
import { ModelNode } from "./ModelNode";
import { layoutGraph, type LayoutMode } from "./layout";
import { sampleGraph } from "./sampleGraph";
import type { DependencyGraphView, GraphEdgeData, GraphEditorState, GraphNodeData, GraphPort, ModelDescriptor, RuntimeGraphNodeData } from "./types";
import "./styles.css";

type EdgeFilterKey = "dataFlow" | "mapped" | "callStack";
type EdgeFilters = Record<EdgeFilterKey, boolean>;
type FocusMode = "none" | "upstream" | "downstream" | "neighborhood";
type SidePanel = "inspector" | "add_model" | "mapping_code" | null;

type SearchResult = {
  id: string;
  kind: "model" | "input" | "output";
  node: GraphNodeData;
  port?: GraphPort;
  label: string;
  detail: string;
};

type RequiredInput = {
  node: GraphNodeData;
  port: GraphPort;
  reason: "previous_time_step" | "mapped_unresolved" | "user_initialization";
};

type ValidationWarning = {
  id: string;
  severity: "error" | "warning" | "info";
  category: "init" | "mapping" | "ownership" | "hard_dependency" | "cross_scale";
  title: string;
  detail: string;
  nodeId?: string;
  nodeIds?: string[];
  portId?: string;
  portIds?: string[];
  edgeId?: string;
};

type FocusState = {
  active: boolean;
  edges: Set<string>;
  nodes: Set<string>;
  ports: Set<string>;
};

const nodeTypes = { model: ModelNode };
const edgeTypes = { dependency: DependencyEdge };
const edgeColors = {
  base: "#a99a8c",
  accent: "#1f7a53",
  mapped: "#4f8d69",
  hard: "#bf6a54",
};

const defaultEdgeFilters: EdgeFilters = {
  dataFlow: true,
  mapped: true,
  callStack: true,
};

const focusLabels: Record<FocusMode, string> = {
  none: "No focus",
  upstream: "Upstream",
  downstream: "Downstream",
  neighborhood: "Both",
};

const layoutLabels: Record<LayoutMode, string> = {
  data_flow: "Data-flow",
  compact: "Compact",
  scale_grouped: "Scale grouped",
  call_stack: "Call stack",
};

export default function App() {
  const [graph, setGraph] = useState<DependencyGraphView>(loadInitialGraph());
  const [editorModels, setEditorModels] = useState<ModelDescriptor[]>([]);
  const [editorSocket, setEditorSocket] = useState<WebSocket | null>(null);
  const [editorConnected, setEditorConnected] = useState(false);
  const [canUndo, setCanUndo] = useState(false);
  const [canRedo, setCanRedo] = useState(false);
  const [activePanel, setActivePanel] = useState<SidePanel>("inspector");
  const [mappingCode, setMappingCode] = useState("");
  const [lastSavedPath, setLastSavedPath] = useState<string | null>(null);
  const [editorFeedback, setEditorFeedback] = useState<{ kind: "error" | "info"; text: string } | null>(null);
  const [savePath, setSavePath] = useState("mapping.generated.jl");
  const [customScales, setCustomScales] = useState<string[]>([]);
  const [selected, setSelected] = useState<GraphNodeData | null>(null);
  const [activePort, setActivePort] = useState<GraphPort | null>(null);
  const [showRequiredPanel, setShowRequiredPanel] = useState(false);
  const [showWarningsPanel, setShowWarningsPanel] = useState(false);
  const [showSearchResults, setShowSearchResults] = useState(false);
  const [searchQuery, setSearchQuery] = useState("");
  const [layoutMode, setLayoutMode] = useState<LayoutMode>("data_flow");
  const [focusMode, setFocusMode] = useState<FocusMode>("neighborhood");
  const [edgeFilters, setEdgeFilters] = useState<EdgeFilters>(defaultEdgeFilters);
  const [collapsedScales, setCollapsedScales] = useState<Set<string>>(() => new Set());
  const [pinnedFocus, setPinnedFocus] = useState<FocusState | null>(null);
  const [selectedEdge, setSelectedEdge] = useState<GraphEdgeData | null>(null);
  const [flowInstance, setFlowInstance] = useState<ReactFlowInstance<Node<RuntimeGraphNodeData>, Edge<GraphEdgeData>> | null>(null);
  const [nodes, setNodes, onNodesChange] = useNodesState<Node<RuntimeGraphNodeData>>([]);
  const [edges, setEdges, onEdgesChange] = useEdgesState<Edge<GraphEdgeData>>([]);

  const nodeById = useMemo(() => new Map(graph.nodes.map((node) => [node.id, node])), [graph]);
  const portById = useMemo(() => buildPortIndex(graph), [graph]);
  const incomingByPort = useMemo(() => groupEdgesByPort(graph.edges, "targetPort"), [graph.edges]);
  const outgoingByPort = useMemo(() => groupEdgesByPort(graph.edges, "sourcePort"), [graph.edges]);
  const requiredInputPortIds = useMemo(() => deriveRequiredInputPorts(graph), [graph]);
  const requiredInputs = useMemo(() => deriveRequiredInputs(graph, requiredInputPortIds, incomingByPort), [graph, incomingByPort, requiredInputPortIds]);
  const warningItems = useMemo(() => deriveValidationWarnings(graph, requiredInputPortIds, incomingByPort), [graph, incomingByPort, requiredInputPortIds]);
  const actionableWarningItems = useMemo(() => warningItems.filter((item) => item.severity !== "info"), [warningItems]);
  const searchResults = useMemo(() => deriveSearchResults(graph, searchQuery), [graph, searchQuery]);
  const visibleNodeData = useMemo(() => graph.nodes.filter((node) => !collapsedScales.has(node.scale)), [collapsedScales, graph.nodes]);
  const editorScales = useMemo(() => {
    const merged = [...graph.scales, ...customScales];
    return [...new Set(merged)];
  }, [customScales, graph.scales]);
  const visibleNodeIds = useMemo(() => new Set(visibleNodeData.map((node) => node.id)), [visibleNodeData]);
  const visibleEdgeData = useMemo(() => graph.edges.filter((edge) => (
    edgeMatchesFilters(edge, edgeFilters) &&
    visibleNodeIds.has(edge.source) &&
    visibleNodeIds.has(edge.target)
  )), [edgeFilters, graph.edges, visibleNodeIds]);
  const hoverHighlight = useMemo(() => deriveHighlight(graph, activePort), [activePort, graph]);
  const traversalFocus = useMemo(
    () => deriveFocus(graph, selected?.id ?? null, activePort, focusMode),
    [activePort, focusMode, graph, selected?.id],
  );
  const focus = useMemo(() => pinnedFocus?.active ? pinnedFocus : traversalFocus, [pinnedFocus, traversalFocus]);

  useEffect(() => {
    const config = loadEditorConfig();
    if (!config?.websocketUrl) return;

    const socket = new WebSocket(config.websocketUrl);
    setEditorSocket(socket);
    socket.addEventListener("open", () => {
      setEditorConnected(true);
      setEditorFeedback(null);
    });
    socket.addEventListener("close", () => {
      setEditorConnected(false);
      setEditorFeedback({ kind: "error", text: "Graph editor connection closed. Refresh the page or restart the Julia session." });
    });
    socket.addEventListener("message", (event) => {
      const payload = JSON.parse(event.data) as GraphEditorState;
      if (payload.graph) setGraph(payload.graph);
      if (payload.models) setEditorModels(payload.models);
      if (typeof payload.mappingCode === "string") setMappingCode(payload.mappingCode);
      if (typeof payload.lastSavedPath === "string") setLastSavedPath(payload.lastSavedPath);
      setCanUndo(Boolean(payload.canUndo));
      setCanRedo(Boolean(payload.canRedo));
      if (payload.ok === false) {
        const message = payload.diagnostics?.[0] ?? "Graph editor command failed.";
        setEditorFeedback({ kind: "error", text: message });
      } else if (payload.diagnostics?.length) {
        setEditorFeedback({ kind: "info", text: payload.diagnostics[0] });
      } else {
        setEditorFeedback(null);
      }
    });
    return () => socket.close();
  }, []);

  const sendEditorCommand = useCallback((command: Record<string, unknown>) => {
    if (!editorSocket || editorSocket.readyState !== WebSocket.OPEN) {
      setEditorFeedback({ kind: "error", text: "Graph editor is offline; command was not sent." });
      return;
    }
    editorSocket.send(JSON.stringify(command));
  }, [editorSocket]);

  const togglePanel = useCallback((panel: Exclude<SidePanel, null>) => {
    setActivePanel((current) => current === panel ? null : panel);
  }, []);

  const addCustomScale = useCallback((rawScale: string) => {
    const scale = rawScale.trim();
    if (!scale) return;
    setCustomScales((current) => current.includes(scale) || graph.scales.includes(scale) ? current : [...current, scale]);
  }, [graph.scales]);

  useEffect(() => {
    const nextNodes = visibleNodeData.map((node) => ({
      id: node.id,
      type: "model",
      position: { x: 0, y: 0 },
      data: runtimeNodeData(node, {
        activePort: null,
        highlightedPortIds: new Set<string>(),
        focusedPortIds: new Set<string>(),
        requiredInputPortIds,
        cycleNodeIds: new Set(graph.cycleNodes),
        focusedNodeIds: new Set<string>(),
        hasActiveFocus: false,
        setActivePort,
      }),
    }));
    const nextEdges = visibleEdgeData.map((edge) => flowEdge(edge, new Set<string>(), new Set<string>(), false, false));
    layoutGraph(nextNodes, nextEdges, layoutMode).then((layouted) => {
      setNodes(layouted);
      setEdges(nextEdges);
    });
  }, [graph.cycleNodes, layoutMode, requiredInputPortIds, setEdges, setNodes, visibleEdgeData, visibleNodeData]);

  useEffect(() => {
    const focusEdges = focus.active ? focus.edges : new Set<string>();
    setNodes((current) => current.map((node) => ({
      ...node,
      data: runtimeNodeData(node.data, {
        activePort,
        highlightedPortIds: hoverHighlight.ports,
        focusedPortIds: focus.ports,
        requiredInputPortIds,
        cycleNodeIds: new Set(graph.cycleNodes),
        focusedNodeIds: focus.nodes,
        hasActiveFocus: focus.active,
        setActivePort,
      }),
    })));
    setEdges((current) => current.map((edge) => edge.data ? flowEdge(edge.data, hoverHighlight.edges, focusEdges, Boolean(activePort), focus.active) : edge));
  }, [activePort, focus, graph.cycleNodes, hoverHighlight.edges, hoverHighlight.ports, requiredInputPortIds, setEdges, setNodes]);

  const onConnect = useCallback((connection: Connection) => {
    setEdges((current) => addEdge({
      ...connection,
      type: "dependency",
      animated: true,
      markerEnd: edgeMarker(edgeColors.base),
      style: edgeStyle(edgeColors.base, false),
      zIndex: 5,
    }, current));
  }, [setEdges]);

  const relayout = useCallback(() => {
    layoutGraph(nodes, edges, layoutMode).then(setNodes);
  }, [edges, layoutMode, nodes, setNodes]);

  const focusNode = useCallback((node: GraphNodeData, port?: GraphPort | null) => {
    setPinnedFocus(null);
    setSelectedEdge(null);
    setSelected(node);
    setActivePort(port ?? null);
    setCollapsedScales((current) => {
      if (!current.has(node.scale)) return current;
      const next = new Set(current);
      next.delete(node.scale);
      return next;
    });
    const renderedNode = nodes.find((item) => item.id === node.id);
    if (renderedNode && flowInstance) {
      flowInstance.setCenter(renderedNode.position.x + 156, renderedNode.position.y + 90, { zoom: 0.85, duration: 520 });
    }
  }, [flowInstance, nodes]);

  const focusEdge = useCallback((edge: GraphEdgeData) => {
    const port = edge.targetPort ? portById.get(edge.targetPort)?.port : edge.sourcePort ? portById.get(edge.sourcePort)?.port : null;
    const node = port?.id === edge.targetPort ? nodeById.get(edge.target) : nodeById.get(edge.source);
    if (node) focusNode(node, port ?? null);
  }, [focusNode, nodeById, portById]);

  const toggleEdgeFilter = useCallback((key: EdgeFilterKey) => {
    setEdgeFilters((current) => ({ ...current, [key]: !current[key] }));
  }, []);

  const toggleScale = useCallback((scale: string) => {
    setSelected(null);
    setSelectedEdge(null);
    setActivePort(null);
    setPinnedFocus(null);
    setCollapsedScales((current) => {
      const next = new Set(current);
      if (next.has(scale)) next.delete(scale);
      else next.add(scale);
      return next;
    });
  }, []);

  const expandAllScales = useCallback(() => setCollapsedScales(new Set()), []);

  const focusWarning = useCallback((warning: ValidationWarning) => {
    if (warning.portIds?.length) {
      const nextFocus = emptyFocusState();
      nextFocus.active = true;
      for (const portId of warning.portIds) {
        const target = portById.get(portId);
        if (!target) continue;
        nextFocus.ports.add(portId);
        nextFocus.nodes.add(target.node.id);
      }
      setPinnedFocus(nextFocus);
      const first = portById.get(warning.portIds[0]);
      if (first) {
        setSelected(null);
        setSelectedEdge(null);
        setActivePort(null);
        if (flowInstance && warning.nodeIds && warning.nodeIds.length > 1) {
          flowInstance.fitView({
            nodes: warning.nodeIds.map((id) => ({ id })),
            padding: 0.28,
            duration: 520,
            maxZoom: 0.95,
          });
        } else {
          const renderedNode = nodes.find((item) => item.id === first.node.id);
          if (renderedNode && flowInstance) {
            flowInstance.setCenter(renderedNode.position.x + 156, renderedNode.position.y + 90, { zoom: 0.9, duration: 520 });
          }
        }
      }
      return;
    }

    setPinnedFocus(null);
    setSelectedEdge(null);
    if (warning.edgeId) {
      const edge = graph.edges.find((item) => item.id === warning.edgeId);
      if (edge) focusEdge(edge);
      return;
    }
    if (warning.portId) {
      const target = portById.get(warning.portId);
      if (target) focusNode(target.node, target.port);
      return;
    }
    if (warning.nodeId) {
      const node = nodeById.get(warning.nodeId);
      if (node) focusNode(node);
    }
  }, [flowInstance, focusEdge, focusNode, graph.edges, nodeById, nodes, portById]);

  return (
    <main className="app-shell">
      <section className="graph-panel">
        <div className="topbar graph-workbench">
          <div className="brand-block">
            <div className="eyebrow">PlantSimEngine</div>
            <h1>Dependency Graph</h1>
          </div>

          <div className="search-box">
            <Search size={15} />
            <input
              value={searchQuery}
              placeholder="Search model or variable"
              onChange={(event) => {
                setSearchQuery(event.target.value);
                setShowSearchResults(true);
              }}
              onFocus={() => setShowSearchResults(true)}
            />
            {searchQuery && (
              <button className="clear-search" onClick={() => setSearchQuery("")} title="Clear search">
                <X size={13} />
              </button>
            )}
            {showSearchResults && searchQuery.trim().length > 0 && (
              <div className="search-results">
                {searchResults.length > 0 ? searchResults.map((result) => (
                  <button
                    key={result.id}
                    className="search-result"
                    onClick={() => {
                      focusNode(result.node, result.port ?? null);
                      setSearchQuery(result.label);
                      setShowSearchResults(false);
                    }}
                  >
                    <strong>{result.label}</strong>
                    <span>{result.detail}</span>
                  </button>
                )) : <div className="empty-state compact">No match.</div>}
              </div>
            )}
          </div>

          <div className="metrics">
            <span>{visibleNodeData.length}/{graph.nodes.length} models</span>
            <span>{visibleEdgeData.length}/{graph.edges.length} links</span>
            {requiredInputs.length > 0 && (
              <button
                className={`metric-button warn ${showRequiredPanel ? "active" : ""}`}
                title={`${requiredInputs.length} required initializations`}
                onClick={() => setShowRequiredPanel((open) => !open)}
              >
                <CircleAlert size={14} /> {requiredInputs.length} init
              </button>
            )}
            {actionableWarningItems.length > 0 && (
              <button
                className={`metric-button caution ${showWarningsPanel ? "active" : ""}`}
                title={`${actionableWarningItems.length} actionable graph warnings`}
                onClick={() => setShowWarningsPanel((open) => !open)}
              >
                <AlertTriangle size={14} /> {actionableWarningItems.length} warn
              </button>
            )}
            {graph.cyclic && <span className="warn"><AlertTriangle size={14} /> cycle</span>}
          </div>

          <div className="toolbar-group">
            <label className="select-control" title="Choose how the graph should be arranged">
              <Network size={14} />
              <select value={layoutMode} onChange={(event) => setLayoutMode(event.target.value as LayoutMode)}>
                {(Object.keys(layoutLabels) as LayoutMode[]).map((mode) => <option key={mode} value={mode}>{layoutLabels[mode]}</option>)}
              </select>
            </label>
            <label className="select-control" title="Dim graph context around the current selection">
              <Route size={14} />
              <select value={focusMode} onChange={(event) => setFocusMode(event.target.value as FocusMode)}>
                {(Object.keys(focusLabels) as FocusMode[]).map((mode) => <option key={mode} value={mode}>{focusLabels[mode]}</option>)}
              </select>
            </label>
            <button className="icon-button" onClick={relayout} title="Run layout">
              <RotateCcw size={17} />
            </button>
          </div>

          <div className="toolbar-group panel-switch">
            <button className={`metric-button ${activePanel === "inspector" ? "active" : ""}`} onClick={() => togglePanel("inspector")}>Inspector</button>
            <button className={`metric-button ${activePanel === "add_model" ? "active" : ""}`} onClick={() => togglePanel("add_model")}>Add model</button>
            <button className={`metric-button ${activePanel === "mapping_code" ? "active" : ""}`} onClick={() => togglePanel("mapping_code")}>Mapping code</button>
          </div>

          {editorSocket && (
            <div className="toolbar-group live-session">
              <span className={editorConnected ? "live-pill connected" : "live-pill"}>{editorConnected ? "live" : "offline"}</span>
              <button className="metric-button" disabled={!canUndo} onClick={() => sendEditorCommand({ action: "undo" })}>Undo</button>
              <button className="metric-button" disabled={!canRedo} onClick={() => sendEditorCommand({ action: "redo" })}>Redo</button>
            </div>
          )}
        </div>

        {editorFeedback && (
          <div className={`editor-feedback ${editorFeedback.kind}`} role="status" aria-live="polite">
            {editorFeedback.text}
          </div>
        )}

        <RelationshipLegend filters={edgeFilters} onToggle={toggleEdgeFilter} />
        <ScaleControls scales={graph.scales} collapsedScales={collapsedScales} onToggle={toggleScale} onExpandAll={expandAllScales} />

        {showRequiredPanel && (
          <FloatingPanel className="required-panel" title="Required Initializations" subtitle={`${requiredInputs.length} inputs`} onClose={() => setShowRequiredPanel(false)}>
            <RequiredInputList groups={groupRequiredInputs(requiredInputs)} onSelect={focusNode} />
          </FloatingPanel>
        )}

        {showWarningsPanel && (
          <FloatingPanel className="warnings-panel" title="Validation Warnings" subtitle={`${actionableWarningItems.length} warnings, ${warningItems.length - actionableWarningItems.length} info`} onClose={() => setShowWarningsPanel(false)}>
            <WarningList warnings={warningItems} onFocusWarning={focusWarning} />
          </FloatingPanel>
        )}

        <ReactFlow
          nodes={nodes}
          edges={edges}
          nodeTypes={nodeTypes}
          edgeTypes={edgeTypes}
          onNodesChange={onNodesChange}
          onEdgesChange={onEdgesChange}
          onConnect={onConnect}
          onInit={setFlowInstance}
          onPaneClick={() => setShowSearchResults(false)}
          onEdgeClick={(_, edge) => {
            if (edge.data) {
              setSelectedEdge(edge.data);
              setSelected(null);
              setActivePort(null);
              setPinnedFocus(null);
            }
          }}
          onNodeClick={(_, node) => {
            setSelectedEdge(null);
            setSelected(node.data);
          }}
          fitView
          fitViewOptions={{ padding: 0.08, minZoom: 0.03, maxZoom: 1 }}
          minZoom={0.03}
          maxZoom={2}
        >
          <Background color="transparent" />
          <Controls />
          <MiniMap pannable zoomable nodeStrokeWidth={3} />
        </ReactFlow>
      </section>

      {activePanel && (
        <aside className="inspector">
          {activePanel === "inspector" && (
            <>
              <header>
                <GitPullRequestArrow size={19} />
                <h2>Inspector</h2>
              </header>
              <InspectorDetails
                selected={selected}
                selectedEdge={selectedEdge}
                activePort={activePort}
                requiredInputPortIds={requiredInputPortIds}
                incomingEdges={activePort ? incomingByPort.get(activePort.id) ?? [] : []}
                outgoingEdges={activePort ? outgoingByPort.get(activePort.id) ?? [] : []}
                nodeById={nodeById}
                portById={portById}
                onFocusEdge={focusEdge}
              />
              <h3>Required Initializations</h3>
              <RequiredInputList groups={groupRequiredInputs(requiredInputs)} onSelect={focusNode} compact />
              <h3>Diagnostics</h3>
              {graph.diagnostics.length > 0 ? graph.diagnostics.map((item) => <div className="diagnostic" key={item}>{item}</div>) : <div className="empty-state">No diagnostics.</div>}
            </>
          )}

          {activePanel === "add_model" && (
            <>
              <header>
                <GitPullRequestArrow size={19} />
                <h2>Add Model</h2>
              </header>
              {editorModels.length > 0 ? (
                <ModelBrowser
                  models={editorModels}
                  scales={editorScales}
                  onAddScale={addCustomScale}
                  onCommand={sendEditorCommand}
                  disabled={!editorConnected}
                />
              ) : <div className="empty-state">No model type is available.</div>}
            </>
          )}

          {activePanel === "mapping_code" && (
            <>
              <header>
                <GitPullRequestArrow size={19} />
                <h2>Mapping Code</h2>
              </header>
              <MappingCodePanel
                code={mappingCode}
                savePath={savePath}
                lastSavedPath={lastSavedPath}
                onSavePathChange={setSavePath}
                onSave={() => sendEditorCommand({ action: "write_mapping_code", path: savePath })}
              />
            </>
          )}
        </aside>
      )}
    </main>
  );
}

function RelationshipLegend({ filters, onToggle }: { filters: EdgeFilters; onToggle: (key: EdgeFilterKey) => void }) {
  return (
    <div className="relationship-legend">
      <div className="legend-title"><Filter size={13} /> Relationships</div>
      <button className={filters.dataFlow ? "active" : ""} onClick={() => onToggle("dataFlow")}><span className="legend-line data-flow" /> data flow</button>
      <button className={filters.mapped ? "active" : ""} onClick={() => onToggle("mapped")}><span className="legend-line mapped" /> mapped</button>
      <button className={filters.callStack ? "active" : ""} onClick={() => onToggle("callStack")}><span className="legend-line call" /> call stack</button>
      <div className="legend-note"><CircleAlert size={12} /> red inputs need initialization</div>
    </div>
  );
}

function ScaleControls({
  scales,
  collapsedScales,
  onToggle,
  onExpandAll,
}: {
  scales: string[];
  collapsedScales: Set<string>;
  onToggle: (scale: string) => void;
  onExpandAll: () => void;
}) {
  return (
    <div className="scale-controls">
      <div className="legend-title"><Network size={13} /> Scales</div>
      <div className="scale-list">
        {scales.map((scale) => {
          const collapsed = collapsedScales.has(scale);
          return (
            <button key={scale} className={collapsed ? "collapsed" : "active"} onClick={() => onToggle(scale)}>
              <span>{scale}</span>
              <small>{collapsed ? "collapsed" : "visible"}</small>
            </button>
          );
        })}
      </div>
      {collapsedScales.size > 0 && <button className="scale-reset" onClick={onExpandAll}>Show all scales</button>}
    </div>
  );
}

function FloatingPanel({ className, title, subtitle, onClose, children }: { className: string; title: string; subtitle: string; onClose: () => void; children: ReactNode }) {
  return (
    <div className={`floating-panel ${className}`}>
      <div className="floating-panel-header">
        <div>
          <div className="eyebrow">{title}</div>
          <h2>{subtitle}</h2>
        </div>
        <button className="icon-button compact" onClick={onClose} title={`Close ${title}`}>
          <X size={14} />
        </button>
      </div>
      {children}
    </div>
  );
}

function RequiredInputList({ groups, onSelect, compact = false }: { groups: Map<string, RequiredInput[]>; onSelect: (node: GraphNodeData, port?: GraphPort | null) => void; compact?: boolean }) {
  if (groups.size === 0) return <div className="empty-state">Every input is computed by another model.</div>;
  return (
    <div className={`initialization-list ${compact ? "compact" : ""}`}>
      {[...groups.entries()].map(([group, items]) => (
        <section className="initialization-group" key={group}>
          <h4>{group}</h4>
          {items.map(({ node, port, reason }) => (
            <button className={`initialization-item ${reason}`} key={port.id} onClick={() => onSelect(node, port)}>
              <span>{node.scale}.{node.process}</span>
              <strong>{port.name}</strong>
              <small>{requiredReasonLabel(reason)}</small>
            </button>
          ))}
        </section>
      ))}
    </div>
  );
}

function WarningList({
  warnings,
  onFocusWarning,
}: {
  warnings: ValidationWarning[];
  onFocusWarning: (warning: ValidationWarning) => void;
}) {
  if (warnings.length === 0) return <div className="empty-state">No validation warnings.</div>;
  const grouped = groupValidationWarnings(warnings);
  return (
    <div className="warning-list">
      {(["error", "warning", "info"] as const).map((severity) => {
        const items = grouped.get(severity) ?? [];
        if (items.length === 0) return null;
        return (
          <section className="warning-group" key={severity}>
            <h4>{validationSeverityLabel(severity)} ({items.length})</h4>
            {items.map((warning) => (
              <button
                key={warning.id}
                className={`warning-item ${warning.severity} ${warning.category}`}
                onClick={() => onFocusWarning(warning)}
              >
                <strong>{warning.title}</strong>
                <span>{warning.detail}</span>
              </button>
            ))}
          </section>
        );
      })}
    </div>
  );
}

function InspectorDetails({
  selected,
  selectedEdge,
  activePort,
  requiredInputPortIds,
  incomingEdges,
  outgoingEdges,
  nodeById,
  portById,
  onFocusEdge,
}: {
  selected: GraphNodeData | null;
  selectedEdge: GraphEdgeData | null;
  activePort: GraphPort | null;
  requiredInputPortIds: Set<string>;
  incomingEdges: GraphEdgeData[];
  outgoingEdges: GraphEdgeData[];
  nodeById: Map<string, GraphNodeData>;
  portById: Map<string, { node: GraphNodeData; port: GraphPort }>;
  onFocusEdge: (edge: GraphEdgeData) => void;
}) {
  return (
    <>
      {selectedEdge && (
        <EdgeDetails edge={selectedEdge} nodeById={nodeById} portById={portById} />
      )}
      {selected ? (
        <div className="details">
          <Row label="Process" value={selected.process} />
          <Row label="Model" value={selected.modelType} />
          <Row label="Scale" value={selected.scale} />
          <Row label="Rate" value={selected.rate} />
          <Row label="Inputs" value={selected.inputs.map((port) => port.name).join(", ") || "none"} />
          <Row label="Outputs" value={selected.outputs.map((port) => port.name).join(", ") || "none"} />
          {selected.inputs.filter((port) => requiredInputPortIds.has(port.id)).map((port) => (
            <div className="initialization-note" key={port.id}><CircleAlert size={14} /> {port.name} must be initialized</div>
          ))}
          {selected.inputs.filter((port) => port.previousTimeStep).map((port) => (
            <div className="edit-suggestion" key={port.id}><ScissorsLineDashed size={14} /> {port.name} uses previous timestep</div>
          ))}
        </div>
      ) : !selectedEdge ? (
        <div className="empty-state">Select a model node.</div>
      ) : null}

      <h3>Variable Provenance</h3>
      {activePort ? (
        <div className="variable-card">
          <div className="variable-card-title">
            <span>{activePort.name}</span>
            <small>{activePort.role}</small>
          </div>
          <Row label={activePort.role === "input" ? "Default" : "Decl."} value={activePort.default} />
          {activePort.mappingMode && <Row label="Mapping" value={activePort.mappingMode} />}
          {activePort.sourceScale && <Row label="Source" value={`${activePort.sourceScale}.${activePort.sourceVariable ?? activePort.name}`} />}
          {requiredInputPortIds.has(activePort.id) && <div className="initialization-note"><CircleAlert size={14} /> required initialization</div>}
          {activePort.previousTimeStep && <div className="edit-suggestion"><ScissorsLineDashed size={14} /> uses previous timestep</div>}
          <EdgeList title="Produced by" edges={incomingEdges} direction="incoming" nodeById={nodeById} portById={portById} onFocusEdge={onFocusEdge} />
          <EdgeList title="Consumed by" edges={outgoingEdges} direction="outgoing" nodeById={nodeById} portById={portById} onFocusEdge={onFocusEdge} />
        </div>
      ) : (
        <div className="empty-state">Hover, click, or search a variable to see where it comes from and where it goes.</div>
      )}
    </>
  );
}

function EdgeDetails({
  edge,
  nodeById,
  portById,
}: {
  edge: GraphEdgeData;
  nodeById: Map<string, GraphNodeData>;
  portById: Map<string, { node: GraphNodeData; port: GraphPort }>;
}) {
  const source = nodeById.get(edge.source);
  const target = nodeById.get(edge.target);
  const sourcePort = edge.sourcePort ? portById.get(edge.sourcePort)?.port : null;
  const targetPort = edge.targetPort ? portById.get(edge.targetPort)?.port : null;
  return (
    <div className="edge-detail-card">
      <div className="variable-card-title">
        <span>{edgeKindLabel(edge)}</span>
        <small>{edge.scaleRelation}</small>
      </div>
      <Row label="Source" value={source ? `${source.scale}.${source.process}` : edge.source} />
      <Row label="Source var" value={sourcePort?.name ?? edge.sourceVariable ?? "model call"} />
      <Row label="Target" value={target ? `${target.scale}.${target.process}` : edge.target} />
      <Row label="Target var" value={targetPort?.name ?? edge.targetVariable ?? "model call"} />
      <Row label="Kind" value={edge.kind} />
      <Row label="Label" value={edge.label || "none"} />
      {edge.diagnostics.length > 0 ? edge.diagnostics.map((item) => (
        <div className="diagnostic" key={item}>{item}</div>
      )) : <div className="empty-state compact">No edge diagnostics.</div>}
    </div>
  );
}

function EdgeList({
  title,
  edges,
  direction,
  nodeById,
  portById,
  onFocusEdge,
}: {
  title: string;
  edges: GraphEdgeData[];
  direction: "incoming" | "outgoing";
  nodeById: Map<string, GraphNodeData>;
  portById: Map<string, { node: GraphNodeData; port: GraphPort }>;
  onFocusEdge: (edge: GraphEdgeData) => void;
}) {
  return (
    <div className="provenance-block">
      <h4>{title}</h4>
      {edges.length > 0 ? edges.map((edge) => {
        const source = nodeById.get(edge.source);
        const target = nodeById.get(edge.target);
        const sourcePort = edge.sourcePort ? portById.get(edge.sourcePort)?.port : null;
        const targetPort = edge.targetPort ? portById.get(edge.targetPort)?.port : null;
        const main = direction === "incoming"
          ? `${source?.scale ?? "?"}.${source?.process ?? "?"}.${sourcePort?.name ?? edge.sourceVariable ?? "model"}`
          : `${target?.scale ?? "?"}.${target?.process ?? "?"}.${targetPort?.name ?? edge.targetVariable ?? "model"}`;
        return (
          <button className={`provenance-edge ${edge.kind}`} key={edge.id} onClick={() => onFocusEdge(edge)}>
            <strong>{main}</strong>
            <span>{edgeKindLabel(edge)}{edge.scaleRelation === "multiscale" ? " across scales" : ""}</span>
            {edge.diagnostics.length > 0 && <small>{edge.diagnostics[0]}</small>}
          </button>
        );
      }) : <div className="empty-state compact">No {title.toLowerCase()} edge.</div>}
    </div>
  );
}

function Row({ label, value }: { label: string; value: string }) {
  return <div className="row"><span>{label}</span><strong>{value}</strong></div>;
}

function MappingCodePanel({
  code,
  savePath,
  lastSavedPath,
  onSavePathChange,
  onSave,
}: {
  code: string;
  savePath: string;
  lastSavedPath: string | null;
  onSavePathChange: (path: string) => void;
  onSave: () => void;
}) {
  const copyCode = useCallback(async () => {
    if (!code) return;
    await navigator.clipboard.writeText(code);
  }, [code]);

  return (
    <div className="mapping-code-panel">
      <div className="row-with-actions">
        <strong>Current Julia mapping</strong>
        <button className="metric-button" onClick={() => { void copyCode(); }}>Copy</button>
      </div>
      <textarea className="mapping-code" readOnly value={code} />
      <label className="model-browser-control">
        <span>Write to file</span>
        <input value={savePath} onChange={(event) => onSavePathChange(event.target.value)} placeholder="mapping.generated.jl" />
      </label>
      <button className="metric-button" onClick={onSave}>Save mapping code</button>
      {lastSavedPath ? <div className="diagnostic">Saved to {lastSavedPath}</div> : <div className="empty-state compact">No mapping code saved yet.</div>}
    </div>
  );
}

function ModelBrowser({
  models,
  scales,
  onAddScale,
  onCommand,
  disabled,
}: {
  models: ModelDescriptor[];
  scales: string[];
  onAddScale: (scale: string) => void;
  onCommand: (command: Record<string, unknown>) => void;
  disabled: boolean;
}) {
  const [modelType, setModelType] = useState(models[0]?.type ?? "");
  const [scale, setScale] = useState(scales[0] ?? "Default");
  const [newScale, setNewScale] = useState("");
  const selected = models.find((model) => model.type === modelType) ?? models[0];

  useEffect(() => {
    if (!models.some((model) => model.type === modelType)) setModelType(models[0]?.type ?? "");
  }, [modelType, models]);

  useEffect(() => {
    if (!scales.includes(scale)) setScale(scales[0] ?? "Default");
  }, [scale, scales]);

  if (!selected) return <div className="empty-state">No model type is available.</div>;
  return (
    <div className="model-browser">
      <label className="model-browser-control">
        <span>Define scale</span>
        <div className="inline-field">
          <input value={newScale} onChange={(event) => setNewScale(event.target.value)} placeholder="Leaf, Plant, Scene" />
          <button
            className="metric-button"
            onClick={() => {
              onAddScale(newScale);
              if (newScale.trim()) setScale(newScale.trim());
              setNewScale("");
            }}
          >
            Add scale
          </button>
        </div>
      </label>
      <label className="model-browser-control">
        <span>Scale</span>
        <select value={scale} onChange={(event) => setScale(event.target.value)}>
          {scales.map((item) => <option key={item} value={item}>{item}</option>)}
        </select>
      </label>
      <label className="model-browser-control">
        <span>Model</span>
        <select value={selected.type} onChange={(event) => setModelType(event.target.value)}>
          {models.map((model) => <option key={model.type} value={model.type}>{model.name} ({model.process ?? "unknown"})</option>)}
        </select>
      </label>
      <ModelParameterForm key={selected.type} model={selected} scale={scale} disabled={disabled} onCommand={onCommand} />
    </div>
  );
}

function ModelParameterForm({
  model,
  scale,
  disabled,
  onCommand,
}: {
  model: ModelDescriptor;
  scale: string;
  disabled: boolean;
  onCommand: (command: Record<string, unknown>) => void;
}) {
  const initialValues = useMemo(() => Object.fromEntries(model.constructor.fields.map((field) => [field.name, parameterDefaultValue(field.default)])), [model]);
  const initialTypes = useMemo(() => Object.fromEntries(model.constructor.fields.map((field) => [field.name, field.inferredChoice])), [model]);
  const [values, setValues] = useState<Record<string, string>>(initialValues);
  const [types, setTypes] = useState<Record<string, string>>(initialTypes);
  const [rateMode, setRateMode] = useState<"default" | "clock">("default");
  const [rateDt, setRateDt] = useState("1.0");
  const [ratePhase, setRatePhase] = useState("0.0");

  const setSharedType = useCallback((fieldName: string, nextType: string) => {
    const field = model.constructor.fields.find((item) => item.name === fieldName);
    const group = field?.typeParameter ? model.constructor.parameterGroups[field.typeParameter] ?? [fieldName] : [fieldName];
    setTypes((current) => ({ ...current, ...Object.fromEntries(group.map((name) => [name, nextType])) }));
  }, [model]);

  const addModel = useCallback(() => {
    const parameters = Object.fromEntries(model.constructor.fields.map((field) => [
      field.name,
      { type: types[field.name] ?? field.inferredChoice, value: values[field.name] ?? "" },
    ]));
    const timestep = rateMode === "clock" ? { mode: "clock", dt: rateDt, phase: ratePhase } : { mode: "default" };
    onCommand({ action: "edit", kind: "add_model", scale, modelType: model.type, parameters, timestep });
  }, [model, onCommand, rateDt, rateMode, ratePhase, scale, types, values]);

  return (
      <div className="model-browser-item">
      <strong>{model.name}</strong>
      <span>{model.process ?? "unknown process"}</span>
      <div className="rate-editor">
        <label className="model-browser-control">
          <span>Rate</span>
          <select value={rateMode} onChange={(event) => setRateMode(event.target.value as "default" | "clock")}>
            <option value="default">Default rate</option>
            <option value="clock">Custom ClockSpec</option>
          </select>
        </label>
        {rateMode === "default" ? (
          <div className="rate-summary">Uses model default: {model.timespec ?? "default rate"}</div>
        ) : (
          <div className="rate-clock-row">
            <label>
              <span>dt</span>
              <input value={rateDt} onChange={(event) => setRateDt(event.target.value)} inputMode="decimal" />
            </label>
            <label>
              <span>phase</span>
              <input value={ratePhase} onChange={(event) => setRatePhase(event.target.value)} inputMode="decimal" />
            </label>
          </div>
        )}
      </div>
      {model.constructor.fields.map((field) => (
        <div className="parameter-row" key={field.name}>
          <label>{field.name}</label>
          <input value={values[field.name] ?? ""} onChange={(event) => setValues((current) => ({ ...current, [field.name]: event.target.value }))} />
          <select value={types[field.name] ?? field.inferredChoice} onChange={(event) => setSharedType(field.name, event.target.value)}>
            {field.choices.map((choice) => <option key={choice} value={choice}>{choice}</option>)}
          </select>
        </div>
      ))}
      <button className="metric-button" disabled={disabled} onClick={addModel}>Add model</button>
    </div>
  );
}

function parameterDefaultValue(value: unknown) {
  if (value === null || typeof value === "undefined") return "";
  if (typeof value === "string" && value.startsWith(":")) return value.slice(1);
  return String(value);
}

function loadInitialGraph() {
  const embedded = document.getElementById("pse-graph-data");
  if (embedded?.textContent) return JSON.parse(embedded.textContent) as DependencyGraphView;
  const fromWindow = (window as Window & { PlantSimEngineGraph?: DependencyGraphView }).PlantSimEngineGraph;
  return fromWindow ?? sampleGraph;
}

function loadEditorConfig() {
  const embedded = document.getElementById("pse-editor-config");
  if (!embedded?.textContent) return null;
  return JSON.parse(embedded.textContent) as { websocketUrl?: string };
}

function runtimeNodeData(
  node: GraphNodeData,
  options: {
    activePort: GraphPort | null;
    highlightedPortIds: Set<string>;
    focusedPortIds: Set<string>;
    requiredInputPortIds: Set<string>;
    cycleNodeIds: Set<string>;
    focusedNodeIds: Set<string>;
    hasActiveFocus: boolean;
    setActivePort: (port: GraphPort | null) => void;
  },
): RuntimeGraphNodeData {
  return {
    ...node,
    cyclic: options.cycleNodeIds.has(node.id),
    activePortId: options.activePort?.id ?? null,
    highlightedPortIds: [...options.highlightedPortIds],
    focusedPortIds: [...options.focusedPortIds],
    requiredInputPortIds: [...options.requiredInputPortIds],
    focused: options.focusedNodeIds.has(node.id),
    dimmed: options.hasActiveFocus && !options.focusedNodeIds.has(node.id),
    onPortEnter: options.setActivePort,
    onPortLeave: () => options.setActivePort(null),
  };
}

function deriveRequiredInputPorts(graph: DependencyGraphView) {
  const computedInputPortIds = new Set(graph.edges.map((edge) => edge.targetPort).filter(isString));
  const required = new Set<string>();
  const requiredKeys = new Set<string>();

  for (const node of graph.nodes) {
    for (const port of node.inputs) {
      if (computedInputPortIds.has(port.id)) continue;
      const canonical = canonicalInitializationPort(graph, node, port, computedInputPortIds);
      if (!canonical) continue;
      const key = initializationKey(canonical.node, canonical.port);
      if (requiredKeys.has(key)) continue;
      requiredKeys.add(key);
      required.add(canonical.port.id);
    }
  }

  return required;
}

function deriveRequiredInputs(graph: DependencyGraphView, requiredInputPortIds: Set<string>, incomingByPort: Map<string, GraphEdgeData[]>) {
  return graph.nodes.flatMap((node) => (
    node.inputs
      .filter((port) => requiredInputPortIds.has(port.id))
      .map((port): RequiredInput => ({
        node,
        port,
        reason: requiredReason(port, incomingByPort.get(port.id) ?? []),
      }))
  ));
}

function requiredReason(port: GraphPort, incomingEdges: GraphEdgeData[]): RequiredInput["reason"] {
  if (port.previousTimeStep) return "previous_time_step";
  if (port.mappingMode && incomingEdges.length === 0) return "mapped_unresolved";
  return "user_initialization";
}

function canonicalInitializationPort(
  graph: DependencyGraphView,
  node: GraphNodeData,
  port: GraphPort,
  computedInputPortIds: Set<string>,
  visited = new Set<string>(),
): { node: GraphNodeData; port: GraphPort } | null {
  if (visited.has(port.id)) return { node, port };
  visited.add(port.id);

  if (!port.sourceScale) return { node, port };

  const sourceVariable = port.sourceVariable ?? port.name;
  const sourceInput = findInputPort(graph, port.sourceScale, sourceVariable);
  if (sourceInput) {
    if (computedInputPortIds.has(sourceInput.port.id)) return null;
    return canonicalInitializationPort(graph, sourceInput.node, sourceInput.port, computedInputPortIds, visited);
  }

  const sourceOutput = findOutputPort(graph, port.sourceScale, sourceVariable);
  if (sourceOutput) return null;

  return { node, port };
}

function findInputPort(graph: DependencyGraphView, scale: string, variable: string) {
  let fallback: { node: GraphNodeData; port: GraphPort } | null = null;
  for (const node of graph.nodes) {
    if (node.scale !== scale) continue;
    const port = node.inputs.find((candidate) => candidate.name === variable);
    if (!port) continue;
    if (!fallback) fallback = { node, port };
    if (!port.sourceScale) return { node, port };
  }
  return fallback;
}

function findOutputPort(graph: DependencyGraphView, scale: string, variable: string) {
  for (const node of graph.nodes) {
    if (node.scale !== scale) continue;
    const port = node.outputs.find((candidate) => candidate.name === variable);
    if (port) return { node, port };
  }
  return null;
}

function initializationKey(node: GraphNodeData, port: GraphPort) {
  return `${node.scale}:${port.name}`;
}

function groupRequiredInputs(requiredInputs: RequiredInput[]) {
  const grouped = new Map<string, RequiredInput[]>();
  for (const item of requiredInputs) {
    const key = `${item.node.scale}.${item.node.process}`;
    const group = grouped.get(key) ?? [];
    group.push(item);
    grouped.set(key, group);
  }
  return grouped;
}

function requiredReasonLabel(reason: RequiredInput["reason"]) {
  if (reason === "previous_time_step") return "previous step";
  if (reason === "mapped_unresolved") return "unresolved mapping";
  return "user init";
}

function flowEdge(
  edge: GraphEdgeData,
  highlightedEdgeIds: Set<string>,
  focusedEdgeIds: Set<string>,
  hasActivePort: boolean,
  hasActiveFocus: boolean,
): Edge<GraphEdgeData> {
  const highlighted = highlightedEdgeIds.has(edge.id);
  const focused = focusedEdgeIds.has(edge.id);
  const callEdge = isCallEdge(edge);
  const dimmed = (hasActivePort && !highlighted) || (hasActiveFocus && !focused && !highlighted);

  return {
    id: edge.id,
    source: edge.source,
    target: edge.target,
    sourceHandle: edge.sourcePort ?? (callEdge ? `${edge.source}:call-source` : undefined),
    targetHandle: edge.targetPort ?? (callEdge ? `${edge.target}:call-target` : undefined),
    markerEnd: callEdge ? undefined : edgeMarker(edgeColor(edge, highlighted || focused)),
    type: "dependency",
    animated: !callEdge && edge.scaleRelation === "multiscale",
    className: `${edge.kind} ${callEdge ? "call_edge" : "variable_edge"} ${edge.scaleRelation} ${focused ? "focused" : ""} ${highlighted ? "highlighted" : dimmed ? "dimmed" : ""}`,
    style: edgeStyle(edgeColor(edge, highlighted || focused), highlighted || focused),
    selected: highlighted || focused,
    zIndex: highlighted ? 120 : focused ? 90 : callEdge ? 3 : 5,
    data: { ...edge, highlighted, focused, dimmed },
  };
}

function edgeColor(edge: GraphEdgeData, highlighted: boolean) {
  if (highlighted) return edgeColors.accent;
  if (edge.kind === "hard_dependency") return edgeColors.hard;
  if (edge.kind === "mapped_variable" || edge.scaleRelation === "multiscale") return edgeColors.mapped;
  return edgeColors.base;
}

function edgeMarker(color: string) {
  return {
    type: MarkerType.ArrowClosed,
    color,
    width: 9,
    height: 9,
    markerUnits: "userSpaceOnUse",
    strokeWidth: 1.2,
  };
}

function edgeStyle(color: string, highlighted: boolean) {
  return {
    stroke: color,
    strokeWidth: highlighted ? 3 : 2.2,
  };
}

function deriveHighlight(graph: DependencyGraphView, activePort: GraphPort | null) {
  const result = emptyFocusState();
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

function deriveFocus(graph: DependencyGraphView, selectedNodeId: string | null, activePort: GraphPort | null, mode: FocusMode): FocusState {
  const result = emptyFocusState();
  if (mode === "none") return result;

  const seeds = new Set<string>();
  if (activePort) seeds.add(activePort.id);
  if (selectedNodeId) {
    const node = graph.nodes.find((item) => item.id === selectedNodeId);
    node?.inputs.forEach((port) => seeds.add(port.id));
    node?.outputs.forEach((port) => seeds.add(port.id));
    result.nodes.add(selectedNodeId);
  }
  if (seeds.size === 0) return result;

  result.active = true;
  const visited = new Set(seeds);
  const queue = [...seeds];
  seeds.forEach((seed) => result.ports.add(seed));

  while (queue.length > 0) {
    const portId = queue.shift()!;
    for (const edge of graph.edges) {
      if (!edge.sourcePort || !edge.targetPort) continue;
      const upstream = mode === "upstream" || mode === "neighborhood";
      const downstream = mode === "downstream" || mode === "neighborhood";
      const nextPort = downstream && edge.sourcePort === portId
        ? edge.targetPort
        : upstream && edge.targetPort === portId
          ? edge.sourcePort
          : null;
      if (!nextPort) continue;

      result.edges.add(edge.id);
      result.nodes.add(edge.source);
      result.nodes.add(edge.target);
      result.ports.add(edge.sourcePort);
      result.ports.add(edge.targetPort);
      if (!visited.has(nextPort)) {
        visited.add(nextPort);
        queue.push(nextPort);
      }
    }
  }

  for (const edge of graph.edges) {
    if (!isCallEdge(edge)) continue;
    if (result.nodes.has(edge.source) || result.nodes.has(edge.target)) {
      result.edges.add(edge.id);
      result.nodes.add(edge.source);
      result.nodes.add(edge.target);
    }
  }

  return result;
}

function deriveSearchResults(graph: DependencyGraphView, query: string): SearchResult[] {
  const normalized = query.trim().toLowerCase();
  if (!normalized) return [];

  const results: SearchResult[] = [];
  for (const node of graph.nodes) {
    const nodeHaystack = `${node.scale} ${node.process} ${node.modelType} ${node.rate}`.toLowerCase();
    if (nodeHaystack.includes(normalized)) {
      results.push({
        id: `model:${node.id}`,
        kind: "model",
        node,
        label: `${node.scale}.${node.process}`,
        detail: node.modelType,
      });
    }
    for (const port of [...node.inputs, ...node.outputs]) {
      const portHaystack = `${node.scale} ${node.process} ${node.modelType} ${port.name} ${port.role}`.toLowerCase();
      if (portHaystack.includes(normalized)) {
        results.push({
          id: `port:${port.id}`,
          kind: port.role,
          node,
          port,
          label: `${port.name}`,
          detail: `${port.role} in ${node.scale}.${node.process}`,
        });
      }
    }
  }

  return results.slice(0, 18);
}

function deriveValidationWarnings(graph: DependencyGraphView, requiredInputPortIds: Set<string>, incomingByPort: Map<string, GraphEdgeData[]>): ValidationWarning[] {
  const warnings: ValidationWarning[] = [];
  const outputs = new Map<string, Array<{ node: GraphNodeData; port: GraphPort }>>();
  const nodeById = new Map(graph.nodes.map((node) => [node.id, node]));

  for (const node of graph.nodes) {
    for (const port of node.outputs) {
      if (!isOwnOutput(node, port)) continue;
      const key = `${node.scale}:${port.name}`;
      const group = outputs.get(key) ?? [];
      group.push({ node, port });
      outputs.set(key, group);
    }
    for (const port of node.inputs) {
      const incoming = incomingByPort.get(port.id) ?? [];
      if (requiredInputPortIds.has(port.id) && incoming.length > 0) {
        warnings.push({
          id: `required-with-edge:${port.id}`,
          severity: "error",
          category: "init",
          title: "Input marked init but connected",
          detail: `${node.scale}.${node.process}.${port.name} has incoming data-flow edges and should not be required.`,
          nodeId: node.id,
          portId: port.id,
        });
      }
      if (port.mappingMode && requiredInputPortIds.has(port.id) && !port.previousTimeStep) {
        warnings.push({
          id: `unresolved-mapping:${port.id}`,
          severity: "warning",
          category: "mapping",
          title: "Mapped input has no producer",
          detail: `${node.scale}.${node.process}.${port.name} declares mapping metadata but no source output was found.`,
          nodeId: node.id,
          portId: port.id,
        });
      }
    }
  }

  for (const [key, group] of outputs) {
    if (group.length <= 1) continue;
    const [scale, variable] = key.split(":");
    const producerLabels = group.map(({ node }) => `${node.scale}.${node.process}`).join(", ");
    warnings.push({
      id: `multiple-producers:${key}`,
      severity: "warning",
      category: "ownership",
      title: "Multiple producers",
      detail: `${scale}.${variable} is output by ${group.length} models at the same scale: ${producerLabels}.`,
      nodeId: group[0].node.id,
      nodeIds: group.map(({ node }) => node.id),
      portId: group[0].port.id,
      portIds: group.map(({ port }) => port.id),
    });
  }

  for (const edge of graph.edges) {
    if (edge.diagnostics.some((item) => item.includes("Forwarded to a hard dependency"))) {
      warnings.push({
        id: `hard-forward:${edge.id}`,
        severity: "info",
        category: "hard_dependency",
        title: "Hard input forwarding",
        detail: `${edge.targetVariable ?? "input"} is satisfied through the owning model status before a hard dependency call. This is expected for declared hard dependencies.`,
        edgeId: edge.id,
      });
    }
    const sourceNode = nodeById.get(edge.source);
    const targetNode = nodeById.get(edge.target);
    const crossesScale = Boolean(sourceNode && targetNode && sourceNode.scale !== targetNode.scale);
    if (
      crossesScale &&
      edge.kind !== "mapped_variable" &&
      !isCallEdge(edge) &&
      !hasSameScaleProducerForTarget(edge, targetNode, nodeById, incomingByPort)
    ) {
      warnings.push({
        id: `implicit-cross-scale:${edge.id}`,
        severity: "info",
        category: "cross_scale",
        title: "Inferred cross-scale edge",
        detail: `${sourceNode?.scale}.${sourceNode?.process}.${edge.sourceVariable ?? "source"} -> ${targetNode?.scale}.${targetNode?.process}.${edge.targetVariable ?? "target"} crosses scales through graph inference rather than a direct mapped-variable edge.`,
        edgeId: edge.id,
      });
    }
  }

  return warnings;
}

function hasSameScaleProducerForTarget(
  edge: GraphEdgeData,
  targetNode: GraphNodeData | undefined,
  nodeById: Map<string, GraphNodeData>,
  incomingByPort: Map<string, GraphEdgeData[]>,
) {
  if (!targetNode || !edge.targetPort) return false;
  const incoming = incomingByPort.get(edge.targetPort) ?? [];
  return incoming.some((candidate) => {
    if (candidate.id === edge.id || !candidate.sourcePort || !candidate.targetPort) return false;
    const candidateSource = nodeById.get(candidate.source);
    return candidateSource?.scale === targetNode.scale;
  });
}

function isOwnOutput(node: GraphNodeData, port: GraphPort) {
  return !node.ownOutputIds || node.ownOutputIds.includes(port.id);
}

function groupValidationWarnings(warnings: ValidationWarning[]) {
  const grouped = new Map<ValidationWarning["severity"], ValidationWarning[]>();
  for (const warning of warnings) {
    const group = grouped.get(warning.severity) ?? [];
    group.push(warning);
    grouped.set(warning.severity, group);
  }
  return grouped;
}

function validationSeverityLabel(severity: ValidationWarning["severity"]) {
  if (severity === "error") return "Likely bugs";
  if (severity === "warning") return "Review";
  return "Information";
}

function mergeFocusStates(primary: FocusState, secondary: FocusState | null): FocusState {
  if (!secondary?.active) return primary;
  return {
    active: primary.active || secondary.active,
    edges: new Set([...primary.edges, ...secondary.edges]),
    nodes: new Set([...primary.nodes, ...secondary.nodes]),
    ports: new Set([...primary.ports, ...secondary.ports]),
  };
}

function buildPortIndex(graph: DependencyGraphView) {
  const index = new Map<string, { node: GraphNodeData; port: GraphPort }>();
  for (const node of graph.nodes) {
    for (const port of [...node.inputs, ...node.outputs]) index.set(port.id, { node, port });
  }
  return index;
}

function groupEdgesByPort(edges: GraphEdgeData[], side: "sourcePort" | "targetPort") {
  const groups = new Map<string, GraphEdgeData[]>();
  for (const edge of edges) {
    const portId = edge[side];
    if (!portId) continue;
    const group = groups.get(portId) ?? [];
    group.push(edge);
    groups.set(portId, group);
  }
  return groups;
}

function edgeMatchesFilters(edge: GraphEdgeData, filters: EdgeFilters) {
  if (isCallEdge(edge)) return filters.callStack;
  if (edge.kind === "mapped_variable" || edge.scaleRelation === "multiscale") return filters.mapped;
  return filters.dataFlow;
}

function edgeKindLabel(edge: GraphEdgeData) {
  if (isCallEdge(edge)) return "call stack";
  if (edge.kind === "mapped_variable") return "mapped variable";
  if (edge.diagnostics.some((item) => item.includes("Forwarded to a hard dependency"))) return "hard input forwarding";
  if (edge.diagnostics.some((item) => item.includes("Computed by a hard dependency"))) return "hard output";
  return "soft dependency";
}

function isCallEdge(edge: GraphEdgeData) {
  return edge.kind === "hard_dependency" && !edge.sourcePort && !edge.targetPort;
}

function emptyFocusState(): FocusState {
  return {
    active: false,
    edges: new Set<string>(),
    nodes: new Set<string>(),
    ports: new Set<string>(),
  };
}

function isString(value: unknown): value is string {
  return typeof value === "string";
}

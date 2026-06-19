import { useCallback, useEffect, useMemo, useState } from "react";
import {
  Background,
  Controls,
  MarkerType,
  MiniMap,
  ReactFlow,
  useEdgesState,
  useNodesState,
  type Connection,
  type Edge,
  type Node,
} from "@xyflow/react";
import "@xyflow/react/dist/style.css";
import {
  AlertTriangle,
  Boxes,
  CircleAlert,
  Code2,
  GitBranch,
  FolderOpen,
  Layers3,
  Network,
  Plus,
  Scissors,
  Search,
  Save,
  Undo2,
  Redo2,
  X,
} from "lucide-react";
import { ApplicationForm, type ApplicationFormValue } from "./ApplicationForm";
import { BindingForm, type BindingEndpoints, type BindingFormValue } from "./BindingForm";
import { ObjectForm, type ObjectFormValue } from "./ObjectForm";
import { OverrideForm, type OverrideFormValue } from "./OverrideForm";
import { ApplicationNode, EntityNode } from "./ModelNode";
import { DependencyEdge } from "./DependencyEdge";
import { layoutGraph, type LayoutMode } from "./layout";
import { sampleGraph } from "./sampleGraph";
import type {
  ApplicationGraphNode,
  DetailMode,
  EditorState,
  ExecutionGraphNode,
  GraphPort,
  GraphViewMode,
  ModelDescriptor,
  ObjectGraphNode,
  RuntimeApplicationNode,
  RuntimeEntityNode,
  SceneGraphEdge,
  SceneGraphView,
} from "./types";
import "./styles.css";

type FlowNode = Node<RuntimeApplicationNode | RuntimeEntityNode>;
type FlowEdge = Edge<SceneGraphEdge>;
type CandidatePopover = { port: GraphPort; application: ApplicationGraphNode; x: number; y: number };
type CycleBreakSelection = { application: ApplicationGraphNode; port: GraphPort };
type InspectorSelection = ApplicationGraphNode | ObjectGraphNode | ExecutionGraphNode | SceneGraphEdge | null;
type ApplicationFormState = {
  mode: "add" | "update";
  scope?: "application" | "template";
  instance?: string;
  application?: ApplicationGraphNode;
  initialModelType?: string;
  suggestedSelector?: ApplicationGraphNode["selector"];
};
type ObjectFormState = { mode: "add" | "update"; object?: ObjectGraphNode };

const nodeTypes = { application: ApplicationNode, entity: EntityNode };
const edgeTypes = { sceneEdge: DependencyEdge };

export default function App() {
  const [graph, setGraph] = useState<SceneGraphView>(loadInitialGraph);
  const [view, setView] = useState<GraphViewMode>(() => loadInitialGraph().level);
  const [detailMode, setDetailMode] = useState<DetailMode>(() => loadInitialGraph().metadata.applicationCount > 24 ? "overview" : "detail");
  const [query, setQuery] = useState("");
  const [selected, setSelected] = useState<InspectorSelection>(null);
  const [selectedPort, setSelectedPort] = useState<GraphPort | null>(null);
  const [candidate, setCandidate] = useState<CandidatePopover | null>(null);
  const [showDiagnostics, setShowDiagnostics] = useState(false);
  const [showInitialization, setShowInitialization] = useState(false);
  const [showSceneCode, setShowSceneCode] = useState(false);
  const [showOpen, setShowOpen] = useState(false);
  const [showSave, setShowSave] = useState(false);
  const [sceneCode, setSceneCode] = useState("");
  const [autosavePath, setAutosavePath] = useState<string | null>(null);
  const [savePath, setSavePath] = useState<string | null>(null);
  const [recentPaths, setRecentPaths] = useState<string[]>([]);
  const [socket, setSocket] = useState<WebSocket | null>(null);
  const [connected, setConnected] = useState(false);
  const [canUndo, setCanUndo] = useState(false);
  const [canRedo, setCanRedo] = useState(false);
  const [feedback, setFeedback] = useState<string | null>(null);
  const [applicationForm, setApplicationForm] = useState<ApplicationFormState | null>(null);
  const [objectForm, setObjectForm] = useState<ObjectFormState | null>(null);
  const [overrideApplication, setOverrideApplication] = useState<ApplicationGraphNode | null>(null);
  const [bindingForm, setBindingForm] = useState<BindingEndpoints | null>(null);
  const [cycleBreakMode, setCycleBreakMode] = useState(false);
  const [cycleBreakSelection, setCycleBreakSelection] = useState<CycleBreakSelection | null>(null);
  const [nodes, setNodes, onNodesChange] = useNodesState<FlowNode>([]);
  const [edges, setEdges, onEdgesChange] = useEdgesState<FlowEdge>([]);

  const editorConfig = useMemo(loadEditorConfig, []);
  const applicationById = useMemo(() => new Map(graph.applications.map((application) => [application.applicationId, application])), [graph.applications]);
  const unresolvedPortIds = useMemo(() => new Set(
    graph.initialization
      .filter((row) => row.role === "input" && row.disposition === "unresolved")
      .map((row) => applicationPortId(row.applicationId, "input", row.variable)),
  ), [graph.initialization]);
  const previousPortIds = useMemo(() => new Set(
    graph.initialization
      .filter((row) => row.role === "input" && row.previousTimeStep)
      .map((row) => applicationPortId(row.applicationId, "input", row.variable)),
  ), [graph.initialization]);
  const cyclicApplications = useMemo(() => new Set(graph.cycles.flatMap((cycle) => cycle.applicationIds)), [graph.cycles]);
  const cycleBreakPortIds = useMemo(() => new Set(
    graph.cycles.flatMap((cycle) => cycle.breakCandidates.map((candidate) => applicationPortId(candidate.applicationId, "input", candidate.input))),
  ), [graph.cycles]);
  const candidatePortIds = useMemo(() => deriveCandidatePortIds(graph), [graph]);
  const candidateModels = useMemo(() => candidate ? modelsForPort(graph.modelLibrary, candidate.port) : [], [candidate, graph.modelLibrary]);
  const candidateApplications = useMemo(() => candidate ? applicationsForPort(graph.applications, candidate) : [], [candidate, graph.applications]);
  const portIndex = useMemo(() => {
    const index = new Map<string, { application: ApplicationGraphNode; port: GraphPort }>();
    for (const application of graph.applications) {
      for (const port of [...application.inputs, ...application.outputs]) index.set(port.id, { application, port });
    }
    return index;
  }, [graph.applications]);

  useEffect(() => {
    if (!editorConfig?.websocketUrl) return;
    const nextSocket = new WebSocket(editorConfig.websocketUrl);
    setSocket(nextSocket);
    nextSocket.addEventListener("open", () => { setConnected(true); setFeedback(null); });
    nextSocket.addEventListener("close", () => { setConnected(false); setFeedback("Editor connection closed."); });
    nextSocket.addEventListener("message", (event) => {
      const payload = JSON.parse(event.data) as EditorState;
      if (payload.graph) setGraph(payload.graph);
      if (typeof payload.sceneCode === "string") setSceneCode(payload.sceneCode);
      setAutosavePath(payload.autosavePath ?? null);
      setSavePath(payload.savePath ?? null);
      setRecentPaths(payload.recentPaths ?? []);
      setCanUndo(Boolean(payload.canUndo));
      setCanRedo(Boolean(payload.canRedo));
      setFeedback(payload.ok === false ? payload.diagnostics?.[0] || "The edit failed." : null);
    });
    return () => nextSocket.close();
  }, [editorConfig?.websocketUrl]);

  useEffect(() => {
    if (!graph.metadata.cyclic) {
      setCycleBreakMode(false);
      setCycleBreakSelection(null);
    }
  }, [graph.metadata.cyclic]);

  const sendCommand = useCallback((command: Record<string, unknown>) => {
    if (!socket || socket.readyState !== WebSocket.OPEN) {
      setFeedback("This action requires an interactive Julia editor session.");
      return;
    }
    socket.send(JSON.stringify(command));
  }, [socket]);

  const openCandidates = useCallback((application: ApplicationGraphNode, port: GraphPort, anchor: { x: number; y: number }) => {
    setSelected(application);
    setSelectedPort(port);
    setCandidate({ application, port, x: anchor.x, y: anchor.y });
  }, []);

  useEffect(() => {
    const nextNodes = buildNodes({
      graph,
      view,
      detailMode,
      query,
      unresolvedPortIds,
      previousPortIds,
      candidatePortIds,
      cyclicApplications,
      cycleBreakPortIds,
      cycleBreakMode,
      openCandidates,
      onPortClick: setSelectedPort,
      onCycleBreak: (application, port) => setCycleBreakSelection({ application, port }),
    });
    const nodeIds = new Set(nextNodes.map((node) => node.id));
    const nextEdges = buildEdges(graph, view).filter((edge) => nodeIds.has(edge.source) && nodeIds.has(edge.target));
    const layoutMode: LayoutMode = view === "topology" ? "topology" : detailMode === "overview" ? "overview" : "data_flow";
    layoutGraph(nextNodes, nextEdges, layoutMode).then(setNodes);
    setEdges(nextEdges);
  }, [candidatePortIds, cycleBreakMode, cycleBreakPortIds, cyclicApplications, detailMode, graph, openCandidates, previousPortIds, query, setEdges, setNodes, unresolvedPortIds, view]);

  const inspectSelection = useCallback((_: unknown, node: FlowNode) => {
    if (node.data.nodeKind === "application") {
      setSelected(applicationById.get(node.data.applicationId) ?? null);
    } else {
      setSelected(node.data.detail);
    }
    setSelectedPort(null);
  }, [applicationById]);

  const selectCandidateModel = useCallback((model: ModelDescriptor) => {
    if (!candidate) return;
    setApplicationForm({
      mode: "add",
      initialModelType: model.type,
      suggestedSelector: selectorSuggestion(candidate.application),
    });
    if (!connected) setFeedback(`${model.name} matches ${candidate.port.name}. Start an interactive Julia editor session to add it to the Scene.`);
    setCandidate(null);
  }, [candidate, connected]);

  const submitApplication = useCallback((value: ApplicationFormValue) => {
    if (!connected) {
      setFeedback("Adding or updating an application requires an interactive Julia editor session.");
      setApplicationForm(null);
      return;
    }
    sendCommand({
      action: "edit",
      kind: value.applicationId ? applicationForm?.scope === "template" ? "update_template_application" : "update_application" : "add_application",
      instance: applicationForm?.instance,
      ...value,
    });
    setApplicationForm(null);
  }, [applicationForm?.instance, applicationForm?.scope, connected, sendCommand]);

  const submitBinding = useCallback((value: BindingFormValue) => {
    if (!connected) {
      setFeedback("Creating a binding requires an interactive Julia editor session.");
      setBindingForm(null);
      return;
    }
    sendCommand({ action: "edit", kind: "set_input_binding", ...value });
    setBindingForm(null);
  }, [connected, sendCommand]);

  const submitObject = useCallback((value: ObjectFormValue) => {
    if (!connected) {
      setFeedback("Adding or updating an object requires an interactive Julia editor session.");
      setObjectForm(null);
      return;
    }
    sendCommand({
      action: "edit",
      kind: objectForm?.mode === "update" ? "update_object" : "add_object",
      objectId: value.objectId,
      configuration: value.configuration,
    });
    setObjectForm(null);
  }, [connected, objectForm?.mode, sendCommand]);

  const submitOverride = useCallback((value: OverrideFormValue) => {
    if (!connected) {
      setFeedback("Creating an override requires an interactive Julia editor session.");
      setOverrideApplication(null);
      return;
    }
    sendCommand({
      action: "edit",
      kind: value.scope === "instance" ? "set_instance_override" : "set_object_override",
      ...value,
    });
    setOverrideApplication(null);
  }, [connected, sendCommand]);

  const connectPorts = useCallback((connection: Connection) => {
    if (!connection.sourceHandle || !connection.targetHandle) return;
    const source = portIndex.get(connection.sourceHandle);
    const target = portIndex.get(connection.targetHandle);
    if (!source || !target || source.port.role !== "output" || target.port.role !== "input") {
      setFeedback("Connect an application output to an application input.");
      return;
    }
    setBindingForm({
      sourceApplication: source.application,
      sourcePort: source.port,
      targetApplication: target.application,
      targetPort: target.port,
    });
  }, [portIndex]);

  const activeInitialization = useMemo(() => {
    if (!selected) return graph.initialization;
    if ("applicationId" in selected) return graph.initialization.filter((row) => row.applicationId === selected.applicationId);
    if ("objectId" in selected) return graph.initialization.filter((row) => String(row.objectId) === String(selected.objectId));
    return graph.initialization;
  }, [graph.initialization, selected]);

  return (
    <main className="scene-editor-shell" data-testid="scene-graph-viewer">
      <header className="scene-toolbar">
        <div className="scene-brand">
          <span className="brand-mark" />
          <div><small>PLANTSIMENGINE</small><strong>Scene Graph</strong></div>
        </div>
        <div className="scene-search">
          <Search size={17} />
          <input value={query} onChange={(event) => setQuery(event.target.value)} placeholder="Search application, object, or variable" />
          {query && <button aria-label="Clear search" onClick={() => setQuery("")}><X size={15} /></button>}
        </div>
        <div className="scene-counts">
          <span>{graph.metadata.applicationCount} applications</span>
          <span>{graph.metadata.objectCount} objects</span>
          {graph.metadata.unresolvedInitializationCount > 0 && (
            <button className="count-warning" onClick={() => setShowInitialization(true)}><CircleAlert size={14} /> {graph.metadata.unresolvedInitializationCount} init</button>
          )}
          {graph.diagnostics.length > 0 && (
            <button className="count-error" onClick={() => setShowDiagnostics(true)}><AlertTriangle size={14} /> {graph.diagnostics.length}</button>
          )}
        </div>
        <nav className="view-tabs" aria-label="Graph projection">
          <button className={view === "applications" ? "active" : ""} onClick={() => setView("applications")}><Layers3 size={15} /> Applications</button>
          <button className={view === "topology" ? "active" : ""} onClick={() => setView("topology")}><GitBranch size={15} /> Objects</button>
          <button className={view === "resolved" ? "active" : ""} onClick={() => setView("resolved")}><Network size={15} /> Executions</button>
        </nav>
        <div className="scene-actions">
          {editorConfig && <button data-testid="open-scene" onClick={() => setShowOpen(true)}><FolderOpen size={15} /> Open</button>}
          {editorConfig && <button data-testid="save-scene" onClick={() => setShowSave(true)}><Save size={15} /> {savePath ? "Saved" : "Save"}</button>}
          {view !== "topology" && (
            <button className={detailMode === "overview" ? "overview-cta" : ""} onClick={() => setDetailMode((current) => current === "overview" ? "detail" : "overview")}>
              {detailMode === "overview" ? "Overview Mode - Show Detailed View" : "Show Overview"}
            </button>
          )}
          {editorConfig && <button data-testid="add-application" onClick={() => setApplicationForm({ mode: "add" })}><Plus size={15} /> Add application</button>}
          {editorConfig && <button data-testid="add-object" onClick={() => setObjectForm({ mode: "add" })}><Plus size={15} /> Add object</button>}
          {editorConfig && <button disabled={!canUndo} onClick={() => sendCommand({ action: "undo" })} aria-label="Undo"><Undo2 size={15} /></button>}
          {editorConfig && <button disabled={!canRedo} onClick={() => sendCommand({ action: "redo" })} aria-label="Redo"><Redo2 size={15} /></button>}
          <button onClick={() => setShowSceneCode(true)}><Code2 size={15} /> Scene code</button>
        </div>
      </header>

      {graph.metadata.cyclic && (
        <section className="cycle-callout" data-testid="cycle-callout">
          <AlertTriangle size={19} />
          <div><strong>Current-step dependency cycle</strong><span>Select a cycle input to read its previous accepted timestep value.</span></div>
          <button
            className={cycleBreakMode ? "active" : ""}
            onClick={() => {
              setView("applications");
              setDetailMode("detail");
              setCycleBreakMode((current) => !current);
            }}
            data-testid="choose-cycle-break"
          >
            {cycleBreakMode ? "Cancel break selection" : "Choose a break point in graph"}
          </button>
        </section>
      )}
      {feedback && <div className="editor-feedback">{feedback}<button onClick={() => setFeedback(null)}><X size={14} /></button></div>}

      <section className="scene-workspace">
        <div className="flow-wrap">
          <ReactFlow
            nodes={nodes}
            edges={edges}
            nodeTypes={nodeTypes}
            edgeTypes={edgeTypes}
            onNodesChange={onNodesChange}
            onEdgesChange={onEdgesChange}
            onConnect={connectPorts}
            onNodeClick={inspectSelection}
            onEdgeClick={(_, edge) => setSelected(edge.data ?? null)}
            fitView
            minZoom={0.05}
            maxZoom={2}
          >
            <Background color="#d8cdbc" gap={22} size={1} />
            <Controls />
            <MiniMap pannable zoomable />
          </ReactFlow>
        </div>
        <Inspector
          selection={selected}
          port={selectedPort}
          initialization={activeInitialization}
          interactive={connected}
          onEditApplication={(application) => setApplicationForm({
            mode: "update",
            scope: application.targetInstances.length > 0 ? "template" : "application",
            instance: application.targetInstances[0],
            application,
          })}
          onRemoveApplication={(application) => sendCommand({
            action: "edit",
            kind: application.targetInstances.length > 0 ? "remove_template_application" : "remove_application",
            instance: application.targetInstances[0],
            applicationId: application.applicationId,
          })}
          onOverrideApplication={setOverrideApplication}
          onEditObject={(object) => setObjectForm({ mode: "update", object })}
          onRemoveObject={(object) => sendCommand({ action: "edit", kind: "remove_object", objectId: object.objectId, recursive: true })}
        />
      </section>

      {candidate && (candidateModels.length > 0 || candidateApplications.length > 0) && (
        <CandidatePopover
          candidate={candidate}
          models={candidateModels}
          applications={candidateApplications}
          onSelectModel={selectCandidateModel}
          onSelectApplication={(application) => {
            setBindingForm(endpointsForCandidate(candidate, application));
            setCandidate(null);
          }}
          onClose={() => setCandidate(null)}
        />
      )}
      {showDiagnostics && <DiagnosticsPanel graph={graph} onClose={() => setShowDiagnostics(false)} sendCommand={sendCommand} interactive={connected} />}
      {showInitialization && <InitializationPanel graph={graph} onClose={() => setShowInitialization(false)} sendCommand={sendCommand} interactive={connected} />}
      {showSceneCode && <SceneCodePanel code={sceneCode} onClose={() => setShowSceneCode(false)} />}
      {showOpen && <SceneFileDialog mode="open" recentPaths={recentPaths} currentPath={savePath} autosavePath={autosavePath} onSubmit={(path) => { sendCommand({ action: "open_scene_code", path }); setShowOpen(false); }} onClose={() => setShowOpen(false)} />}
      {showSave && <SceneFileDialog mode="save" recentPaths={recentPaths} currentPath={savePath} autosavePath={autosavePath} onSubmit={(path) => { sendCommand({ action: "save_scene_code", path }); setShowSave(false); }} onClose={() => setShowSave(false)} />}
      {applicationForm && (
        <ApplicationForm
          mode={applicationForm.mode}
          models={graph.modelLibrary}
          objects={graph.objects}
          application={applicationForm.application}
          initialModelType={applicationForm.initialModelType}
          suggestedSelector={applicationForm.suggestedSelector}
          nameReadOnly={applicationForm.scope === "template"}
          onSubmit={submitApplication}
          onClose={() => setApplicationForm(null)}
        />
      )}
      {bindingForm && (
        <BindingForm endpoints={bindingForm} objects={graph.objects} onSubmit={submitBinding} onClose={() => setBindingForm(null)} />
      )}
      {objectForm && (
        <ObjectForm mode={objectForm.mode} objects={graph.objects} object={objectForm.object} onSubmit={submitObject} onClose={() => setObjectForm(null)} />
      )}
      {overrideApplication && (
        <OverrideForm application={overrideApplication} models={graph.modelLibrary} instances={graph.instances} onSubmit={submitOverride} onClose={() => setOverrideApplication(null)} />
      )}
      {cycleBreakSelection && (
        <CycleBreakDialog
          selection={cycleBreakSelection}
          initialization={graph.initialization}
          onSubmit={(initializeMissing, initialValue) => {
            sendCommand({
              action: "edit",
              kind: "break_cycle",
              applicationId: cycleBreakSelection.application.applicationId,
              input: cycleBreakSelection.port.name,
              initializeMissing,
              initialValue,
            });
            setCycleBreakSelection(null);
          }}
          onClose={() => setCycleBreakSelection(null)}
        />
      )}
    </main>
  );
}

function buildNodes({
  graph,
  view,
  detailMode,
  query,
  unresolvedPortIds,
  previousPortIds,
  candidatePortIds,
  cyclicApplications,
  cycleBreakPortIds,
  cycleBreakMode,
  openCandidates,
  onPortClick,
  onCycleBreak,
}: {
  graph: SceneGraphView;
  view: GraphViewMode;
  detailMode: DetailMode;
  query: string;
  unresolvedPortIds: Set<string>;
  previousPortIds: Set<string>;
  candidatePortIds: Set<string>;
  cyclicApplications: Set<string>;
  cycleBreakPortIds: Set<string>;
  cycleBreakMode: boolean;
  openCandidates: (application: ApplicationGraphNode, port: GraphPort, anchor: { x: number; y: number }) => void;
  onPortClick: (port: GraphPort) => void;
  onCycleBreak: (application: ApplicationGraphNode, port: GraphPort) => void;
}): FlowNode[] {
  const matches = (value: unknown) => !query || JSON.stringify(value).toLowerCase().includes(query.toLowerCase());
  if (view === "topology") {
    return graph.objects.filter(matches).map((object) => ({
      id: object.id,
      type: "entity",
      position: { x: 0, y: 0 },
      data: {
        nodeKind: "object",
        title: object.name || String(object.objectId),
        subtitle: [object.kind, object.scale, object.instance].filter(Boolean).join(" · "),
        badges: [object.species, object.hasStatus ? "status" : null, object.hasGeometry ? "geometry" : null].filter(Boolean) as string[],
        detail: object,
      },
    }));
  }
  if (view === "resolved") {
    const applications = new Map(graph.applications.map((application) => [application.applicationId, application]));
    return graph.executions.filter(matches).map((execution) => {
      const application = applications.get(execution.applicationId);
      return {
        id: execution.id,
        type: "entity",
        position: { x: 0, y: 0 },
        data: {
          nodeKind: "execution",
          title: execution.applicationId,
          subtitle: `object ${String(execution.objectId)}`,
          badges: [shortType(execution.modelType), execution.overridden ? "override" : "shared"],
          inputPortIds: application?.inputs.map((port) => port.id) ?? [],
          outputPortIds: application?.outputs.map((port) => port.id) ?? [],
          detail: execution,
        },
      };
    });
  }
  return graph.applications.filter(matches).map((application) => ({
    id: application.id,
    type: "application",
    position: { x: 0, y: 0 },
    data: {
      ...application,
      nodeKind: "application",
      detailMode,
      cyclic: cyclicApplications.has(application.applicationId),
      requiredInputPortIds: application.inputs.filter((port) => unresolvedPortIds.has(port.id)).map((port) => port.id),
      candidatePortIds: [...application.inputs, ...application.outputs].filter((port) => candidatePortIds.has(port.id)).map((port) => port.id),
      previousTimeStepPortIds: application.inputs.filter((port) => previousPortIds.has(port.id)).map((port) => port.id),
      cycleBreakInputPortIds: application.inputs.filter((port) => cycleBreakPortIds.has(port.id)).map((port) => port.id),
      cycleBreakMode,
      onCandidateClick: (port, anchor) => openCandidates(application, port, anchor),
      onPortClick,
      onCycleBreak,
    },
  }));
}

function buildEdges(graph: SceneGraphView, view: GraphViewMode): FlowEdge[] {
  return graph.edges
    .filter((edge) => edgeProjectionMatches(edge, view))
    .map((edge) => ({
      id: edge.id,
      source: edge.source,
      target: edge.target,
      sourceHandle: edge.sourcePort || undefined,
      targetHandle: edge.targetPort || undefined,
      type: "sceneEdge",
      data: edge,
      markerEnd: { type: MarkerType.ArrowClosed, color: edgeColor(edge), width: 16, height: 16 },
      style: {
        stroke: edgeColor(edge),
        strokeWidth: edge.cycle ? 4 : edge.kind === "manual_call" ? 2.5 : 1.8,
        strokeDasharray: edge.kind === "previous_timestep" ? "7 5" : edge.kind === "manual_call" ? "3 4" : undefined,
      },
    }));
}

function edgeProjectionMatches(edge: SceneGraphEdge, view: GraphViewMode) {
  const projection = (edge as SceneGraphEdge & { projection?: string }).projection;
  if (view === "topology") return edge.kind === "object_topology";
  if (view === "resolved") return projection === "resolved";
  return projection === "applications" || (!projection && !["object_topology", "application_target"].includes(edge.kind));
}

function edgeColor(edge: SceneGraphEdge) {
  if (edge.cycle) return "#cf4937";
  if (edge.kind === "previous_timestep") return "#317b62";
  if (edge.kind === "manual_call") return "#be6a54";
  if (edge.kind === "object_topology") return "#7b7167";
  return "#a59687";
}

export function deriveCandidatePortIds(graph: SceneGraphView) {
  const result = new Set<string>();
  for (const application of graph.applications) {
    for (const input of application.inputs) {
      const existing = graph.applications.some((other) =>
        other.applicationId !== application.applicationId && other.outputs.some((output) => output.name === input.name)
      );
      if (existing || graph.modelLibrary.some((model) => Object.prototype.hasOwnProperty.call(model.outputs, input.name))) result.add(input.id);
    }
    for (const output of application.outputs) {
      const existing = graph.applications.some((other) =>
        other.applicationId !== application.applicationId && other.inputs.some((input) => input.name === output.name)
      );
      if (existing || graph.modelLibrary.some((model) => Object.prototype.hasOwnProperty.call(model.inputs, output.name))) result.add(output.id);
    }
  }
  return result;
}

export function modelsForPort(library: ModelDescriptor[], port: GraphPort) {
  const field = port.role === "input" ? "outputs" : "inputs";
  return library
    .filter((model) => Object.prototype.hasOwnProperty.call(model[field], port.name))
    .sort((left, right) => `${left.package}.${left.name}`.localeCompare(`${right.package}.${right.name}`));
}

function CandidatePopover({
  candidate,
  models,
  applications,
  onSelectModel,
  onSelectApplication,
  onClose,
}: {
  candidate: CandidatePopover;
  models: ModelDescriptor[];
  applications: ApplicationGraphNode[];
  onSelectModel: (model: ModelDescriptor) => void;
  onSelectApplication: (application: ApplicationGraphNode) => void;
  onClose: () => void;
}) {
  const title = candidate.port.role === "input" ? `Models that compute ${candidate.port.name}` : `Models that consume ${candidate.port.name}`;
  return (
    <section className="candidate-popover" style={{ left: Math.min(candidate.x + 8, window.innerWidth - 390), top: Math.min(candidate.y - 20, window.innerHeight - 480) }}>
      <header><div><strong>{title}</strong><span>Exact declared variable-name matches</span></div><button onClick={onClose}><X size={15} /></button></header>
      <div className="candidate-list">
        {applications.length > 0 && <div className="candidate-section-label">Existing applications</div>}
        {applications.map((application) => (
          <button className="candidate-card existing" key={application.applicationId} onClick={() => onSelectApplication(application)}>
            <strong>{application.name || application.applicationId}</strong>
            <span>{application.modelName}</span>
            <small>{application.targetCount} target{application.targetCount === 1 ? "" : "s"}</small>
            <div>Connect without adding another application</div>
          </button>
        ))}
        {models.length > 0 && <div className="candidate-section-label">Available models</div>}
        {models.map((model) => (
          <button className="candidate-card" key={model.type} onClick={() => onSelectModel(model)}>
            <strong>{model.name}</strong>
            <span>{model.process}</span>
            <small>{model.package || model.module}</small>
            <div>{Object.keys(model.inputs).length} inputs · {Object.keys(model.outputs).length} outputs</div>
          </button>
        ))}
      </div>
    </section>
  );
}

export function applicationsForPort(applications: ApplicationGraphNode[], candidate: CandidatePopover) {
  return applications
    .filter((application) => application.applicationId !== candidate.application.applicationId)
    .filter((application) => {
      const ports = candidate.port.role === "input" ? application.outputs : application.inputs;
      return ports.some((port) => port.name === candidate.port.name);
    })
    .sort((left, right) => left.applicationId.localeCompare(right.applicationId));
}

export function endpointsForCandidate(candidate: CandidatePopover, application: ApplicationGraphNode): BindingEndpoints {
  if (candidate.port.role === "input") {
    const sourcePort = application.outputs.find((port) => port.name === candidate.port.name);
    if (!sourcePort) throw new Error(`Application ${application.applicationId} does not output ${candidate.port.name}.`);
    return { sourceApplication: application, sourcePort, targetApplication: candidate.application, targetPort: candidate.port };
  }
  const targetPort = application.inputs.find((port) => port.name === candidate.port.name);
  if (!targetPort) throw new Error(`Application ${application.applicationId} does not input ${candidate.port.name}.`);
  return { sourceApplication: candidate.application, sourcePort: candidate.port, targetApplication: application, targetPort };
}

function Inspector({ selection, port, initialization, interactive, onEditApplication, onRemoveApplication, onOverrideApplication, onEditObject, onRemoveObject }: { selection: InspectorSelection; port: GraphPort | null; initialization: SceneGraphView["initialization"]; interactive: boolean; onEditApplication: (application: ApplicationGraphNode) => void; onRemoveApplication: (application: ApplicationGraphNode) => void; onOverrideApplication: (application: ApplicationGraphNode) => void; onEditObject: (object: ObjectGraphNode) => void; onRemoveObject: (object: ObjectGraphNode) => void }) {
  const application = selection && "applicationId" in selection && "selector" in selection ? selection as ApplicationGraphNode : null;
  const object = selection && "objectId" in selection && !("applicationId" in selection) ? selection as ObjectGraphNode : null;
  return (
    <aside className="scene-inspector">
      <header><strong>Inspector</strong>{selection && <span>{selectionLabel(selection)}</span>}</header>
      {!selection && <div className="empty-inspector"><Boxes size={28} /><p>Select an application, object, execution, or relationship.</p></div>}
      {selection && <pre>{JSON.stringify(selection, null, 2)}</pre>}
      {application && interactive && <div className="inspector-actions"><button onClick={() => onEditApplication(application)}>{application.targetInstances.length > 0 ? "Edit shared template" : "Edit application"}</button>{application.targetInstances.length > 0 && <button onClick={() => onOverrideApplication(application)}>Create override</button>}<button className="danger" onClick={() => onRemoveApplication(application)}>{application.targetInstances.length > 0 ? "Remove from shared template" : "Remove application"}</button></div>}
      {object && interactive && <div className="inspector-actions"><button onClick={() => onEditObject(object)}>Edit object</button><button className="danger" onClick={() => onRemoveObject(object)}>Remove object and descendants</button></div>}
      {port && <section><h4>Selected variable</h4><code>{port.name}</code><p>{port.expectedType}</p></section>}
      {selection && initialization.length > 0 && (
        <section className="inspector-initialization"><h4>Initialization</h4>{initialization.slice(0, 8).map((row) => <div key={`${row.applicationId}:${row.objectId}:${row.variable}`}><code>{row.variable}</code><span className={row.disposition === "unresolved" ? "unresolved" : ""}>{row.disposition}</span></div>)}</section>
      )}
    </aside>
  );
}

function DiagnosticsPanel({ graph, onClose, sendCommand, interactive }: { graph: SceneGraphView; onClose: () => void; sendCommand: (command: Record<string, unknown>) => void; interactive: boolean }) {
  return <Overlay title="Diagnostics and cycles" onClose={onClose}>
    {graph.diagnostics.map((diagnostic) => <article className="diagnostic-card" key={`${diagnostic.code}:${diagnostic.message}`}><strong>{diagnostic.code}</strong><p>{diagnostic.message}</p>{diagnostic.suggestions.map((suggestion) => <small key={suggestion}>{suggestion}</small>)}</article>)}
    {graph.cycles.map((cycle) => <article className="cycle-card" key={cycle.id}><strong>{cycle.applicationIds.join(" → ")}</strong><p>Choose an input to read from the previous timestep.</p>{cycle.breakCandidates.map((candidate) => <button disabled={!interactive} key={`${candidate.applicationId}:${candidate.objectId}:${candidate.input}`} onClick={() => sendCommand({ action: "edit", kind: "mark_previous_timestep", applicationId: candidate.applicationId, input: candidate.input })}>{candidate.applicationId}.{candidate.input}</button>)}</article>)}
    {graph.diagnostics.length === 0 && graph.cycles.length === 0 && <p>No diagnostics.</p>}
  </Overlay>;
}

function InitializationPanel({ graph, onClose, sendCommand, interactive }: { graph: SceneGraphView; onClose: () => void; sendCommand: (command: Record<string, unknown>) => void; interactive: boolean }) {
  const unresolved = graph.initialization.filter((row) => row.disposition === "unresolved");
  const groups = new Map<string, typeof unresolved>();
  for (const row of unresolved) {
    const key = `${row.applicationId}:${row.variable}`;
    groups.set(key, [...(groups.get(key) || []), row]);
  }
  return <Overlay title="Initialization" onClose={onClose}>
    {[...groups.entries()].map(([key, rows]) => <InitializationGroup key={key} rows={rows} interactive={interactive} sendCommand={sendCommand} />)}
    {unresolved.length === 0 && <p>No unresolved initial values.</p>}
  </Overlay>;
}

function InitializationGroup({ rows, interactive, sendCommand }: { rows: SceneGraphView["initialization"]; interactive: boolean; sendCommand: (command: Record<string, unknown>) => void }) {
  const [valueType, setValueType] = useState("float");
  const [value, setValue] = useState("");
  const first = rows[0];
  const typedValue = { type: valueType, value };
  return <article className="initialization-group">
    <header><div><strong>{first.variable}</strong><span>{first.applicationId}</span></div><small>{rows.length} object{rows.length === 1 ? "" : "s"} · expected {first.expectedType}</small></header>
    <p>Required because the input has no producer, environment source, status value, or usable temporal initialization.</p>
    {interactive && <div className="initialization-value"><label>Type<select value={valueType} onChange={(event) => setValueType(event.target.value)}><option value="float">Float</option><option value="integer">Integer</option><option value="boolean">Boolean</option><option value="symbol">Symbol</option><option value="string">String</option><option value="julia">Julia expression</option></select></label><label>Value<input value={value} onChange={(event) => setValue(event.target.value)} /></label><button disabled={!value.trim()} onClick={() => sendCommand({ action: "edit", kind: "set_object_statuses", objectIds: rows.map((row) => row.objectId), variable: first.variable, value: typedValue })}>Set all targets</button></div>}
    <div className="initialization-object-list">{rows.map((row) => <div key={String(row.objectId)}><span>Object {String(row.objectId)}</span><code>{row.origin}</code>{interactive && <button disabled={!value.trim()} onClick={() => sendCommand({ action: "edit", kind: "set_object_status", objectId: row.objectId, variable: row.variable, value: typedValue })}>Set this object</button>}</div>)}</div>
  </article>;
}

function SceneCodePanel({ code, onClose }: { code: string; onClose: () => void }) {
  return <Overlay title="Scene code" onClose={onClose}><pre className="scene-code">{code || "Scene code is available from an interactive editor session."}</pre></Overlay>;
}

function SceneFileDialog({ mode, recentPaths, currentPath, autosavePath, onSubmit, onClose }: { mode: "open" | "save"; recentPaths: string[]; currentPath: string | null; autosavePath: string | null; onSubmit: (path: string) => void; onClose: () => void }) {
  const [path, setPath] = useState(currentPath || "");
  return <Overlay title={mode === "open" ? "Open Scene" : "Save Scene"} onClose={onClose}>
    <div className="scene-file-dialog">
      <p>{mode === "open" ? "Open a Julia script whose final binding is `scene = Scene(...)`. Future edits will be saved back to that file." : "After the first save, every successful graph edit automatically rewrites this Julia script."}</p>
      <label>Julia file path<div className="scene-path-input"><input value={path} onChange={(event) => setPath(event.target.value)} placeholder="/absolute/path/to/scene.jl" autoFocus /><button className="primary" disabled={!path.trim()} onClick={() => onSubmit(path.trim())}>{mode === "open" ? "Open" : "Save"}</button></div></label>
      {mode === "open" && recentPaths.length > 0 && <section><strong>Recent scenes</strong><div className="recent-scene-list">{recentPaths.map((recent) => <button key={recent} onClick={() => onSubmit(recent)}><span>{recent.split("/").at(-1)}</span><small>{recent}</small></button>)}</div></section>}
      {mode === "open" && autosavePath && <section><strong>Recovery autosave</strong><button className="recovery-path" onClick={() => onSubmit(autosavePath)}>{autosavePath}</button></section>}
      <small>Use Git to version saved Scene scripts and review scientific configuration changes.</small>
    </div>
  </Overlay>;
}

function CycleBreakDialog({
  selection,
  initialization,
  onSubmit,
  onClose,
}: {
  selection: CycleBreakSelection;
  initialization: SceneGraphView["initialization"];
  onSubmit: (initializeMissing: boolean, initialValue: { type: string; value: string } | null) => void;
  onClose: () => void;
}) {
  const missing = initialization.filter((row) =>
    row.applicationId === selection.application.applicationId &&
    row.variable === selection.port.name &&
    row.disposition !== "supplied"
  );
  const [valueType, setValueType] = useState("float");
  const [value, setValue] = useState("");
  return <div className="overlay-backdrop" onMouseDown={onClose}>
    <section className="overlay-panel cycle-break-dialog" onMouseDown={(event) => event.stopPropagation()} data-testid="cycle-break-dialog">
      <header><div><strong>Break the current-step cycle</strong><span>{selection.application.applicationId}.{selection.port.name}</span></div><button onClick={onClose}><X size={17} /></button></header>
      <div className="overlay-content">
        <p>This changes the application input to read its value from the previous accepted timestep. The model is disconnected from the current value during each run step.</p>
        <div className="cycle-impact"><strong>Application-wide change</strong><span>It affects all {selection.application.targetCount} targets selected by this application.</span></div>
        {missing.length > 0 && <fieldset><legend>Required initial value</legend><p>{missing.length} target{missing.length === 1 ? "" : "s"} need a value before the first timestep.</p><div className="form-grid"><label>Value type<select value={valueType} onChange={(event) => setValueType(event.target.value)}><option value="float">Float</option><option value="integer">Integer</option><option value="boolean">Boolean</option><option value="symbol">Symbol</option><option value="string">String</option><option value="julia">Julia expression</option></select></label><label>Initial value<input value={value} onChange={(event) => setValue(event.target.value)} autoFocus /></label></div></fieldset>}
      </div>
      <footer><button onClick={onClose}>Cancel</button><button className="primary" disabled={missing.length > 0 && !value.trim()} onClick={() => onSubmit(missing.length > 0, missing.length > 0 ? { type: valueType, value } : null)} data-testid="confirm-cycle-break"><Scissors size={15} /> Use previous timestep</button></footer>
    </section>
  </div>;
}

function Overlay({ title, onClose, children }: { title: string; onClose: () => void; children: React.ReactNode }) {
  return <div className="overlay-backdrop" onMouseDown={onClose}><section className="overlay-panel" onMouseDown={(event) => event.stopPropagation()}><header><strong>{title}</strong><button onClick={onClose}><X size={17} /></button></header><div className="overlay-content">{children}</div></section></div>;
}

function selectionLabel(selection: Exclude<InspectorSelection, null>) {
  if ("applicationId" in selection) return selection.applicationId;
  if ("objectId" in selection) return String(selection.objectId);
  return selection.kind.replaceAll("_", " ");
}

function shortType(type: string) {
  return type.split(".").at(-1) || type;
}

export function selectorSuggestion(application: ApplicationGraphNode): ApplicationGraphNode["selector"] {
  const criteria: Record<string, unknown> = { selectors: [] };
  if (application.targetInstances.length === 0 && application.targetScales.length === 1) criteria.scale = application.targetScales[0];
  if (application.targetKinds.length === 1) criteria.kind = application.targetKinds[0];
  if (application.targetSpecies.length === 1) criteria.species = application.targetSpecies[0];
  return { type: application.targetCount === 1 ? "One" : "Many", multiplicity: application.targetCount === 1 ? "one" : "many", criteria, julia: "" };
}

export function applicationPortId(applicationId: string, role: "input" | "output", variable: string) {
  return `application:${applicationId}:${role}:${variable}`;
}

function loadInitialGraph(): SceneGraphView {
  const element = document.getElementById("pse-scene-graph-data");
  if (!element?.textContent) return sampleGraph;
  try { return JSON.parse(element.textContent) as SceneGraphView; } catch { return sampleGraph; }
}

function loadEditorConfig(): { websocketUrl: string } | null {
  const element = document.getElementById("pse-editor-config");
  if (!element?.textContent) return null;
  try { return JSON.parse(element.textContent) as { websocketUrl: string }; } catch { return null; }
}

export type GraphPort = {
  id: string;
  name: string;
  role: "input" | "output";
  mappingMode: string | null;
  sourceScale: string | null;
  sourceVariable: string | null;
  previousTimeStep: boolean;
  default: string;
};

export type GraphNodeData = {
  id: string;
  process: string;
  scale: string;
  modelType: string;
  role: "model" | "hard_dependency";
  rate: string;
  modelParameters?: Record<string, { value: string; type: string }>;
  timestep?: { mode: "default" | "clock" | "julia"; dt?: string; phase?: string; value?: string };
  inputs: GraphPort[];
  outputs: GraphPort[];
  ownOutputIds?: string[];
  parent: string | null;
  diagnostics: string[];
} & Record<string, unknown>;

export type RuntimeGraphNodeData = GraphNodeData & {
  viewMode?: "overview" | "detail";
  activePortId?: string | null;
  highlightedPortIds?: string[];
  focusedPortIds?: string[];
  requiredInputPortIds?: string[];
  candidatePortIds?: string[];
  dimmed?: boolean;
  focused?: boolean;
  onPortEnter?: (port: GraphPort) => void;
  onPortLeave?: (port: GraphPort) => void;
  onCandidateClick?: (port: GraphPort, anchor: { x: number; y: number }) => void;
  onRemoveModel?: (node: GraphNodeData) => void;
};

export type GraphEdgeData = {
  id: string;
  source: string;
  target: string;
  sourcePort: string | null;
  targetPort: string | null;
  sourceVariable: string | null;
  targetVariable: string | null;
  kind: "soft_dependency" | "mapped_variable" | "hard_dependency";
  scaleRelation: "same_scale" | "multiscale";
  label: string;
  diagnostics: string[];
} & Record<string, unknown>;

export type DependencyGraphView = {
  nodes: GraphNodeData[];
  edges: GraphEdgeData[];
  scales: string[];
  cyclic: boolean;
  cycleNodes: string[];
  cycleEdges?: string[];
  diagnostics: string[];
};

export type ModelConstructorField = {
  name: string;
  declaredType: string;
  hasDefault: boolean;
  default: unknown;
  defaultType: string | null;
  typeParameter: string | null;
  inferredChoice: string;
  choices: string[];
};

export type ModelDescriptor = {
  type: string;
  name: string;
  process: string | null;
  processType: string | null;
  inputs: Record<string, unknown>;
  outputs: Record<string, unknown>;
  timespec?: string;
  timestepHint?: string;
  meteoHint?: string;
  outputPolicy?: string;
  constructor: {
    fields: ModelConstructorField[];
    parameterGroups: Record<string, string[]>;
    hasZeroArgConstructor: boolean;
  };
};

export type InitializationDescriptor = {
  scale: string;
  name: string;
  value: string;
  type: string;
  provided: boolean;
};

export type GraphEditorState = {
  ok: boolean;
  diagnostics: string[];
  graph: DependencyGraphView;
  models: ModelDescriptor[];
  canUndo: boolean;
  canRedo: boolean;
  url: string;
  mappingCode: string;
  initializations: InitializationDescriptor[];
  lastSavedPath: string | null;
  saveTargetPath: string | null;
  autosavePath: string | null;
  lastAutosavedPath: string | null;
  recentMappings: string[];
};

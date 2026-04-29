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
  inputs: GraphPort[];
  outputs: GraphPort[];
  parent: string | null;
  diagnostics: string[];
} & Record<string, unknown>;

export type RuntimeGraphNodeData = GraphNodeData & {
  activePortId?: string | null;
  highlightedPortIds?: string[];
  requiredInputPortIds?: string[];
  onPortEnter?: (port: GraphPort) => void;
  onPortLeave?: () => void;
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
  diagnostics: string[];
};

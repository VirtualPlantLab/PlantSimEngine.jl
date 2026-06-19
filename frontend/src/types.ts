export type GraphPortRole = "input" | "output" | "environment_input" | "environment_output";

export type GraphPort = {
  id: string;
  name: string;
  role: GraphPortRole;
  default: unknown;
  defaultJulia: string;
  expectedType: string;
};

export type SelectorDescriptor = {
  type: string;
  multiplicity: "one" | "optional_one" | "many";
  criteria: Record<string, unknown>;
  julia: string;
};

export type ModelParameter = {
  value: unknown;
  julia: string;
  type: string;
  juliaType: string;
};

export type ApplicationGraphNode = {
  id: string;
  applicationId: string;
  name: string | null;
  process: string;
  modelType: string;
  modelName: string;
  module: string;
  package: string | null;
  modelParameters: Record<string, ModelParameter>;
  selector: SelectorDescriptor;
  targetIds: unknown[];
  targetCount: number;
  targetScales: string[];
  targetKinds: string[];
  targetSpecies: string[];
  targetInstances: string[];
  timestep: unknown;
  clock: unknown;
  inputs: GraphPort[];
  outputs: GraphPort[];
  environmentInputs: GraphPort[];
  environmentOutputs: GraphPort[];
  modelStorage: "shared_application" | "per_object_override";
  objectOverrides: Array<Record<string, unknown>>;
};

export type ObjectGraphNode = {
  id: string;
  objectId: unknown;
  scale: string | null;
  kind: string | null;
  species: string | null;
  name: string | null;
  instance: string | null;
  parent: string | null;
  children: string[];
  hasGeometry: boolean;
  hasStatus: boolean;
};

export type InstanceDescriptor = {
  id: string;
  name: string;
  rootId: unknown;
  kind: string | null;
  species: string | null;
  objectIds: unknown[];
  applicationIds: string[];
  instanceOverrides: string[];
  objectOverrides: Array<Record<string, unknown>>;
  parametersType: string;
};

export type ExecutionGraphNode = {
  id: string;
  applicationId: string;
  applicationNodeId: string;
  objectId: unknown;
  objectNodeId: string;
  modelType: string;
  modelParameters: Record<string, ModelParameter>;
  overridden: boolean;
};

export type SceneGraphEdge = {
  id: string;
  source: string;
  target: string;
  sourcePort?: string | null;
  targetPort?: string | null;
  sourceVariable?: string | null;
  targetVariable?: string | null;
  sourceApplicationId?: string;
  targetApplicationId?: string;
  sourceObjectIds?: unknown[];
  targetObjectIds?: unknown[];
  kind: "value_binding" | "inferred_same_object" | "previous_timestep" | "manual_call" | "object_topology" | "application_target" | "update_order" | "environment_binding" | string;
  origin?: string;
  multiplicity?: string;
  policy?: string;
  selector?: SelectorDescriptor;
  call?: string;
  projection?: "applications" | "topology" | "resolved" | "targets";
  cycle: boolean;
};

export type InitializationDescriptor = {
  applicationId: string;
  objectId: unknown;
  variable: string;
  role: GraphPortRole;
  disposition: "generated" | "producer_bound" | "supplied" | "environment_bound" | "unresolved";
  value: unknown;
  valueJulia: string;
  expectedType: string;
  sourceApplicationIds: string[];
  sourceObjectIds: unknown[];
  sourceVariable: string | null;
  origin: string;
  previousTimeStep: boolean;
};

export type GraphDiagnostic = {
  code: string;
  severity: "error" | "warning" | "info";
  message: string;
  phase: string;
  applicationIds: string[];
  objectIds: unknown[];
  variable: string | null;
  suggestions: string[];
};

export type CycleDescriptor = {
  id: string;
  applicationIds: string[];
  edges: Array<{ sourceApplicationId: string; targetApplicationId: string }>;
  breakCandidates: Array<{
    applicationId: string;
    objectId: unknown;
    input: string;
    sourceApplicationIds: string[];
    sourceObjectIds: unknown[];
    sourceVariable: string;
    selector: SelectorDescriptor;
  }>;
};

export type ModelConstructorField = {
  name: string;
  declaredType: string;
  hasDefault: boolean;
  default: unknown;
  defaultJulia: string | null;
  defaultType: string | null;
  typeParameter: string | null;
  inferredChoice: string;
  choices: string[];
};

export type ModelDescriptor = {
  type: string;
  name: string;
  module: string;
  package: string | null;
  process: string | null;
  processType: string | null;
  inputs: Record<string, unknown>;
  outputs: Record<string, unknown>;
  environmentInputs: Record<string, unknown>;
  environmentOutputs: Record<string, unknown>;
  timespec?: string | null;
  timestepHint?: string | null;
  meteoHint?: string | null;
  outputPolicy?: string | null;
  constructor: {
    fields: ModelConstructorField[];
    parameterGroups: Record<string, string[]>;
    hasZeroArgConstructor: boolean;
    constructible: boolean;
  };
};

export type SceneGraphView = {
  schemaVersion: number;
  level: "applications" | "topology" | "resolved";
  metadata: {
    title: string;
    sceneRevision: number;
    objectCount: number;
    instanceCount: number;
    applicationCount: number;
    executionCount: number;
    bindingCount: number;
    callCount: number;
    unresolvedInitializationCount: number;
    cyclic: boolean;
    strictlyCompiled: boolean;
  };
  objects: ObjectGraphNode[];
  instances: InstanceDescriptor[];
  applications: ApplicationGraphNode[];
  executions: ExecutionGraphNode[];
  edges: SceneGraphEdge[];
  modelLibrary: ModelDescriptor[];
  initialization: InitializationDescriptor[];
  diagnostics: GraphDiagnostic[];
  cycles: CycleDescriptor[];
  availableActions: string[];
};

export type GraphViewMode = "applications" | "topology" | "resolved";
export type DetailMode = "overview" | "detail";

export type RuntimeApplicationNode = ApplicationGraphNode & {
  nodeKind: "application";
  detailMode: DetailMode;
  cyclic: boolean;
  requiredInputPortIds: string[];
  candidatePortIds: string[];
  previousTimeStepPortIds: string[];
  cycleBreakInputPortIds: string[];
  cycleBreakMode: boolean;
  onCandidateClick?: (port: GraphPort, anchor: { x: number; y: number }) => void;
  onPortClick?: (port: GraphPort) => void;
  onCycleBreak?: (application: ApplicationGraphNode, port: GraphPort) => void;
};

export type RuntimeEntityNode = {
  nodeKind: "object" | "execution";
  title: string;
  subtitle: string;
  badges: string[];
  inputPortIds?: string[];
  outputPortIds?: string[];
  detail: ObjectGraphNode | ExecutionGraphNode;
};

export type EditorState = {
  ok: boolean;
  graph: SceneGraphView;
  diagnostics: string[];
  canUndo: boolean;
  canRedo: boolean;
  url: string;
  sceneCode?: string;
  autosavePath?: string | null;
  savePath?: string | null;
  recentPaths?: string[];
};

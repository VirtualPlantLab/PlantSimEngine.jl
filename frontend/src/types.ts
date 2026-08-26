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

export type CallMode = "manual" | "initializer";

export type CallBindingDescriptor = SelectorDescriptor & {
  mode: CallMode;
};

export type ModelParameter = {
  value: unknown;
  julia: string;
  type: string;
  juliaType: string;
};

export type ApplicationRef = {
  scope: "global" | "template";
  applicationId: string;
  instance: string | null;
};

export type ApplicationOwner = ApplicationRef & {
  templateId: string | null;
};

export type PeriodDescriptor = {
  mode: "default" | "period" | "custom";
  value: number | null;
  unit: string | null;
  julia: string;
};

export type ApplicationEnvironment = {
  backendId: string | null;
  provider: string | null;
  sources: Record<string, string>;
  sink: string | null;
  extra: Record<string, unknown>;
};

export type ApplicationGraphNode = {
  id: string;
  applicationId: string;
  owner: ApplicationOwner;
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
  cadence: PeriodDescriptor;
  clock: unknown;
  inputs: GraphPort[];
  outputs: GraphPort[];
  environmentInputs: GraphPort[];
  environmentOutputs: GraphPort[];
  inputBindings: Record<string, SelectorDescriptor>;
  callBindings: Record<string, CallBindingDescriptor>;
  environment: ApplicationEnvironment | null;
  environmentBindings: Record<string, unknown>;
  environmentWindow: PeriodDescriptor;
  outputRouting: Record<string, string>;
  updates: Array<{ variables: string[]; after: string[] }>;
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
  parent: unknown | null;
  children: unknown[];
  hasGeometry: boolean;
  hasStatus: boolean;
};

export type InstanceDescriptor = {
  id: string;
  name: string;
  templateId: string;
  rootId: unknown;
  kind: string | null;
  species: string | null;
  objectIds: unknown[];
  applicationIds: string[];
  instanceOverrides: string[];
  objectOverrides: Array<Record<string, unknown>>;
  parametersType: string;
};

export type TemplateApplicationDescriptor = {
  applicationId: string;
  process: string;
  modelType: string;
  modelName: string;
  selector: SelectorDescriptor | null;
  cadence: PeriodDescriptor;
};

export type TemplateDescriptor = {
  id: string;
  name: string;
  source: "catalog" | "model";
  kind: string | null;
  species: string | null;
  parameters: unknown;
  parametersJulia: string;
  applications: TemplateApplicationDescriptor[];
  mountedInstances: string[];
};

export type EnvironmentDescriptor = {
  id: string;
  name: string;
  source: "catalog" | "model";
  type: string;
  variables: string[];
  active: boolean;
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

export type ModelGraphEdge = {
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
  kind: "value_binding" | "inferred_same_object" | "previous_timestep" | "manual_call" | "initializer" | "object_topology" | "application_target" | "update_order" | "environment_binding" | string;
  origin?: string;
  multiplicity?: string;
  policy?: string;
  selector?: SelectorDescriptor;
  call?: string;
  mode?: CallMode;
  variables?: string[];
  provider?: string;
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
  environmentHint?: string | null;
  outputPolicy?: string | null;
  constructor: {
    fields: ModelConstructorField[];
    parameterGroups: Record<string, string[]>;
    hasZeroArgConstructor: boolean;
    constructible: boolean;
  };
};

export type ModelGraphView = {
  schemaVersion: number;
  level: "applications" | "topology" | "resolved";
  metadata: {
    title: string;
    modelRevision: number;
    objectCount: number;
    instanceCount: number;
    applicationCount: number;
    executionCount: number;
    bindingCount: number;
    callCount: number;
    unresolvedInitializationCount: number;
    cyclic: boolean;
    strictlyCompiled: boolean;
    sceneEnvironmentId: string | null;
  };
  objects: ObjectGraphNode[];
  templates: TemplateDescriptor[];
  instances: InstanceDescriptor[];
  applications: ApplicationGraphNode[];
  executions: ExecutionGraphNode[];
  edges: ModelGraphEdge[];
  modelLibrary: ModelDescriptor[];
  environments: EnvironmentDescriptor[];
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
  nodeKind: "model" | "template" | "instance" | "object" | "execution" | "environment";
  title: string;
  subtitle: string;
  badges: string[];
  inputPortIds?: string[];
  outputPortIds?: string[];
  detail: ModelRootDescriptor | TemplateDescriptor | InstanceDescriptor | ObjectGraphNode | ExecutionGraphNode | EnvironmentDescriptor | EnvironmentGraphNode;
};

export type EnvironmentGraphNode = {
  provider: string;
};

export type ModelRootDescriptor = {
  entity: "model";
  objectCount: number;
  instanceCount: number;
  applicationCount: number;
};

export type EditorState = {
  ok: boolean;
  graph: ModelGraphView;
  diagnostics: string[];
  canUndo: boolean;
  canRedo: boolean;
  url: string;
  modelCode?: string;
  autosavePath?: string | null;
  savePath?: string | null;
  recentPaths?: string[];
  selectorPreview?: SelectorPreview;
  targetPreview?: TargetPreview;
  instancePreview?: InstancePreview;
};

export type SelectorPreview = {
  applicationRef: ApplicationRef;
  input: string;
  consumerObjectIds: unknown[];
  sourceObjectIds: unknown[];
  sourceApplicationIds: string[];
  bindingCount: number;
  diagnostics: string[];
};

export type TargetPreview = {
  objectIds: unknown[];
  count: number;
  groups: Array<{ instance: string; objectIds: unknown[] }>;
};

export type InstancePreview = {
  name: string;
  objectIds: unknown[];
  applications: Array<{ applicationId: string; targetIds: unknown[] }>;
  diagnostics: string[];
};

import type { ApplicationGraphNode, GraphPort, ModelGraphEdge, ModelGraphView } from "./types";

const source = application("source", "degree_days", "ToyDegreeDaysCumulModel", [], ["TT_cu"]);
const lai = application("lai", "lai_dynamic", "ToyLAIModel", ["TT_cu"], ["LAI"]);
const light = application("light", "light_interception", "Beer", ["LAI"], ["aPPFD"]);

export const sampleModelGraph: ModelGraphView = {
  schemaVersion: 2,
  level: "applications",
  metadata: {
    title: "PlantSimEngine Model Graph",
    modelRevision: 0,
    objectCount: 1,
    instanceCount: 0,
    applicationCount: 3,
    executionCount: 3,
    bindingCount: 2,
    callCount: 0,
    unresolvedInitializationCount: 1,
    cyclic: false,
    strictlyCompiled: true,
    sceneEnvironmentId: null,
  },
  objects: [{ id: "object:plant", objectId: "plant", scale: "Plant", kind: "plant", species: null, name: "plant", instance: null, parent: null, children: [], hasGeometry: false, hasStatus: true }],
  templates: [],
  instances: [],
  applications: [source, lai, light],
  executions: [source, lai, light].map((item) => ({ id: `execution:${item.applicationId}:plant`, applicationId: item.applicationId, applicationNodeId: item.id, objectId: "plant", objectNodeId: "object:plant", modelType: item.modelType, modelParameters: {}, overridden: false })),
  edges: [edge(source, "TT_cu", lai, "TT_cu"), edge(lai, "LAI", light, "LAI")],
  modelLibrary: [],
  environments: [],
  initialization: [{ applicationId: "source", objectId: "plant", variable: "TT", role: "input", disposition: "unresolved", value: "-Inf", valueJulia: "-Inf", expectedType: "Float64", sourceApplicationIds: [], sourceObjectIds: [], sourceVariable: null, origin: "missing", previousTimeStep: false }],
  diagnostics: [],
  cycles: [],
  availableActions: ["inspect"],
};

function application(applicationId: string, process: string, modelName: string, inputs: string[], outputs: string[]): ApplicationGraphNode {
  return {
    id: `application:${applicationId}`,
    applicationId,
    owner: { scope: "global", applicationId, instance: null, templateId: null },
    name: applicationId,
    process,
    modelType: modelName,
    modelName,
    module: "PlantSimEngine.Examples",
    package: "PlantSimEngine",
    modelParameters: {},
    selector: { type: "One", multiplicity: "one", criteria: { scale: "Plant" }, julia: "One(scale=:Plant)" },
    targetIds: ["plant"],
    targetCount: 1,
    targetScales: ["Plant"],
    targetKinds: ["plant"],
    targetSpecies: [],
    targetInstances: [],
    cadence: { mode: "default", value: null, unit: null, julia: "nothing" },
    clock: null,
    inputs: inputs.map((name) => port(applicationId, "input", name)),
    outputs: outputs.map((name) => port(applicationId, "output", name)),
    environmentInputs: [],
    environmentOutputs: [],
    inputBindings: {},
    callBindings: {},
    environment: null,
    environmentBindings: {},
    environmentWindow: { mode: "default", value: null, unit: null, julia: "nothing" },
    outputRouting: {},
    updates: [],
    modelStorage: "shared_application",
    objectOverrides: [],
  };
}

function port(applicationId: string, role: "input" | "output", name: string): GraphPort {
  return { id: `application:${applicationId}:${role}:${name}`, name, role, default: "-Inf", defaultJulia: "-Inf", expectedType: "Float64" };
}

function edge(sourceApplication: ApplicationGraphNode, sourceVariable: string, targetApplication: ApplicationGraphNode, targetVariable: string): ModelGraphEdge {
  return {
    id: `binding:${sourceApplication.applicationId}:${sourceVariable}:${targetApplication.applicationId}:${targetVariable}`,
    source: sourceApplication.id,
    target: targetApplication.id,
    sourcePort: `application:${sourceApplication.applicationId}:output:${sourceVariable}`,
    targetPort: `application:${targetApplication.applicationId}:input:${targetVariable}`,
    sourceVariable,
    targetVariable,
    sourceApplicationId: sourceApplication.applicationId,
    targetApplicationId: targetApplication.applicationId,
    kind: "inferred_same_object",
    cycle: false,
    projection: "applications",
  };
}

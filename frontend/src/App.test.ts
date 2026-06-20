import { describe, expect, it } from "vitest";
import { applicationPortId, applicationsForPort, deriveCandidatePortIds, endpointsForCandidate, modelsForPort, objectSubtreeIds, selectorSuggestion } from "./App";
import type { ApplicationGraphNode, GraphPort, ModelDescriptor, ObjectGraphNode, SceneGraphView } from "./types";

const output: GraphPort = { id: applicationPortId("source", "output", "signal"), name: "signal", role: "output", default: 0, defaultJulia: "0", expectedType: "Int" };
const input: GraphPort = { id: applicationPortId("consumer", "input", "signal"), name: "signal", role: "input", default: 0, defaultJulia: "0", expectedType: "Int" };

const source = application("source", [], [output], ["leaf"]);
const consumer = application("consumer", [input], [], ["leaf"]);

describe("candidate composition", () => {
  it("keeps plus controls for exact existing-application matches", () => {
    const graph = graphView([source, consumer], []);
    const ids = deriveCandidatePortIds(graph);
    expect(ids.has(output.id)).toBe(true);
    expect(ids.has(input.id)).toBe(true);
  });

  it("matches model descriptors by exact declared variable name", () => {
    const exact = model("Exact", { signal: 0 }, {});
    const near = model("Near", { Signal: 0 }, {});
    expect(modelsForPort([near, exact], output).map((item) => item.name)).toEqual(["Exact"]);
  });

  it("separates existing applications and produces directed binding endpoints", () => {
    const candidate = { application: source, port: output, x: 0, y: 0 };
    expect(applicationsForPort([source, consumer], candidate)).toEqual([consumer]);
    const endpoints = endpointsForCandidate(candidate, consumer);
    expect(endpoints.sourceApplication.applicationId).toBe("source");
    expect(endpoints.targetApplication.applicationId).toBe("consumer");
    expect(endpoints.targetPort.name).toBe("signal");
  });
});

describe("selector suggestions", () => {
  it("suggests a conservative target selector from one application", () => {
    const suggestion = selectorSuggestion(source);
    expect(suggestion.multiplicity).toBe("one");
    expect(suggestion.criteria.scale).toBe("Leaf");
  });
});

describe("object topology scoping", () => {
  it("includes the selected object and all descendants", () => {
    const objects: ObjectGraphNode[] = [
      object("plant", null),
      object("leaf", "plant"),
      object("cell", "leaf"),
      object("soil", null),
    ];
    expect(new Set(objectSubtreeIds(objects, "plant"))).toEqual(new Set(["plant", "leaf", "cell"]));
  });
});

function application(id: string, inputs: GraphPort[], outputs: GraphPort[], targetIds: unknown[]): ApplicationGraphNode {
  return {
    id: `application:${id}`, applicationId: id, name: id, process: id, modelType: id, modelName: id, module: "Main", package: null,
    modelParameters: {}, selector: { type: "One", multiplicity: "one", criteria: { selectors: [], scale: "Leaf" }, julia: "" },
    targetIds, targetCount: targetIds.length, targetScales: ["Leaf"], targetKinds: [], targetSpecies: [], targetInstances: [], timestep: null, clock: null,
    inputs, outputs, environmentInputs: [], environmentOutputs: [], inputBindings: {}, callBindings: {}, environment: null, meteoBindings: {}, meteoWindow: null, outputRouting: {}, updates: [], modelStorage: "shared_application", objectOverrides: [],
  };
}

function model(name: string, inputs: Record<string, unknown>, outputs: Record<string, unknown>): ModelDescriptor {
  return { type: name, name, module: "Main", package: null, process: name, processType: name, inputs, outputs, environmentInputs: {}, environmentOutputs: {}, constructor: { fields: [], parameterGroups: {}, hasZeroArgConstructor: true, constructible: true } };
}

function object(id: string, parent: string | null): ObjectGraphNode {
  return { id: `object:${id}`, objectId: id, scale: null, kind: null, species: null, name: id, instance: null, parent, children: [], hasGeometry: false, hasStatus: false };
}

function graphView(applications: ApplicationGraphNode[], modelLibrary: ModelDescriptor[]): SceneGraphView {
  return {
    schemaVersion: 1, level: "applications", metadata: { title: "", sceneRevision: 0, objectCount: 1, instanceCount: 0, applicationCount: applications.length, executionCount: applications.length, bindingCount: 0, callCount: 0, unresolvedInitializationCount: 0, cyclic: false, strictlyCompiled: true },
    objects: [], instances: [], applications, executions: [], edges: [], modelLibrary, initialization: [], diagnostics: [], cycles: [], availableActions: [],
  };
}

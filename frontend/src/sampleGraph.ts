import type { DependencyGraphView, GraphEdgeData, GraphNodeData, GraphPort } from "./types";

const scales = ["Scene", "Plant", "Leaf"];

export const sampleGraph: DependencyGraphView = {
  nodes: [
    node("meteo", "Scene", "WeatherDriver", "hourly", [], [
      output("meteo", "Scene", "PPFD"),
      output("meteo", "Scene", "Tair"),
      output("meteo", "Scene", "VPD"),
    ]),
    node("lai", "Plant", "ToyLAIModel", "daily", [
      input("lai", "Plant", "TT_cu", { defaultValue: "0.0" }),
      input("lai", "Plant", "biomass", { previousTimeStep: true, defaultValue: "PreviousTimeStep(Float64)" }),
    ], [
      output("lai", "Plant", "LAI"),
    ], ["biomass is read from the previous timestep to keep the growth/LAI feedback open."]),
    node("light_interception", "Leaf", "BeerLambert", "hourly", [
      input("light_interception", "Leaf", "LAI", { mappingMode: "SingleNodeMapping", sourceScale: "Plant", sourceVariable: "LAI", defaultValue: "0.0" }),
      input("light_interception", "Leaf", "PPFD", { mappingMode: "SingleNodeMapping", sourceScale: "Scene", sourceVariable: "PPFD", defaultValue: "0.0" }),
    ], [
      output("light_interception", "Leaf", "aPPFD"),
    ]),
    node("stomatal_conductance", "Leaf", "MedlynGs", "hourly", [
      input("stomatal_conductance", "Leaf", "VPD", { mappingMode: "SingleNodeMapping", sourceScale: "Scene", sourceVariable: "VPD", defaultValue: "1.0" }),
      input("stomatal_conductance", "Leaf", "psi_leaf", { mappingMode: "SingleNodeMapping", sourceScale: "Plant", sourceVariable: "psi_leaf", previousTimeStep: true, defaultValue: "PreviousTimeStep(-0.3)" }),
    ], [
      output("stomatal_conductance", "Leaf", "gs"),
    ]),
    node("boundary_layer", "Leaf", "ForcedConvection", "hourly", [
      input("boundary_layer", "Leaf", "wind", { mappingMode: "SingleNodeMapping", sourceScale: "Scene", sourceVariable: "wind", defaultValue: "1.2" }),
      input("boundary_layer", "Leaf", "leaf_width", { defaultValue: "0.04" }),
    ], [
      output("boundary_layer", "Leaf", "gb"),
    ], ["Hard dependency: called inside transpiration.run!, not scheduled as an independent soft node."], "hard_dependency", modelId("transpiration", "Leaf")),
    node("photosynthesis", "Leaf", "Farquhar", "hourly", [
      input("photosynthesis", "Leaf", "aPPFD", { defaultValue: "0.0" }),
      input("photosynthesis", "Leaf", "Tair", { mappingMode: "SingleNodeMapping", sourceScale: "Scene", sourceVariable: "Tair", defaultValue: "20.0" }),
      input("photosynthesis", "Leaf", "gs", { defaultValue: "0.0" }),
    ], [
      output("photosynthesis", "Leaf", "An"),
    ]),
    node("transpiration", "Leaf", "PenmanMonteith", "hourly", [
      input("transpiration", "Leaf", "gs", { defaultValue: "0.0" }),
      input("transpiration", "Leaf", "VPD", { mappingMode: "SingleNodeMapping", sourceScale: "Scene", sourceVariable: "VPD", defaultValue: "1.0" }),
      input("transpiration", "Leaf", "gb", { defaultValue: "0.0" }),
    ], [
      output("transpiration", "Leaf", "E"),
    ]),
    node("water_balance", "Plant", "SoilPlantWater", "daily", [
      input("water_balance", "Plant", "transpiration", { mappingMode: "MultiNodeMapping", sourceScale: "Leaf", sourceVariable: "E", defaultValue: "RefVector length 0" }),
      input("water_balance", "Plant", "soil_water", { defaultValue: "0.32" }),
    ], [
      output("water_balance", "Plant", "psi_leaf"),
    ]),
    node("growth", "Plant", "CarbonAllocation", "daily", [
      input("growth", "Plant", "assimilation", { mappingMode: "MultiNodeMapping", sourceScale: "Leaf", sourceVariable: "An", defaultValue: "RefVector length 0" }),
      input("growth", "Plant", "LAI", { defaultValue: "0.0" }),
    ], [
      output("growth", "Plant", "biomass"),
    ]),
  ],
  edges: [
    edge("meteo", "Scene", "PPFD", "light_interception", "Leaf", "PPFD", "mapped_variable", "multiscale", "PPFD"),
    edge("lai", "Plant", "LAI", "light_interception", "Leaf", "LAI", "mapped_variable", "multiscale", "LAI"),
    edge("light_interception", "Leaf", "aPPFD", "photosynthesis", "Leaf", "aPPFD", "soft_dependency", "same_scale", "aPPFD"),
    edge("meteo", "Scene", "Tair", "photosynthesis", "Leaf", "Tair", "mapped_variable", "multiscale", "Tair"),
    edge("meteo", "Scene", "VPD", "stomatal_conductance", "Leaf", "VPD", "mapped_variable", "multiscale", "VPD"),
    edge("stomatal_conductance", "Leaf", "gs", "photosynthesis", "Leaf", "gs", "soft_dependency", "same_scale", "gs"),
    edge("stomatal_conductance", "Leaf", "gs", "transpiration", "Leaf", "gs", "soft_dependency", "same_scale", "gs"),
    hardEdge("transpiration", "Leaf", "boundary_layer", "Leaf", "calls"),
    edge("meteo", "Scene", "VPD", "transpiration", "Leaf", "VPD", "mapped_variable", "multiscale", "VPD"),
    edge("transpiration", "Leaf", "E", "water_balance", "Plant", "transpiration", "mapped_variable", "multiscale", "E → transpiration"),
    edge("photosynthesis", "Leaf", "An", "growth", "Plant", "assimilation", "mapped_variable", "multiscale", "An → assimilation"),
    edge("lai", "Plant", "LAI", "growth", "Plant", "LAI", "soft_dependency", "same_scale", "LAI"),
  ],
  scales,
  cyclic: false,
  cycleNodes: [],
  diagnostics: [
    "Potential feedback stomatal_conductance.gs -> transpiration.E -> water_balance.psi_leaf -> stomatal_conductance.psi_leaf is opened with PreviousTimeStep.",
    "Potential feedback growth.biomass -> lai.biomass is opened with PreviousTimeStep.",
  ],
};

type PortOptions = {
  mappingMode?: string;
  sourceScale?: string;
  sourceVariable?: string;
  previousTimeStep?: boolean;
  defaultValue?: string;
};

function node(
  process: string,
  scale: string,
  modelType: string,
  rate: string,
  inputs: GraphPort[],
  outputs: GraphPort[],
  diagnostics: string[] = [],
  role: GraphNodeData["role"] = "model",
  parent: string | null = null,
): GraphNodeData {
  return {
    id: modelId(process, scale),
    process,
    scale,
    modelType,
    role,
    rate,
    inputs,
    outputs,
    parent,
    diagnostics,
  };
}

function input(process: string, scale: string, name: string, options: PortOptions = {}): GraphPort {
  return port(process, scale, name, "input", options);
}

function output(process: string, scale: string, name: string, options: PortOptions = {}): GraphPort {
  return port(process, scale, name, "output", { defaultValue: "Float64", ...options });
}

function port(process: string, scale: string, name: string, role: "input" | "output", options: PortOptions): GraphPort {
  return {
    id: portId(process, scale, role, name),
    name,
    role,
    mappingMode: options.mappingMode ?? null,
    sourceScale: options.sourceScale ?? null,
    sourceVariable: options.sourceVariable ?? null,
    previousTimeStep: options.previousTimeStep ?? false,
    default: options.defaultValue ?? "uninitialized",
  };
}

function edge(
  sourceProcess: string,
  sourceScale: string,
  sourceVariable: string,
  targetProcess: string,
  targetScale: string,
  targetVariable: string,
  kind: GraphEdgeData["kind"],
  scaleRelation: GraphEdgeData["scaleRelation"],
  label: string,
): GraphEdgeData {
  return {
    id: `edge:${sourceScale}:${sourceProcess}:${sourceVariable}->${targetScale}:${targetProcess}:${targetVariable}`,
    source: modelId(sourceProcess, sourceScale),
    target: modelId(targetProcess, targetScale),
    sourcePort: portId(sourceProcess, sourceScale, "output", sourceVariable),
    targetPort: portId(targetProcess, targetScale, "input", targetVariable),
    sourceVariable,
    targetVariable,
    kind,
    scaleRelation,
    label,
    diagnostics: [],
  };
}

function hardEdge(sourceProcess: string, sourceScale: string, targetProcess: string, targetScale: string, label: string): GraphEdgeData {
  return {
    id: `edge:hard:${sourceScale}:${sourceProcess}->${targetScale}:${targetProcess}`,
    source: modelId(sourceProcess, sourceScale),
    target: modelId(targetProcess, targetScale),
    sourcePort: null,
    targetPort: null,
    sourceVariable: null,
    targetVariable: null,
    kind: "hard_dependency",
    scaleRelation: sourceScale === targetScale ? "same_scale" : "multiscale",
    label,
    diagnostics: ["Hard dependency: target model is invoked manually by the caller."],
  };
}

function modelId(process: string, scale: string) {
  return `model:${scale}:${process}`;
}

function portId(process: string, scale: string, role: "input" | "output", variable: string) {
  return `${modelId(process, scale)}:${role}:${variable}`;
}

import type { DependencyGraphView } from "./types";

export const sampleGraph: DependencyGraphView = {
  nodes: [
    {
      id: "model:Default:lai",
      process: "lai",
      scale: "Default",
      modelType: "ToyLAIModel",
      role: "model",
      rate: "default rate",
      inputs: [{ id: "model:Default:lai:input:TT_cu", name: "TT_cu", role: "input", mappingMode: null, sourceScale: null, sourceVariable: null, previousTimeStep: false, default: "uninitialized" }],
      outputs: [{ id: "model:Default:lai:output:LAI", name: "LAI", role: "output", mappingMode: null, sourceScale: null, sourceVariable: null, previousTimeStep: false, default: "Float64" }],
      parent: null,
      diagnostics: [],
    },
    {
      id: "model:Default:light_interception",
      process: "light_interception",
      scale: "Default",
      modelType: "Beer",
      role: "model",
      rate: "default rate",
      inputs: [{ id: "model:Default:light_interception:input:LAI", name: "LAI", role: "input", mappingMode: null, sourceScale: null, sourceVariable: null, previousTimeStep: false, default: "uninitialized" }],
      outputs: [{ id: "model:Default:light_interception:output:aPPFD", name: "aPPFD", role: "output", mappingMode: null, sourceScale: null, sourceVariable: null, previousTimeStep: false, default: "Float64" }],
      parent: null,
      diagnostics: [],
    },
  ],
  edges: [
    {
      id: "edge:sample",
      source: "model:Default:lai",
      target: "model:Default:light_interception",
      sourcePort: "model:Default:lai:output:LAI",
      targetPort: "model:Default:light_interception:input:LAI",
      sourceVariable: "LAI",
      targetVariable: "LAI",
      kind: "soft_dependency",
      scaleRelation: "same_scale",
      label: "LAI",
      diagnostics: [],
    },
  ],
  scales: ["Default"],
  cyclic: false,
  cycleNodes: [],
  diagnostics: [],
};

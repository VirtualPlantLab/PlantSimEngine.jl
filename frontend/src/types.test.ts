import { describe, expect, it } from "vitest";
import type { ModelDescriptor } from "./types";

describe("ModelDescriptor authoring provenance", () => {
  it("accepts field-level nested provenance from Authoring.to_dict", () => {
    const descriptor: ModelDescriptor = {
      type: "FixtureModel",
      name: "FixtureModel",
      module: "Main",
      package: null,
      process: "fixture",
      processType: "AbstractFixtureModel",
      inputs: {},
      outputs: {},
      environmentInputs: {},
      environmentOutputs: {},
      provenance: "exact",
      fieldProvenance: {
        process: "declared",
        parameters: { values: "exact", metadata: "declared" },
        ports: { declarations: "declared", contracts: "declared" },
      },
      complete: true,
      diagnostics: [],
      constructor: {
        fields: [],
        parameterGroups: {},
        hasZeroArgConstructor: true,
        constructible: true,
      },
    };

    expect(descriptor.fieldProvenance?.parameters).toEqual({
      values: "exact",
      metadata: "declared",
    });
  });
});

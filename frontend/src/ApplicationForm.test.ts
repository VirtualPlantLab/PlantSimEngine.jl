import { describe, expect, it } from "vitest";
import { modelDescriptorForApplication } from "./ApplicationForm";
import type { ApplicationGraphNode, ModelDescriptor } from "./types";

describe("application model descriptors", () => {
  it("matches a concrete parametric application to its constructor type", () => {
    const descriptor = {
      type: "Beer",
      name: "Beer",
      module: "PlantSimEngine.Examples",
    } as ModelDescriptor;
    const application = {
      modelType: "Beer{Float64}",
      modelName: "Beer",
      module: "PlantSimEngine.Examples",
    } as ApplicationGraphNode;

    expect(modelDescriptorForApplication([descriptor], application)).toBe(descriptor);
  });
});

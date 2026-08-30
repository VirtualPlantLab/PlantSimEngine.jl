import { describe, expect, it } from "vitest";
import { applicationEnvironmentConfiguration, callBindingCommand } from "./ApplicationConfigurationForm";
import { bindingWindowDescriptor } from "./BindingForm";
import { unclaimedInstanceRoots } from "./InstanceForm";
import type { InstanceDescriptor, ObjectGraphNode } from "./types";

describe("schema-v2 graph editor payloads", () => {
  it("serializes temporal windows as Dates periods", () => {
    expect(bindingWindowDescriptor("3", "Hour")).toEqual({
      mode: "period",
      value: 3,
      unit: "Hour",
      julia: "Dates.Hour(3)",
    });
    expect(bindingWindowDescriptor("0", "Hour")).toBeNull();
    expect(bindingWindowDescriptor("1.5", "Hour")).toBeNull();
  });

  it("keeps environment backends as named catalog references", () => {
    expect(applicationEnvironmentConfiguration(
      "environment:canopy",
      " canopy_cells ",
      { T: " air_temperature ", RH: "" },
      " canopy_state ",
      [{ key: "layer", type: "integer", value: "2" }],
    )).toEqual({
      backendId: "environment:canopy",
      provider: "canopy_cells",
      sources: { T: "air_temperature" },
      sink: "canopy_state",
      extra: { layer: { type: "integer", value: "2" } },
    });
  });

  it("preserves initializer mode in call-binding commands", () => {
    const applicationRef = {
      scope: "global" as const,
      applicationId: "creator",
      instance: null,
      templateId: null,
    };
    const selector = {
      type: "One",
      multiplicity: "one" as const,
      criteria: { selectors: [], application: "leaf_state" },
      julia: "",
    };
    expect(callBindingCommand(
      applicationRef,
      "leaf",
      selector,
      "initializer",
    )).toEqual({
      action: "edit",
      kind: "set_call_binding",
      applicationRef,
      call: "leaf",
      selector,
      mode: "initializer",
    });
  });

  it("offers only objects not already claimed by an instance", () => {
    const objects = [object("plant_a"), object("leaf_a"), object("plant_b")];
    const instances = [{ objectIds: ["plant_a", "leaf_a"] }] as InstanceDescriptor[];
    expect(unclaimedInstanceRoots(objects, instances).map((item) => item.objectId)).toEqual(["plant_b"]);
  });
});

function object(id: string): ObjectGraphNode {
  return { id: `object:${id}`, objectId: id, scale: null, kind: null, species: null, name: id, instance: null, parent: null, children: [], hasGeometry: false, hasStatus: false };
}

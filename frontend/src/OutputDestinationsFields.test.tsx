import { describe, expect, it } from "vitest";
import { renderToStaticMarkup } from "react-dom/server";
import { OutputDestinationsFields, outputDestinationDrafts, outputDestinationsCommand } from "./OutputDestinationsFields";
import type { ApplicationGraphNode, ApplicationOwner, OutputDestinationDescriptor } from "./types";

const owner: ApplicationOwner = { scope: "global", applicationId: "light", instance: null, templateId: null };
const destination: OutputDestinationDescriptor = {
  selector: { type: "Many", multiplicity: "many", criteria: { scale: "Leaf", within: { type: "SceneScope" } }, julia: "Many(scale=:Leaf, within=SceneScope())" },
  vars: null,
  resolvedVars: ["x", "y"],
  origin: "inferred",
  coverage: "exact",
};

describe("distributed output destination editing", () => {
  it("preserves omission and explicit variable order in commands", () => {
    const inferred = outputDestinationsCommand(owner, outputDestinationDrafts([destination]), ["x", "y"]);
    expect(inferred.destinations[0].vars).toBeNull();
    expect(inferred.destinations[0].selector).toEqual(destination.selector);
    const explicit = outputDestinationsCommand(owner, outputDestinationDrafts([{ ...destination, vars: ["y", "x"], origin: "explicit" }]), ["x", "y"]);
    expect(explicit.destinations[0].vars).toEqual(["y", "x"]);
    expect(explicit.kind).toBe("set_output_destinations");
  });

  it("requires an explicit complete partition for several destinations", () => {
    const first = { ...outputDestinationDrafts([destination])[0], vars: "x" };
    const second = { ...first, vars: "y" };
    expect(outputDestinationsCommand(owner, [first, second], ["x", "y"]).destinations.map((entry) => entry.vars)).toEqual([["x"], ["y"]]);
    expect(() => outputDestinationsCommand(owner, [{ ...first, vars: null }, second], ["x", "y"])).toThrow("list the variables");
    expect(() => outputDestinationsCommand(owner, [second, { ...first, vars: null }], ["x", "y"])).toThrow("list the variables");
    expect(() => outputDestinationsCommand(owner, [first], ["x", "y"])).toThrow("Choose destinations for: y");
    expect(() => outputDestinationsCommand(owner, [first, first], ["x", "y"])).toThrow("bound more than once");
  });

  it("rejects empty, unknown and duplicate variables instead of inferring them", () => {
    const draft = outputDestinationDrafts([destination])[0];
    expect(() => outputDestinationsCommand(owner, [{ ...draft, vars: "" }], ["x"])).toThrow("at least one");
    expect(() => outputDestinationsCommand(owner, [{ ...draft, vars: "local_value" }], ["x"])).toThrow("not a distributed output");
    expect(() => outputDestinationsCommand(owner, [{ ...draft, vars: "x,x" }], ["x"])).toThrow("bound more than once");
    expect(() => outputDestinationsCommand(owner, [draft], [])).toThrow("at least one");
  });

  it("renders the shorthand and destination selection without a group-name field", () => {
    const application = {
      applicationId: "light", owner, outputsTo: [destination],
      outputs: [{ name: "x", storage: "distributed" }, { name: "local_value", storage: "local" }],
    } as ApplicationGraphNode;
    const markup = renderToStaticMarkup(<OutputDestinationsFields application={application} onCommand={() => {}} />);
    expect(markup).toContain("Distributed outputs: x");
    expect(markup).toContain("All distributed outputs (single destination)");
    expect(markup).toContain("Many(scale=:Leaf, within=SceneScope())");
    expect(markup).not.toContain("local_value");
    expect(markup).not.toContain("group");
  });
});

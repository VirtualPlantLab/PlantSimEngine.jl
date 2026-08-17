import { describe, expect, it } from "vitest";
import { applicationInputPorts, applicationOutputPorts } from "./layout";
import type { GraphPort, RuntimeApplicationNode } from "./types";

describe("application layout ports", () => {
  it("includes model and environment ports in ELK order", () => {
    const modelInput = port("input", "signal");
    const environmentInput = port("environment_input", "temperature");
    const modelOutput = port("output", "result");
    const environmentOutput = port("environment_output", "canopy_temperature");
    const application = {
      inputs: [modelInput],
      environmentInputs: [environmentInput],
      outputs: [modelOutput],
      environmentOutputs: [environmentOutput],
    } as RuntimeApplicationNode;

    expect(applicationInputPorts(application)).toEqual([modelInput, environmentInput]);
    expect(applicationOutputPorts(application)).toEqual([modelOutput, environmentOutput]);
  });
});

function port(role: GraphPort["role"], name: string): GraphPort {
  return {
    id: `application:test:${role}:${name}`,
    name,
    role,
    default: null,
    defaultJulia: "nothing",
    expectedType: "Any",
  };
}

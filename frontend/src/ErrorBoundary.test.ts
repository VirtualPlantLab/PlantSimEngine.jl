import { describe, expect, it } from "vitest";
import { ErrorBoundary } from "./ErrorBoundary";

describe("ErrorBoundary", () => {
  it("captures a rendering error as recoverable state", () => {
    const error = new Error("panel failed");
    expect(ErrorBoundary.getDerivedStateFromError(error)).toEqual({ error });
  });
});

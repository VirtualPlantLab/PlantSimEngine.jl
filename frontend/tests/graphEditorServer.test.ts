import { afterEach, describe, expect, it, vi } from "vitest";
import { stopProcess, type StoppableProcess } from "../e2e/graphEditorServer";

describe("graph editor server teardown", () => {
  afterEach(() => {
    vi.useRealTimers();
  });

  it("forces termination when the process ignores SIGTERM", async () => {
    vi.useFakeTimers();
    const proc = new FakeProcess();

    const stopped = stopProcess(proc, 100);
    expect(proc.signals).toEqual(["SIGTERM"]);

    await vi.advanceTimersByTimeAsync(100);
    await stopped;

    expect(proc.signals).toEqual(["SIGTERM", "SIGKILL"]);
    expect(proc.signalCode).toBe("SIGKILL");
  });

  it("cancels forced termination after a graceful exit", async () => {
    vi.useFakeTimers();
    const proc = new FakeProcess();

    const stopped = stopProcess(proc, 100);
    proc.exit(0, null);
    await stopped;
    await vi.advanceTimersByTimeAsync(100);

    expect(proc.signals).toEqual(["SIGTERM"]);
  });

  it("does not signal a process that has already exited", async () => {
    const proc = new FakeProcess();
    proc.exitCode = 0;

    await stopProcess(proc);

    expect(proc.signals).toEqual([]);
  });
});

class FakeProcess implements StoppableProcess {
  exitCode: number | null = null;
  signalCode: NodeJS.Signals | null = null;
  readonly signals: Array<NodeJS.Signals | number> = [];
  private exitListener?: (code: number | null, signal: NodeJS.Signals | null) => void;

  once(
    event: "exit",
    listener: (code: number | null, signal: NodeJS.Signals | null) => void,
  ): this {
    expect(event).toBe("exit");
    this.exitListener = listener;
    return this;
  }

  kill(signal: NodeJS.Signals | number = "SIGTERM"): boolean {
    this.signals.push(signal);
    if (signal === "SIGKILL") this.exit(null, "SIGKILL");
    return true;
  }

  exit(code: number | null, signal: NodeJS.Signals | null): void {
    this.exitCode = code;
    this.signalCode = signal;
    this.exitListener?.(code, signal);
  }
}

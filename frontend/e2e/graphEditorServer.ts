import { spawn, type ChildProcessWithoutNullStreams } from "node:child_process";
import path from "node:path";
import { fileURLToPath } from "node:url";

const dirname = path.dirname(fileURLToPath(import.meta.url));
const repoRoot = path.resolve(dirname, "../..");
const serverScript = path.join(repoRoot, "test", "fixtures", "graph_editor_e2e_server.jl");

export type GraphEditorServer = {
  url: string;
  stop: () => Promise<void>;
};

export async function startGraphEditorServer(): Promise<GraphEditorServer> {
  if (process.env.PSE_GRAPH_EDITOR_URL) {
    return {
      url: process.env.PSE_GRAPH_EDITOR_URL,
      stop: async () => {},
    };
  }

  const proc = spawn("julia", ["--project=test", "--startup-file=no", serverScript], {
    cwd: repoRoot,
    env: { ...process.env, JULIA_NUM_THREADS: process.env.JULIA_NUM_THREADS ?? "2" },
  });

  let log = "";
  const url = await new Promise<string>((resolve, reject) => {
    let settled = false;
    let timeout: ReturnType<typeof setTimeout>;

    const consume = (chunk: Buffer) => {
      if (settled) return;
      log += chunk.toString();
      const match = log.match(/PSE_GRAPH_EDITOR_URL=(http:\/\/127\.0\.0\.1:\d+[^\s]*)/);
      if (match) {
        settled = true;
        clearTimeout(timeout);
        resolve(match[1]);
      }
    };

    const fail = (error: Error) => {
      if (settled) return;
      settled = true;
      clearTimeout(timeout);
      void stopProcess(proc).finally(() => reject(error));
    };

    timeout = setTimeout(() => {
      fail(new Error(`Timed out waiting for graph editor URL.\n${log}`));
    }, 90_000);

    proc.stdout.on("data", consume);
    proc.stderr.on("data", consume);
    proc.once("exit", (code, signal) => {
      fail(new Error(`Graph editor process exited before startup: code=${code} signal=${signal}\n${log}`));
    });
    proc.once("error", (error) => {
      fail(error);
    });
  });

  return {
    url,
    stop: () => stopProcess(proc),
  };
}

function stopProcess(proc: ChildProcessWithoutNullStreams): Promise<void> {
  if (proc.killed || proc.exitCode !== null) return Promise.resolve();
  return new Promise((resolve) => {
    const killTimer = setTimeout(() => {
      if (!proc.killed && proc.exitCode === null) proc.kill("SIGKILL");
    }, 3_000);
    proc.once("exit", () => {
      clearTimeout(killTimer);
      resolve();
    });
    proc.kill("SIGTERM");
  });
}

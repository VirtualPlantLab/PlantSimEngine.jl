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
  const proc = spawn("julia", ["--project=test", "--startup-file=no", serverScript], {
    cwd: repoRoot,
    env: { ...process.env, JULIA_NUM_THREADS: process.env.JULIA_NUM_THREADS ?? "2" },
  });

  let log = "";
  const url = await new Promise<string>((resolve, reject) => {
    const timeout = setTimeout(() => {
      reject(new Error(`Timed out waiting for graph editor URL.\n${log}`));
    }, 45_000);

    const consume = (chunk: Buffer) => {
      log += chunk.toString();
      const match = log.match(/PSE_GRAPH_EDITOR_URL=(http:\/\/127\.0\.0\.1:\d+)/);
      if (match) {
        clearTimeout(timeout);
        resolve(match[1]);
      }
    };

    proc.stdout.on("data", consume);
    proc.stderr.on("data", consume);
    proc.once("exit", (code, signal) => {
      clearTimeout(timeout);
      reject(new Error(`Graph editor process exited before startup: code=${code} signal=${signal}\n${log}`));
    });
    proc.once("error", (error) => {
      clearTimeout(timeout);
      reject(error);
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

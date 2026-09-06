import type { RuntimeApplicationNode } from "./types";

export function nodeWidth(node: RuntimeApplicationNode) {
  if (node.detailMode === "overview") return 190;
  const longest = Math.max(
    node.applicationId.length,
    node.modelName.length,
    ...node.inputs.map((port) => port.name.length),
    ...node.outputs.map((port) => port.name.length),
  );
  return Math.max(310, Math.min(540, 235 + longest * 7));
}

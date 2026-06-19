import ELK from "elkjs/lib/elk.bundled.js";
import type { Edge, Node } from "@xyflow/react";
import type { RuntimeApplicationNode, RuntimeEntityNode, SceneGraphEdge } from "./types";
import { nodeWidth } from "./nodeSizing";

const elk = new ELK();
export type LayoutMode = "data_flow" | "compact" | "overview" | "topology";
type RuntimeNode = RuntimeApplicationNode | RuntimeEntityNode;

export async function layoutGraph(nodes: Node<RuntimeNode>[], edges: Edge<SceneGraphEdge>[], mode: LayoutMode) {
  const graph = {
    id: "root",
    layoutOptions: options(mode),
    children: nodes.map((node) => ({
      id: node.id,
      width: width(node.data),
      height: height(node.data),
      ports: node.data.nodeKind === "application" ? [
        ...node.data.inputs.map((port, index) => portDescriptor(port.id, "WEST", index)),
        ...node.data.outputs.map((port, index) => portDescriptor(port.id, "EAST", index)),
      ] : [
        ...(node.data.inputPortIds ?? []).map((id, index) => portDescriptor(id, "WEST", index)),
        ...(node.data.outputPortIds ?? []).map((id, index) => portDescriptor(id, "EAST", index)),
      ],
      layoutOptions: { "org.eclipse.elk.portConstraints": "FIXED_ORDER" },
    })),
    edges: edges.map((edge) => ({
      id: edge.id,
      sources: [edge.sourceHandle ?? edge.source],
      targets: [edge.targetHandle ?? edge.target],
    })),
  };
  const result = await elk.layout(graph);
  const positions = new Map((result.children ?? []).map((child) => [child.id, { x: child.x ?? 0, y: child.y ?? 0 }]));
  return nodes.map((node) => ({ ...node, position: positions.get(node.id) ?? node.position }));
}

function options(mode: LayoutMode): Record<string, string> {
  return {
    "elk.algorithm": mode === "topology" ? "mrtree" : "layered",
    "elk.direction": mode === "topology" ? "DOWN" : "RIGHT",
    "elk.spacing.nodeNode": mode === "overview" ? "24" : mode === "compact" ? "32" : "56",
    "elk.layered.spacing.nodeNodeBetweenLayers": mode === "overview" ? "48" : mode === "compact" ? "60" : "110",
    "elk.layered.nodePlacement.strategy": "BRANDES_KOEPF",
    "elk.layered.crossingMinimization.semiInteractive": "true",
    "elk.edgeRouting": "ORTHOGONAL",
  };
}

function portDescriptor(id: string, side: "WEST" | "EAST", index: number) {
  return {
    id,
    width: 9,
    height: 9,
    layoutOptions: {
      "org.eclipse.elk.port.side": side,
      "org.eclipse.elk.port.index": String(index),
    },
  };
}

function width(data: RuntimeNode) {
  return data.nodeKind === "application" ? nodeWidth(data) : 240;
}

function height(data: RuntimeNode) {
  if (data.nodeKind !== "application") return 112;
  if (data.detailMode === "overview") return 108;
  return Math.max(178, 142 + Math.max(data.inputs.length, data.outputs.length) * 27);
}

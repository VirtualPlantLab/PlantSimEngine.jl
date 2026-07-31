import ELK from "elkjs/lib/elk.bundled.js";
import type { Edge, Node } from "@xyflow/react";
import type { RuntimeApplicationNode, RuntimeEntityNode, ModelGraphEdge } from "./types";
import { nodeWidth } from "./nodeSizing";

const elk = new ELK();
export type LayoutMode = "data_flow" | "compact" | "overview" | "topology";
type RuntimeNode = RuntimeApplicationNode | RuntimeEntityNode;

export async function layoutGraph(nodes: Node<RuntimeNode>[], edges: Edge<ModelGraphEdge>[], mode: LayoutMode) {
  const graph = {
    id: "root",
    layoutOptions: options(mode),
    children: nodes.map((node) => ({
      id: node.id,
      width: width(node.data),
      height: height(node.data),
      ports: node.data.nodeKind === "application" ? [
        ...applicationInputPorts(node.data).map((port, index) => portDescriptor(port.id, "WEST", index)),
        ...applicationOutputPorts(node.data).map((port, index) => portDescriptor(port.id, "EAST", index)),
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
  const modelPortRows = Math.max(data.inputs.length, data.outputs.length);
  const environmentPortRows = Math.max(data.environmentInputs.length, data.environmentOutputs.length);
  return Math.max(178, 142 + modelPortRows * 27 + (environmentPortRows > 0 ? 32 + environmentPortRows * 27 : 0));
}

export function applicationInputPorts(data: RuntimeApplicationNode) {
  return [...data.inputs, ...data.environmentInputs];
}

export function applicationOutputPorts(data: RuntimeApplicationNode) {
  return [...data.outputs, ...data.environmentOutputs];
}

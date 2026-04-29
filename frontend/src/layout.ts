import ELK from "elkjs/lib/elk.bundled.js";
import type { Edge, Node } from "@xyflow/react";
import type { GraphEdgeData, GraphPort, RuntimeGraphNodeData } from "./types";

const elk = new ELK();
const NODE_WIDTH = 312;

export async function layoutGraph(nodes: Node<RuntimeGraphNodeData>[], edges: Edge<GraphEdgeData>[]) {
  const graph = {
    id: "root",
    layoutOptions: {
      "elk.algorithm": "layered",
      "elk.direction": "RIGHT",
      "elk.spacing.nodeNode": "58",
      "elk.layered.spacing.nodeNodeBetweenLayers": "110",
      "elk.layered.nodePlacement.strategy": "BRANDES_KOEPF",
      "elk.layered.crossingMinimization.semiInteractive": "true",
      "elk.edgeRouting": "ORTHOGONAL",
    },
    children: nodes.map((node) => ({
      id: node.id,
      width: NODE_WIDTH,
      height: nodeHeight(node.data),
      ports: [...node.data.inputs.map((port, index) => elkPort(port, index)), ...node.data.outputs.map((port, index) => elkPort(port, index))],
      layoutOptions: {
        "org.eclipse.elk.portConstraints": "FIXED_ORDER",
      },
    })),
    edges: edges.map((edge) => ({
      id: edge.id,
      sources: [edge.sourceHandle ?? edge.source],
      targets: [edge.targetHandle ?? edge.target],
    })),
  };

  const result = await elk.layout(graph);
  const positions = new Map((result.children ?? []).map((child) => [child.id, { x: child.x ?? 0, y: child.y ?? 0 }]));

  return nodes.map((node) => ({
    ...node,
    position: positions.get(node.id) ?? node.position,
  }));
}

function nodeHeight(node: RuntimeGraphNodeData) {
  return Math.max(160, 112 + Math.max(node.inputs.length, node.outputs.length) * 28);
}

function elkPort(port: GraphPort, index: number) {
  return {
    id: port.id,
    width: 9,
    height: 9,
    layoutOptions: {
      "org.eclipse.elk.port.side": port.role === "input" ? "WEST" : "EAST",
      "org.eclipse.elk.port.index": String(index),
    },
  };
}

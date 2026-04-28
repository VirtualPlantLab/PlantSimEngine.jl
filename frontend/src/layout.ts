import ELK from "elkjs/lib/elk.bundled.js";
import type { Edge, Node } from "@xyflow/react";
import type { GraphEdgeData, GraphNodeData } from "./types";

const elk = new ELK();

export async function layoutGraph(nodes: Node<GraphNodeData>[], edges: Edge<GraphEdgeData>[]) {
  const graph = {
    id: "root",
    layoutOptions: {
      "elk.algorithm": "layered",
      "elk.direction": "RIGHT",
      "elk.spacing.nodeNode": "58",
      "elk.layered.spacing.nodeNodeBetweenLayers": "110",
      "elk.layered.nodePlacement.strategy": "BRANDES_KOEPF",
      "elk.edgeRouting": "ORTHOGONAL",
    },
    children: nodes.map((node) => ({
      id: node.id,
      width: 312,
      height: Math.max(160, 112 + Math.max(node.data.inputs.length, node.data.outputs.length) * 28),
    })),
    edges: edges.map((edge) => ({
      id: edge.id,
      sources: [edge.source],
      targets: [edge.target],
    })),
  };

  const result = await elk.layout(graph);
  const positions = new Map((result.children ?? []).map((child) => [child.id, { x: child.x ?? 0, y: child.y ?? 0 }]));

  return nodes.map((node) => ({
    ...node,
    position: positions.get(node.id) ?? node.position,
  }));
}

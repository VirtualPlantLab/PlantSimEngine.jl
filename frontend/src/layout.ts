import ELK from "elkjs/lib/elk.bundled.js";
import type { Edge, Node } from "@xyflow/react";
import type { GraphEdgeData, GraphPort, RuntimeGraphNodeData } from "./types";
import { nodeWidth } from "./nodeSizing";

const elk = new ELK();
export type LayoutMode = "data_flow" | "compact" | "scale_grouped" | "call_stack";

export async function layoutGraph(nodes: Node<RuntimeGraphNodeData>[], edges: Edge<GraphEdgeData>[], mode: LayoutMode = "data_flow") {
  const layoutEdges = mode === "call_stack" ? edges.filter((edge) => isCallEdge(edge.data)) : edges;
  const graph = {
    id: "root",
    layoutOptions: layoutOptions(mode),
    children: nodes.map((node) => ({
      id: node.id,
      width: nodeWidth(node.data),
      height: nodeHeight(node.data),
      ports: [
        elkCallPort(node.id, "target"),
        ...node.data.inputs.map((port, index) => elkPort(port, index)),
        ...node.data.outputs.map((port, index) => elkPort(port, index)),
        elkCallPort(node.id, "source"),
      ],
      layoutOptions: {
        "org.eclipse.elk.portConstraints": "FIXED_ORDER",
      },
    })),
    edges: layoutEdges.map((edge) => ({
      id: edge.id,
      sources: [edge.sourceHandle ?? edge.source],
      targets: [edge.targetHandle ?? edge.target],
    })),
  };

  const result = await elk.layout(graph);
  const positions = new Map((result.children ?? []).map((child) => [child.id, { x: child.x ?? 0, y: child.y ?? 0 }]));
  const scaleOffsets = mode === "scale_grouped" ? scaleBandOffsets(nodes) : new Map<string, number>();

  return nodes.map((node) => {
    const position = positions.get(node.id) ?? node.position;
    return {
      ...node,
      position: {
        x: position.x,
        y: position.y + (scaleOffsets.get(node.data.scale) ?? 0),
      },
    };
  });
}

function layoutOptions(mode: LayoutMode): Record<string, string> {
  if (mode === "compact") {
    return {
      "elk.algorithm": "layered",
      "elk.direction": "RIGHT",
      "elk.spacing.nodeNode": "28",
      "elk.layered.spacing.nodeNodeBetweenLayers": "52",
      "elk.layered.nodePlacement.strategy": "BRANDES_KOEPF",
      "elk.layered.crossingMinimization.semiInteractive": "true",
      "elk.edgeRouting": "ORTHOGONAL",
    };
  }

  if (mode === "call_stack") {
    return {
      "elk.algorithm": "layered",
      "elk.direction": "DOWN",
      "elk.spacing.nodeNode": "46",
      "elk.layered.spacing.nodeNodeBetweenLayers": "76",
      "elk.layered.nodePlacement.strategy": "NETWORK_SIMPLEX",
      "elk.edgeRouting": "ORTHOGONAL",
    };
  }

  return {
    "elk.algorithm": "layered",
    "elk.direction": "RIGHT",
    "elk.spacing.nodeNode": mode === "scale_grouped" ? "72" : "58",
    "elk.layered.spacing.nodeNodeBetweenLayers": mode === "scale_grouped" ? "130" : "110",
    "elk.layered.nodePlacement.strategy": "BRANDES_KOEPF",
    "elk.layered.crossingMinimization.semiInteractive": "true",
    "elk.edgeRouting": "ORTHOGONAL",
  };
}

function scaleBandOffsets(nodes: Node<RuntimeGraphNodeData>[]) {
  const scales = [...new Set(nodes.map((node) => node.data.scale))].sort();
  return new Map(scales.map((scale, index) => [scale, index * 260]));
}

function isCallEdge(edge?: GraphEdgeData) {
  return edge?.kind === "hard_dependency" && !edge.sourcePort && !edge.targetPort;
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

function elkCallPort(nodeId: string, role: "source" | "target") {
  return {
    id: `${nodeId}:call-${role}`,
    width: 12,
    height: 36,
    layoutOptions: {
      "org.eclipse.elk.port.side": role === "target" ? "WEST" : "EAST",
      "org.eclipse.elk.port.index": role === "target" ? "-1" : "9999",
    },
  };
}

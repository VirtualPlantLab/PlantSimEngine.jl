import { BaseEdge, EdgeLabelRenderer, Position, getSmoothStepPath, type Edge, type EdgeProps } from "@xyflow/react";
import type { ModelGraphEdge } from "./types";

type SceneFlowEdge = Edge<ModelGraphEdge, "sceneEdge">;

export function DependencyEdge({
  id,
  sourceX,
  sourceY,
  targetX,
  targetY,
  sourcePosition = Position.Right,
  targetPosition = Position.Left,
  markerEnd,
  style,
  data,
}: EdgeProps<SceneFlowEdge>) {
  const [path, labelX, labelY] = getSmoothStepPath({
    sourceX,
    sourceY,
    targetX,
    targetY,
    sourcePosition,
    targetPosition,
    borderRadius: 14,
    offset: 24,
  });
  const label = edgeLabel(data);
  return (
    <>
      <BaseEdge id={id} path={path} markerEnd={markerEnd} style={style} interactionWidth={18} />
      {label && (
        <EdgeLabelRenderer>
          <div
            className={`edge-chip ${data?.kind ?? ""} ${data?.cycle ? "cycle" : ""}`}
            style={{ transform: `translate(-50%, -50%) translate(${labelX}px, ${labelY - 12}px)` }}
          >
            {label}
          </div>
        </EdgeLabelRenderer>
      )}
    </>
  );
}

function edgeLabel(data?: ModelGraphEdge) {
  if (!data) return "";
  if (data.kind === "manual_call") return data.call || "call";
  if (data.kind === "object_topology" || data.kind === "application_target") return "";
  if (data.sourceVariable && data.targetVariable) {
    return data.sourceVariable === data.targetVariable ? data.sourceVariable : `${data.sourceVariable} → ${data.targetVariable}`;
  }
  return data.kind.replaceAll("_", " ");
}

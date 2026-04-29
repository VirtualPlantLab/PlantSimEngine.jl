import {
  BaseEdge,
  EdgeLabelRenderer,
  Position,
  getSmoothStepPath,
  type Edge,
  type EdgeProps,
} from "@xyflow/react";
import type { GraphEdgeData } from "./types";

type DependencyFlowEdge = Edge<GraphEdgeData, "dependency">;

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
}: EdgeProps<DependencyFlowEdge>) {
  const [path, labelX, labelY] = getSmoothStepPath({
    sourceX,
    sourceY,
    sourcePosition,
    targetX,
    targetY,
    targetPosition,
    borderRadius: 18,
    offset: 28,
  });

  const label = data?.label;
  const renamed = data?.sourceVariable && data?.targetVariable && data.sourceVariable !== data.targetVariable;
  const showPrimaryLabel = Boolean(label) && !renamed;
  const showScaleTag = data?.scaleRelation === "multiscale";
  const showChip = showPrimaryLabel || showScaleTag;
  const highlighted = Boolean(data?.highlighted);
  const dimmed = Boolean(data?.dimmed);

  return (
    <>
      <BaseEdge id={id} path={path} markerEnd={markerEnd} style={style} interactionWidth={18} />
      {showChip && (
        <EdgeLabelRenderer>
          <EdgeTerminal
            className={`edge-terminal source ${data.kind} ${data.scaleRelation} ${highlighted ? "highlighted" : ""} ${dimmed ? "dimmed" : ""}`}
            x={sourceX}
            y={sourceY}
            side={sourcePosition}
            color={terminalColor(data, highlighted)}
          />
          <EdgeTerminal
            className={`edge-terminal target ${data.kind} ${data.scaleRelation} ${highlighted ? "highlighted" : ""} ${dimmed ? "dimmed" : ""}`}
            x={targetX}
            y={targetY}
            side={targetPosition}
            color={terminalColor(data, highlighted)}
          />
          <div
            className={`edge-chip ${data.kind} ${data.scaleRelation} ${highlighted ? "highlighted" : ""} ${dimmed ? "dimmed" : ""}`}
            style={{
              transform: `translate(-50%, -50%) translate(${labelX}px, ${labelY - 14}px)`,
            }}
          >
            {showPrimaryLabel && <span>{label}</span>}
            {showScaleTag && <small>multiscale</small>}
          </div>
        </EdgeLabelRenderer>
      )}
    </>
  );
}

function EdgeTerminal({ className, x, y, side, color }: { className: string; x: number; y: number; side: Position; color: string }) {
  const xOffset =
    className.includes("target")
      ? side === Position.Left
        ? -9
        : 9
      : side === Position.Left
        ? 9
        : -9;

  return (
    <div
      className={className}
      data-side={side}
      style={{
        transform: `translate(-50%, -50%) translate(${x + xOffset}px, ${y}px)`,
        ["--terminal-color" as string]: color,
      }}
    />
  );
}

function terminalColor(data: GraphEdgeData, highlighted: boolean) {
  if (highlighted) return "#1f7a53";
  if (data.kind === "hard_dependency") return "#bf6a54";
  if (data.kind === "mapped_variable" || data.scaleRelation === "multiscale") return "#1f7a53";
  return "#b7a696";
}

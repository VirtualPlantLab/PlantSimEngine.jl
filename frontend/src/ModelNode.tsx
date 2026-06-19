import { Handle, Position, type Node, type NodeProps } from "@xyflow/react";
import { Box, Clock3, Layers3, Plus, Scissors } from "lucide-react";
import type { GraphPort, RuntimeApplicationNode, RuntimeEntityNode } from "./types";
import { nodeWidth } from "./nodeSizing";

type ApplicationFlowNode = Node<RuntimeApplicationNode, "application">;
type EntityFlowNode = Node<RuntimeEntityNode, "entity">;

export function ApplicationNode({ data, selected }: NodeProps<ApplicationFlowNode>) {
  const overview = data.detailMode === "overview";
  const required = new Set(data.requiredInputPortIds);
  const candidates = new Set(data.candidatePortIds);
  const previous = new Set(data.previousTimeStepPortIds);
  const cycleBreaks = new Set(data.cycleBreakInputPortIds);
  const scope = scopeLabel(data);

  return (
    <section
      className={`model-node application-node ${overview ? "overview-node" : ""} ${data.cyclic ? "cyclic" : ""} ${selected ? "selected" : ""}`}
      data-testid={`application-node-${data.applicationId}`}
      style={{ width: nodeWidth(data) }}
    >
      {overview && <OverviewHandles inputs={data.inputs} outputs={data.outputs} />}
      <header className="node-header">
        <div>
          <div className="process">{data.name || data.applicationId}</div>
          <div className="model-type">{data.modelName}</div>
        </div>
        <Layers3 size={18} />
      </header>
      {overview ? (
        <div className="overview-node-summary">
          <span>{data.targetCount} targets</span>
          <span>{data.inputs.length} in</span>
          <span>{data.outputs.length} out</span>
        </div>
      ) : (
        <>
          <div className="node-meta">
            <span className="meta-chip" title={data.selector.julia}>
              <Box size={13} /> {scope}
            </span>
            <span className="meta-chip" title={String(data.clock ?? "Default scene cadence")}>
              <Clock3 size={13} /> {rateLabel(data)}
            </span>
          </div>
          <div className="target-summary">
            <strong>{data.targetCount}</strong> concrete target{data.targetCount === 1 ? "" : "s"}
          </div>
          <div className="ports-grid">
            <PortColumn
              title="Inputs"
              side="input"
              ports={data.inputs}
              required={required}
              candidates={candidates}
              previous={previous}
              cycleBreaks={cycleBreaks}
              cycleBreakMode={data.cycleBreakMode}
              application={data}
              onCandidateClick={data.onCandidateClick}
              onPortClick={data.onPortClick}
              onCycleBreak={data.onCycleBreak}
            />
            <PortColumn
              title="Outputs"
              side="output"
              ports={data.outputs}
              required={required}
              candidates={candidates}
              previous={previous}
              cycleBreaks={cycleBreaks}
              cycleBreakMode={data.cycleBreakMode}
              application={data}
              onCandidateClick={data.onCandidateClick}
              onPortClick={data.onPortClick}
              onCycleBreak={data.onCycleBreak}
            />
          </div>
        </>
      )}
    </section>
  );
}

export function EntityNode({ data, selected }: NodeProps<EntityFlowNode>) {
  return (
    <section className={`entity-node ${data.nodeKind} ${selected ? "selected" : ""}`} data-testid={`${data.nodeKind}-node`}>
      {(data.inputPortIds?.length ? data.inputPortIds : [undefined]).map((id, index) => (
        <Handle key={id ?? "target"} id={id} type="target" position={Position.Left} style={{ top: `${handlePosition(index, data.inputPortIds?.length ?? 1)}%` }} />
      ))}
      <header>
        <strong>{data.title}</strong>
        <span>{data.subtitle}</span>
      </header>
      <div className="badges">
        {data.badges.map((badge) => <span className="meta-chip" key={badge}>{badge}</span>)}
      </div>
      {(data.outputPortIds?.length ? data.outputPortIds : [undefined]).map((id, index) => (
        <Handle key={id ?? "source"} id={id} type="source" position={Position.Right} style={{ top: `${handlePosition(index, data.outputPortIds?.length ?? 1)}%` }} />
      ))}
    </section>
  );
}

function PortColumn({
  title,
  side,
  ports,
  required,
  candidates,
  previous,
  cycleBreaks,
  cycleBreakMode,
  application,
  onCandidateClick,
  onPortClick,
  onCycleBreak,
}: {
  title: string;
  side: "input" | "output";
  ports: GraphPort[];
  required: Set<string>;
  candidates: Set<string>;
  previous: Set<string>;
  cycleBreaks: Set<string>;
  cycleBreakMode: boolean;
  application: RuntimeApplicationNode;
  onCandidateClick?: RuntimeApplicationNode["onCandidateClick"];
  onPortClick?: RuntimeApplicationNode["onPortClick"];
  onCycleBreak?: RuntimeApplicationNode["onCycleBreak"];
}) {
  return (
    <div className={`port-column ${side}`}>
      <div className="port-title">{title}</div>
      {ports.map((port) => (
        <div
          className={`port ${required.has(port.id) ? "required-input" : ""} ${previous.has(port.id) ? "previous" : ""}`}
          key={port.id}
          data-testid={`port-${side}-${port.name}`}
          title={`${port.name}: ${port.defaultJulia}`}
          onClick={(event) => {
            event.stopPropagation();
            onPortClick?.(port);
          }}
        >
          {side === "input" && <Handle id={port.id} type="target" position={Position.Left} />}
          <span>{port.name}</span>
          {candidates.has(port.id) && (
            <button
              className="port-candidate-button nodrag nopan"
              type="button"
              title={side === "input" ? "Models that compute this variable" : "Models that consume this variable"}
              aria-label={side === "input" ? `Models that compute ${port.name}` : `Models that consume ${port.name}`}
              onClick={(event) => {
                event.stopPropagation();
                const rect = event.currentTarget.getBoundingClientRect();
                onCandidateClick?.(port, { x: rect.right, y: rect.top + rect.height / 2 });
              }}
            >
              <Plus size={11} />
            </button>
          )}
          {side === "input" && cycleBreakMode && cycleBreaks.has(port.id) && (
            <button
              className="cycle-port-break nodrag nopan"
              type="button"
              title={`Read ${port.name} from the previous accepted timestep`}
              aria-label={`Break cycle at ${application.applicationId}.${port.name}`}
              data-testid={`cycle-break-${application.applicationId}-${port.name}`}
              onClick={(event) => {
                event.stopPropagation();
                onCycleBreak?.(application, port);
              }}
            >
              <Scissors size={12} />
            </button>
          )}
          {previous.has(port.id) && <small className="previous-label">t-1</small>}
          {side === "output" && <Handle id={port.id} type="source" position={Position.Right} />}
        </div>
      ))}
    </div>
  );
}

function OverviewHandles({ inputs, outputs }: { inputs: GraphPort[]; outputs: GraphPort[] }) {
  return (
    <>
      {inputs.map((port, index) => (
        <Handle key={port.id} id={port.id} type="target" position={Position.Left} style={{ top: `${handlePosition(index, inputs.length)}%` }} />
      ))}
      {outputs.map((port, index) => (
        <Handle key={port.id} id={port.id} type="source" position={Position.Right} style={{ top: `${handlePosition(index, outputs.length)}%` }} />
      ))}
    </>
  );
}

function handlePosition(index: number, total: number) {
  return total <= 1 ? 52 : 28 + (index / (total - 1)) * 48;
}

function scopeLabel(data: RuntimeApplicationNode) {
  const labels = [...data.targetInstances, ...data.targetScales, ...data.targetKinds];
  return labels.length > 0 ? labels.slice(0, 2).join(" / ") : data.selector.type;
}

function rateLabel(data: RuntimeApplicationNode) {
  if (data.timestep === null || data.timestep === undefined) return "default rate";
  return String(data.timestep);
}

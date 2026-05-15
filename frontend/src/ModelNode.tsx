import { Handle, Position, type Node, type NodeProps } from "@xyflow/react";
import { Clock3, GitBranch, Layers3, Link2, PhoneCall, Plus, ScissorsLineDashed, Trash2 } from "lucide-react";
import type { GraphPort, RuntimeGraphNodeData } from "./types";
import { nodeWidth } from "./nodeSizing";

type ModelFlowNode = Node<RuntimeGraphNodeData, "model">;

export function ModelNode({ data, selected }: NodeProps<ModelFlowNode>) {
  const cyclic = Boolean(data.cyclic);
  const dimmed = Boolean(data.dimmed);
  const focused = Boolean(data.focused);
  const overview = data.viewMode === "overview";
  return (
    <section
      className={`model-node ${data.role} ${overview ? "overview-node" : ""} ${cyclic ? "cyclic" : ""} ${selected ? "selected" : ""} ${focused ? "focused" : ""} ${dimmed ? "dimmed" : ""}`}
      data-scale={data.scale}
      data-testid={`model-node-${data.scale}-${data.process}`}
      style={{ width: nodeWidth(data) }}
    >
      <Handle className="call-handle call-target" id={`${data.id}:call-target`} type="target" position={Position.Left} />
      <Handle className="call-handle call-source" id={`${data.id}:call-source`} type="source" position={Position.Right} />
      {overview && <OverviewPortHandles inputs={data.inputs} outputs={data.outputs} />}
      {selected && data.onRemoveModel && (
        <button
          className="model-remove-button nodrag nopan"
          type="button"
          title={data.role === "hard_dependency" ? `Remove owning model for ${data.process}` : `Remove ${data.process}`}
          aria-label={data.role === "hard_dependency" ? `Remove owning model for ${data.process}` : `Remove ${data.process}`}
          onClick={(event) => {
            event.stopPropagation();
            data.onRemoveModel?.(data);
          }}
        >
          <Trash2 size={14} />
        </button>
      )}
      <header className="node-header">
        <div>
          <div className="process">{data.process}</div>
          <div className="model-type">{data.modelType}</div>
        </div>
        {data.role === "hard_dependency" ? <GitBranch size={18} /> : <Layers3 size={18} />}
      </header>
      {overview ? (
        <div className="overview-node-summary">
          <span>{data.scale}</span>
          <span>{data.inputs.length} in</span>
          <span>{data.outputs.length} out</span>
        </div>
      ) : (
        <>
      <div className="node-meta">
        {data.role === "hard_dependency" && (
          <span className="meta-chip hard-chip" data-tooltip="Hard dependency: this model is called from its parent model run!, not independently scheduled." aria-label="Hard dependency called by parent model">
            <PhoneCall size={13} /> called by parent
          </span>
        )}
        <span className="meta-chip" data-tooltip={`Scale: ${data.scale}. This is the ModelMapping scale where the model runs.`} title={`Scale: ${data.scale}. This is the ModelMapping scale where the model runs.`} aria-label={`Scale: ${data.scale}. This is the ModelMapping scale where the model runs.`}>
          <Layers3 size={13} />{data.scale}
        </span>
        <span className="meta-chip" data-tooltip={`Rate: ${data.rate}. This describes the timestep used to schedule this model.`} title={`Rate: ${data.rate}. This describes the timestep used to schedule this model.`} aria-label={`Rate: ${data.rate}. This describes the timestep used to schedule this model.`}>
          <Clock3 size={13} />{data.rate}
        </span>
      </div>
      <div className="ports-grid">
        <PortColumn title="Inputs" ports={data.inputs} side="input" data={data} />
        <PortColumn title="Outputs" ports={data.outputs} side="output" data={data} />
      </div>
        </>
      )}
      {data.diagnostics.length > 0 && <div className="diagnostic">{data.diagnostics[0]}</div>}
    </section>
  );
}

function OverviewPortHandles({ inputs, outputs }: { inputs: GraphPort[]; outputs: GraphPort[] }) {
  return (
    <div className="overview-port-handles" aria-hidden="true">
      {inputs.map((port, index) => (
        <Handle
          key={port.id}
          id={port.id}
          type="target"
          position={Position.Left}
          style={{ top: `${overviewHandlePosition(index, inputs.length)}%` }}
        />
      ))}
      {outputs.map((port, index) => (
        <Handle
          key={port.id}
          id={port.id}
          type="source"
          position={Position.Right}
          style={{ top: `${overviewHandlePosition(index, outputs.length)}%` }}
        />
      ))}
    </div>
  );
}

function overviewHandlePosition(index: number, total: number) {
  if (total <= 1) return 50;
  return 24 + (index / (total - 1)) * 52;
}

function PortColumn({ title, ports, side, data }: { title: string; ports: GraphPort[]; side: "input" | "output"; data: RuntimeGraphNodeData }) {
  const highlighted = new Set(data.highlightedPortIds ?? []);
  const focused = new Set(data.focusedPortIds ?? []);
  const requiredInputs = new Set(data.requiredInputPortIds ?? []);
  const candidatePorts = new Set(data.candidatePortIds ?? []);
  const cycleBreakPorts = new Set(data.cycleBreakPortIds ?? []);
  return (
    <div className={`port-column ${side}`}>
      <div className="port-title">{title}</div>
      {ports.map((port) => (
        <div
          className={`port ${port.mappingMode ? "mapped" : ""} ${requiredInputs.has(port.id) ? "required-input" : ""} ${cycleBreakPorts.has(port.id) ? "cycle-break-target" : ""} ${port.previousTimeStep ? "previous" : ""} ${focused.has(port.id) ? "focused" : ""} ${highlighted.has(port.id) ? "highlighted" : ""} ${data.activePortId === port.id ? "active" : ""}`}
          key={port.id}
          data-testid={`port-${side}-${data.scale}-${data.process}-${port.name}`}
          data-default={`${requiredInputs.has(port.id) ? "Required initialization" : portValueLabel(port)}: ${port.default}`}
          aria-label={`${port.name}, ${side}, ${requiredInputs.has(port.id) ? "required initialization" : portValueLabel(port).toLowerCase()} ${port.default}`}
          onMouseEnter={() => data.onPortEnter?.(port)}
          onMouseLeave={() => data.onPortLeave?.(port)}
          onPointerEnter={() => data.onPortEnter?.(port)}
          onPointerLeave={() => data.onPortLeave?.(port)}
          onClick={(event) => {
            event.stopPropagation();
            data.onPortEnter?.(port);
          }}
        >
          {side === "input" && <Handle id={port.id} type="target" position={Position.Left} />}
          <span>{port.name}</span>
          {candidatePorts.has(port.id) && (
            <button
              className="port-candidate-button nodrag nopan"
              data-testid={`candidate-${side}-${data.scale}-${data.process}-${port.name}`}
              type="button"
              title={side === "input" ? "Show models that can compute this variable" : "Show models that can consume this variable"}
              aria-label={side === "input" ? "Show models that can compute this variable" : "Show models that can consume this variable"}
              onClick={(event) => {
                event.stopPropagation();
                const rect = event.currentTarget.getBoundingClientRect();
                data.onPortEnter?.(port);
                data.onCandidateClick?.(port, {
                  x: rect.right,
                  y: rect.top + rect.height / 2,
                });
              }}
            >
              <Plus size={10} />
            </button>
          )}
          {side === "input" && data.cycleBreakActive && cycleBreakPorts.has(port.id) && (
            <button
              className="port-cycle-break-button nodrag nopan"
              data-testid={`cycle-break-${data.scale}-${data.process}-${port.name}`}
              type="button"
              title="Use this input from the previous timestep to break the cycle"
              aria-label={`Break cycle at ${port.name}`}
              onPointerDown={(event) => {
                event.preventDefault();
                event.stopPropagation();
              }}
              onMouseDown={(event) => {
                event.preventDefault();
                event.stopPropagation();
              }}
              onClick={(event) => {
                event.preventDefault();
                event.stopPropagation();
                data.onPortEnter?.(port);
                data.onCycleBreakClick?.(port);
              }}
            >
              <ScissorsLineDashed size={11} />
            </button>
          )}
          {port.mappingMode && <Link2 size={12} />}
          {side === "output" && <Handle id={port.id} type="source" position={Position.Right} />}
        </div>
      ))}
    </div>
  );
}

function portValueLabel(port: GraphPort) {
  return port.role === "input" ? "Default" : "Declaration";
}

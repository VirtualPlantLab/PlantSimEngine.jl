import { Handle, Position, type Node, type NodeProps } from "@xyflow/react";
import { Clock3, GitBranch, Layers3, Link2 } from "lucide-react";
import type { GraphPort, RuntimeGraphNodeData } from "./types";

type ModelFlowNode = Node<RuntimeGraphNodeData, "model">;

export function ModelNode({ data, selected }: NodeProps<ModelFlowNode>) {
  return (
    <section className={`model-node ${data.role} ${selected ? "selected" : ""}`} data-scale={data.scale}>
      <header className="node-header">
        <div>
          <div className="process">{data.process}</div>
          <div className="model-type">{data.modelType}</div>
        </div>
        {data.role === "hard_dependency" ? <GitBranch size={18} /> : <Layers3 size={18} />}
      </header>
      <div className="node-meta">
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
      {data.diagnostics.length > 0 && <div className="diagnostic">{data.diagnostics[0]}</div>}
    </section>
  );
}

function PortColumn({ title, ports, side, data }: { title: string; ports: GraphPort[]; side: "input" | "output"; data: RuntimeGraphNodeData }) {
  const highlighted = new Set(data.highlightedPortIds ?? []);
  return (
    <div className={`port-column ${side}`}>
      <div className="port-title">{title}</div>
      {ports.map((port) => (
        <div
          className={`port ${port.mappingMode ? "mapped" : ""} ${port.previousTimeStep ? "previous" : ""} ${highlighted.has(port.id) ? "highlighted" : ""} ${data.activePortId === port.id ? "active" : ""}`}
          key={port.id}
          title={port.default}
          onMouseEnter={() => data.onPortEnter?.(port)}
          onMouseLeave={() => data.onPortLeave?.()}
          onPointerEnter={() => data.onPortEnter?.(port)}
          onPointerLeave={() => data.onPortLeave?.()}
          onClick={(event) => {
            event.stopPropagation();
            data.onPortEnter?.(port);
          }}
        >
          {side === "input" && <Handle id={port.id} type="target" position={Position.Left} />}
          <span>{port.name}</span>
          {port.mappingMode && <Link2 size={12} />}
          {side === "output" && <Handle id={port.id} type="source" position={Position.Right} />}
        </div>
      ))}
    </div>
  );
}

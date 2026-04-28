import { Handle, Position, type Node, type NodeProps } from "@xyflow/react";
import { Clock3, GitBranch, Layers3, Link2 } from "lucide-react";
import type { GraphNodeData, GraphPort } from "./types";

type ModelFlowNode = Node<GraphNodeData, "model">;

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
        <span><Layers3 size={13} />{data.scale}</span>
        <span><Clock3 size={13} />{data.rate}</span>
      </div>
      <div className="ports-grid">
        <PortColumn title="Inputs" ports={data.inputs} side="input" />
        <PortColumn title="Outputs" ports={data.outputs} side="output" />
      </div>
      {data.diagnostics.length > 0 && <div className="diagnostic">{data.diagnostics[0]}</div>}
    </section>
  );
}

function PortColumn({ title, ports, side }: { title: string; ports: GraphPort[]; side: "input" | "output" }) {
  return (
    <div className={`port-column ${side}`}>
      <div className="port-title">{title}</div>
      {ports.map((port) => (
        <div className={`port ${port.mappingMode ? "mapped" : ""} ${port.previousTimeStep ? "previous" : ""}`} key={port.id} title={port.default}>
          {side === "input" && <Handle id={port.id} type="target" position={Position.Left} />}
          <span>{port.name}</span>
          {port.mappingMode && <Link2 size={12} />}
          {side === "output" && <Handle id={port.id} type="source" position={Position.Right} />}
        </div>
      ))}
    </div>
  );
}

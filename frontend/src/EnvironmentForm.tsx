import { Check, X } from "lucide-react";
import { useState } from "react";
import type { EnvironmentDescriptor } from "./types";

export function EnvironmentForm({ environments, activeId, onSubmit, onClose }: {
  environments: EnvironmentDescriptor[];
  activeId: string | null;
  onSubmit: (environmentId: string | null) => void;
  onClose: () => void;
}) {
  const [environmentId, setEnvironmentId] = useState(activeId || "none");
  const selected = environments.find((environment) => environment.id === environmentId);
  return <div className="overlay-backdrop" onMouseDown={onClose}>
    <section className="overlay-panel environment-form" onMouseDown={(event) => event.stopPropagation()} data-testid="environment-form">
      <header><div><strong>Scene environment</strong><span>Environment values stay in Julia and are selected by catalog name</span></div><button onClick={onClose}><X size={17} /></button></header>
      <div className="overlay-content">
        <label>Environment<select value={environmentId} onChange={(event) => setEnvironmentId(event.target.value)} data-testid="scene-environment"><option value="none">No environment</option>{environments.filter((environment) => environment.source === "catalog").map((environment) => <option value={environment.id} key={environment.id}>{environment.name} · {environment.type}</option>)}</select></label>
        {selected && <section className="environment-summary"><strong>{selected.name}</strong><code>{selected.type}</code><span>{selected.variables.length ? `Available variables: ${selected.variables.join(", ")}` : "Backend variables are discovered by Julia at compile time."}</span></section>}
      </div>
      <footer><button onClick={onClose}>Cancel</button><button className="primary" onClick={() => onSubmit(environmentId === "none" ? null : environmentId)} data-testid="environment-submit"><Check size={15} /> Use environment</button></footer>
    </section>
  </div>;
}

import { useEffect, useState } from "react";
import { Check, Plus, Trash2 } from "lucide-react";
import type { ApplicationGraphNode, ApplicationOwner, OutputDestinationDescriptor, SelectorDescriptor } from "./types";

export type OutputDestinationDraft = {
  selector: SelectorDescriptor;
  vars: string | null;
  coverage: "exact";
};

export function outputDestinationDrafts(destinations: OutputDestinationDescriptor[]): OutputDestinationDraft[] {
  return destinations.map((destination) => ({
    selector: destination.selector,
    vars: destination.vars === null ? null : destination.vars.join(", "),
    coverage: destination.coverage,
  }));
}

export function outputDestinationsCommand(applicationRef: ApplicationOwner, drafts: OutputDestinationDraft[], distributedVariables: string[]) {
  const names = new Set(distributedVariables);
  const bound = new Set<string>();
  const destinations = drafts.map((draft) => {
    if (draft.vars === null && drafts.length !== 1) throw new Error("With several destinations, list the variables for every destination.");
    const vars = draft.vars === null ? null : draft.vars.split(",").map((name) => name.trim()).filter(Boolean);
    const resolved = vars === null ? distributedVariables : vars;
    if (resolved.length === 0) throw new Error("Each destination must bind at least one distributed output.");
    for (const variable of resolved) {
      if (!names.has(variable)) throw new Error(`${variable} is not a distributed output of this model.`);
      if (bound.has(variable)) throw new Error(`${variable} is bound more than once.`);
      bound.add(variable);
    }
    return { selector: draft.selector, vars, coverage: draft.coverage };
  });
  const missing = distributedVariables.filter((variable) => !bound.has(variable));
  if (missing.length > 0) throw new Error(`Choose destinations for: ${missing.join(", ")}.`);
  return { action: "edit", kind: "set_output_destinations", applicationRef, destinations };
}

export function OutputDestinationsFields({ application, onCommand }: {
  application: ApplicationGraphNode;
  onCommand: (command: Record<string, unknown>) => void;
}) {
  const [drafts, setDrafts] = useState(() => outputDestinationDrafts(application.outputsTo));
  const [error, setError] = useState<string | null>(null);
  useEffect(() => {
    setDrafts(outputDestinationDrafts(application.outputsTo));
    setError(null);
  }, [application.applicationId, application.outputsTo]);
  const distributed = application.outputs.filter((port) => port.storage === "distributed");
  if (distributed.length === 0 && drafts.length === 0) return null;

  function update(index: number, value: Partial<OutputDestinationDraft>) {
    setDrafts((current) => current.map((entry, i) => i === index ? { ...entry, ...value } : entry));
    setError(null);
  }

  function updateSelector(index: number, selector: SelectorDescriptor) {
    update(index, { selector: { ...selector, julia: "" } });
  }

  function apply() {
    try {
      const command = outputDestinationsCommand(application.owner, drafts, distributed.map((port) => port.name));
      setError(null);
      onCommand(command);
    } catch (failure) {
      setError(failure instanceof Error ? failure.message : String(failure));
    }
  }

  return <fieldset data-testid="output-destinations"><legend>Output destinations</legend>
    <p>Distributed outputs: {distributed.map((port) => port.name).join(", ")}. Each variable needs one destination selection.</p>
    {drafts.map((draft, index) => {
      const within = draft.selector.criteria.within as { type?: string } | undefined;
      const scope = within?.type || "local";
      return <fieldset key={index} data-testid={`output-destination-${index}`}><legend>Destination {index + 1}</legend>
        <div className="form-grid compact-configuration-row">
          <label>Objects<select aria-label={`Destination ${index + 1} multiplicity`} value={draft.selector.multiplicity} onChange={(event) => updateSelector(index, { ...draft.selector, multiplicity: event.target.value as SelectorDescriptor["multiplicity"], type: event.target.value === "one" ? "One" : "Many" })}><option value="many">Many</option><option value="one">One</option></select></label>
          <label>Scope<select aria-label={`Destination ${index + 1} scope`} value={scope} onChange={(event) => {
            const criteria = { ...draft.selector.criteria };
            if (event.target.value === "local") delete criteria.within;
            else criteria.within = { type: event.target.value };
            updateSelector(index, { ...draft.selector, criteria });
          }}><option value="local">Instance local</option><option value="SceneScope">Whole scene</option><option value="SelfPlant">Current plant</option><option value="Subtree">Current object and descendants</option><option value="Self">Current object</option>{!["local", "SceneScope", "SelfPlant", "Subtree", "Self"].includes(scope) && <option value={scope}>Current {scope} scope</option>}</select></label>
          {(["scale", "kind", "species"] as const).map((criterion) => <label key={criterion}>{criterion}<input aria-label={`Destination ${index + 1} ${criterion}`} value={String(draft.selector.criteria[criterion] || "")} onChange={(event) => {
            const criteria = { ...draft.selector.criteria };
            if (event.target.value.trim()) criteria[criterion] = event.target.value.trim();
            else delete criteria[criterion];
            updateSelector(index, { ...draft.selector, criteria });
          }} placeholder="Any" /></label>)}
        </div>
        {draft.selector.julia && <code>{draft.selector.julia}</code>}
        <label><input type="checkbox" checked={draft.vars === null} disabled={drafts.length !== 1 && draft.vars !== null} onChange={(event) => update(index, { vars: event.target.checked ? null : distributed.map((port) => port.name).join(", ") })} /> All distributed outputs (single destination)</label>
        {draft.vars !== null && <label>Variables<input aria-label={`Destination ${index + 1} variables`} value={draft.vars} onChange={(event) => update(index, { vars: event.target.value })} placeholder="x, y" /></label>}
        <button type="button" className="danger" aria-label={`Remove destination ${index + 1}`} onClick={() => setDrafts((current) => current.filter((_, i) => i !== index))}><Trash2 size={14} /> Remove destination</button>
      </fieldset>;
    })}
    {error && <p role="alert">{error}</p>}
    <div className="compact-actions"><button type="button" onClick={() => setDrafts((current) => [...current, {
      selector: { type: "Many", multiplicity: "many", criteria: { selectors: [], within: { type: "SceneScope" } }, julia: "" },
      vars: current.length === 0 ? null : "",
      coverage: "exact",
    }])}><Plus size={14} /> Add destination</button><button type="button" data-testid="apply-output-destinations" onClick={apply}><Check size={14} /> Apply destinations</button></div>
  </fieldset>;
}

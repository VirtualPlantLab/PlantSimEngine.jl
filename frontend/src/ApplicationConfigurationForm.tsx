import { useMemo, useState } from "react";
import { Check, Plus, Trash2, X } from "lucide-react";
import type { ApplicationGraphNode, SelectorDescriptor } from "./types";

type UpdateRule = { variables: string[]; after: string[] };

export function ApplicationConfigurationForm({
  application,
  applications,
  onCommand,
  onClose,
}: {
  application: ApplicationGraphNode;
  applications: ApplicationGraphNode[];
  onCommand: (command: Record<string, unknown>) => void;
  onClose: () => void;
}) {
  const otherApplications = applications.filter((item) => item.applicationId !== application.applicationId);
  const [callName, setCallName] = useState("");
  const [calleeId, setCalleeId] = useState(otherApplications[0]?.applicationId || "");
  const [provider, setProvider] = useState(String(application.environment?.provider || "scene"));
  const [updateRules, setUpdateRules] = useState<UpdateRule[]>(application.updates || []);
  const [updateVariable, setUpdateVariable] = useState(application.outputs[0]?.name || "");
  const [updateAfter, setUpdateAfter] = useState(otherApplications[0]?.applicationId || "");
  const selectedCallee = otherApplications.find((item) => item.applicationId === calleeId);
  const callSelector = useMemo<SelectorDescriptor>(() => ({
    type: selectedCallee?.targetCount === 1 ? "One" : "Many",
    multiplicity: selectedCallee?.targetCount === 1 ? "one" : "many",
    criteria: {
      selectors: [],
      within: { type: "SceneScope" },
      application: calleeId,
    },
    julia: "",
  }), [calleeId, selectedCallee?.targetCount]);

  const addCall = () => {
    if (!callName.trim() || !calleeId) return;
    onCommand({
      action: "edit",
      kind: "set_call_binding",
      applicationId: application.applicationId,
      call: callName.trim(),
      selector: callSelector,
    });
    setCallName("");
  };

  const addUpdateRule = () => {
    if (!updateVariable || !updateAfter) return;
    setUpdateRules((current) => [
      ...current.filter((rule) => !rule.variables.includes(updateVariable)),
      { variables: [updateVariable], after: [updateAfter] },
    ]);
  };

  return <div className="overlay-backdrop" onMouseDown={onClose}>
    <section className="overlay-panel application-configuration-form" onMouseDown={(event) => event.stopPropagation()} data-testid="application-configuration-form">
      <header><div><strong>Configure {application.applicationId}</strong><span>Authored coupling and execution policy, validated by Julia</span></div><button onClick={onClose}><X size={17} /></button></header>
      <div className="overlay-content application-configuration-content">
        <fieldset><legend>Explicit input bindings</legend>
          {Object.entries(application.inputBindings).length === 0 && <p>No authored input bindings. Unique same-object producers may still be inferred.</p>}
          <div className="configuration-list">{Object.entries(application.inputBindings).map(([input, selector]) => <div key={input}><code>{input}</code><span>{selector.julia || selector.type}</span><button className="danger icon-button" title={`Remove ${input} binding`} onClick={() => onCommand({ action: "edit", kind: "remove_input_binding", applicationId: application.applicationId, input })}><Trash2 size={14} /></button></div>)}</div>
        </fieldset>

        <fieldset><legend>Manual calls</legend>
          <div className="configuration-list">{Object.entries(application.callBindings).map(([call, selector]) => <div key={call}><code>{call}</code><span>{selector.julia || selector.type}</span><button className="danger icon-button" title={`Remove ${call} call`} onClick={() => onCommand({ action: "edit", kind: "remove_call_binding", applicationId: application.applicationId, call })}><Trash2 size={14} /></button></div>)}</div>
          <div className="form-grid compact-configuration-row"><label>Call name<input data-testid="call-name" value={callName} onChange={(event) => setCallName(event.target.value)} placeholder="child" /></label><label>Target application<select data-testid="call-target" value={calleeId} onChange={(event) => setCalleeId(event.target.value)}><option value="">Choose application</option>{otherApplications.map((item) => <option key={item.applicationId} value={item.applicationId}>{item.applicationId}</option>)}</select></label><button type="button" data-testid="add-call-binding" disabled={!callName.trim() || !calleeId} onClick={addCall}><Plus size={14} /> Add call</button></div>
        </fieldset>

        <fieldset><legend>Environment</legend>
          <div className="form-grid compact-configuration-row"><label>Provider<input data-testid="environment-provider" value={provider} onChange={(event) => setProvider(event.target.value)} placeholder="scene" /></label><button type="button" data-testid="apply-environment-provider" disabled={!provider.trim()} onClick={() => onCommand({ action: "edit", kind: "set_environment_provider", applicationId: application.applicationId, provider: provider.trim() })}><Check size={14} /> Apply provider</button></div>
          {Object.keys(application.meteoBindings || {}).length > 0 && <code>{JSON.stringify(application.meteoBindings)}</code>}
        </fieldset>

        <fieldset><legend>Output routing</legend>
          <div className="configuration-list">{application.outputs.map((output) => <label key={output.name}><code>{output.name}</code><select data-testid={`output-routing-${output.name}`} value={application.outputRouting[output.name] || "canonical"} onChange={(event) => onCommand({ action: "edit", kind: "set_output_routing", applicationId: application.applicationId, output: output.name, route: event.target.value })}><option value="canonical">Canonical status owner</option><option value="stream_only">Stream only</option></select></label>)}</div>
        </fieldset>

        <fieldset><legend>Duplicate-writer ordering</legend>
          <div className="configuration-list">{updateRules.map((rule, index) => <div key={`${rule.variables.join(",")}:${rule.after.join(",")}`}><code>{rule.variables.join(", ")}</code><span>after {rule.after.join(", ")}</span><button className="danger icon-button" title="Remove update ordering" onClick={() => setUpdateRules((current) => current.filter((_, itemIndex) => itemIndex !== index))}><Trash2 size={14} /></button></div>)}</div>
          <div className="form-grid compact-configuration-row"><label>Output<select value={updateVariable} onChange={(event) => setUpdateVariable(event.target.value)}>{application.outputs.map((output) => <option key={output.name} value={output.name}>{output.name}</option>)}</select></label><label>Run after<select value={updateAfter} onChange={(event) => setUpdateAfter(event.target.value)}><option value="">Choose application</option>{otherApplications.map((item) => <option key={item.applicationId} value={item.applicationId}>{item.applicationId}</option>)}</select></label><button type="button" disabled={!updateVariable || !updateAfter} onClick={addUpdateRule}><Plus size={14} /> Add rule</button><button type="button" onClick={() => onCommand({ action: "edit", kind: "set_update_ordering", applicationId: application.applicationId, updates: updateRules })}><Check size={14} /> Apply ordering</button></div>
        </fieldset>
      </div>
      <footer><button className="primary" onClick={onClose}>Done</button></footer>
    </section>
  </div>;
}

import { useMemo, useState } from "react";
import { Check, Plus, Trash2, X } from "lucide-react";
import type { ApplicationGraphNode, EnvironmentDescriptor, ModelDescriptor, SelectorDescriptor } from "./types";

type UpdateRule = { variables: string[]; after: string[] };
export type ExtraEntry = { key: string; type: string; value: string };

export function ApplicationConfigurationForm({
  application,
  applications,
  environments,
  models,
  onCommand,
  onClose,
}: {
  application: ApplicationGraphNode;
  applications: ApplicationGraphNode[];
  environments: EnvironmentDescriptor[];
  models: ModelDescriptor[];
  onCommand: (command: Record<string, unknown>) => void;
  onClose: () => void;
}) {
  const otherApplications = applications.filter((item) =>
    item.applicationId !== application.applicationId &&
    (application.owner.scope === "global"
      ? item.owner.scope === "global"
      : item.owner.scope === "template" &&
        item.owner.templateId === application.owner.templateId &&
        item.owner.instance === application.owner.instance)
  );
  const [callName, setCallName] = useState("");
  const [calleeId, setCalleeId] = useState(otherApplications[0]?.applicationId || "");
  const [environmentMode, setEnvironmentMode] = useState(
    application.environment ? application.environment.backendId || "scene" : "default"
  );
  const [provider, setProvider] = useState(String(application.environment?.provider || ""));
  const [sources, setSources] = useState<Record<string, string>>(() => ({
    ...Object.fromEntries(application.environmentInputs.map((port) => [port.name, ""])),
    ...(application.environment?.sources || {}),
  }));
  const [sink, setSink] = useState(String(application.environment?.sink || ""));
  const [extraEntries, setExtraEntries] = useState<ExtraEntry[]>(() => extraConfigurationEntries(application.environment?.extra));
  const [updateRules, setUpdateRules] = useState<UpdateRule[]>(application.updates || []);
  const [updateVariable, setUpdateVariable] = useState(application.outputs[0]?.name || "");
  const [updateAfter, setUpdateAfter] = useState(otherApplications[0]?.owner.applicationId || "");
  const selectedCallee = otherApplications.find((item) => item.applicationId === calleeId);
  const model = models.find((item) => item.type === application.modelType);
  const callSelector = useMemo<SelectorDescriptor>(() => {
    const sameTemplate = application.owner.scope === "template" &&
      selectedCallee?.owner.scope === "template" &&
      selectedCallee.owner.templateId === application.owner.templateId;
    return {
      type: selectedCallee?.targetCount === 1 ? "One" : "Many",
      multiplicity: selectedCallee?.targetCount === 1 ? "one" : "many",
      criteria: {
        selectors: [],
        ...(sameTemplate ? {} : { within: { type: "SceneScope" } }),
        application: selectedCallee?.owner.applicationId || calleeId,
      },
      julia: "",
    };
  }, [application.owner.scope, application.owner.templateId, calleeId, selectedCallee]);

  const addCall = () => {
    if (!callName.trim() || !calleeId) return;
    onCommand({
      action: "edit",
      kind: "set_call_binding",
      applicationRef: application.owner,
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

  const applyEnvironment = () => {
    const configuration = applicationEnvironmentConfiguration(environmentMode, provider, sources, sink, extraEntries);
    onCommand({
      action: "edit",
      kind: "set_application_environment",
      applicationRef: application.owner,
      configuration,
    });
  };

  return <div className="overlay-backdrop" onMouseDown={onClose}>
    <section className="overlay-panel application-configuration-form" onMouseDown={(event) => event.stopPropagation()} data-testid="application-configuration-form">
      <header><div><strong>Configure {application.owner.applicationId}</strong><span>Authored coupling and execution policy, validated by Julia</span></div><button onClick={onClose}><X size={17} /></button></header>
      <div className="overlay-content application-configuration-content">
        <fieldset><legend>Explicit input bindings</legend>
          {Object.entries(application.inputBindings).length === 0 && <p>No authored input bindings. Unique same-object producers may still be inferred.</p>}
          <div className="configuration-list">{Object.entries(application.inputBindings).map(([input, selector]) => <div key={input}><code>{input}</code><span>{selector.julia || selector.type}</span><button className="danger icon-button" title={`Remove ${input} binding`} onClick={() => onCommand({ action: "edit", kind: "remove_input_binding", applicationRef: application.owner, input })}><Trash2 size={14} /></button></div>)}</div>
        </fieldset>

        <fieldset><legend>Manual calls</legend>
          <div className="configuration-list">{Object.entries(application.callBindings).map(([call, selector]) => <div key={call}><code>{call}</code><span>{selector.julia || selector.type}</span><button className="danger icon-button" title={`Remove ${call} call`} onClick={() => onCommand({ action: "edit", kind: "remove_call_binding", applicationRef: application.owner, call })}><Trash2 size={14} /></button></div>)}</div>
          <div className="form-grid compact-configuration-row"><label>Call name<input data-testid="call-name" value={callName} onChange={(event) => setCallName(event.target.value)} placeholder="child" /></label><label>Target application<select data-testid="call-target" value={calleeId} onChange={(event) => setCalleeId(event.target.value)}><option value="">Choose application</option>{otherApplications.map((item) => <option key={item.applicationId} value={item.applicationId}>{item.owner.applicationId}</option>)}</select></label><button type="button" data-testid="add-call-binding" disabled={!callName.trim() || !calleeId} onClick={addCall}><Plus size={14} /> Add call</button></div>
        </fieldset>

        <fieldset><legend>Environment</legend>
          {model?.environmentHint && <p className="environment-hint"><strong>Model hint</strong> {model.environmentHint}</p>}
          <div className="form-grid compact-configuration-row">
            <label>Backend<select data-testid="environment-backend" value={environmentMode} onChange={(event) => setEnvironmentMode(event.target.value)}><option value="default">No application override</option><option value="scene">Active scene environment</option>{environments.filter((item) => item.source === "catalog").map((item) => <option value={item.id} key={item.id}>{item.name} · {item.type}</option>)}</select></label>
            <label>Provider<input data-testid="environment-provider" value={provider} onChange={(event) => setProvider(event.target.value)} placeholder="default provider" disabled={environmentMode === "default"} /></label>
            <label>Output sink<input data-testid="environment-sink" value={sink} onChange={(event) => setSink(event.target.value)} placeholder="default sink" disabled={environmentMode === "default"} /></label>
          </div>
          {application.environmentInputs.length > 0 && <div className="configuration-list environment-sources">{application.environmentInputs.map((input) => <label key={input.name}><code>{input.name}</code><input value={sources[input.name] || ""} onChange={(event) => setSources((current) => ({ ...current, [input.name]: event.target.value }))} placeholder="backend source variable" disabled={environmentMode === "default"} data-testid={`environment-source-${input.name}`} /></label>)}</div>}
          <div className="configuration-list">{extraEntries.map((entry, index) => <div key={index}><input aria-label="Backend option" value={entry.key} onChange={(event) => setExtraEntries((current) => current.map((item, itemIndex) => itemIndex === index ? { ...item, key: event.target.value } : item))} placeholder="option" /><select value={entry.type} onChange={(event) => setExtraEntries((current) => current.map((item, itemIndex) => itemIndex === index ? { ...item, type: event.target.value } : item))}><option value="float">Float</option><option value="integer">Integer</option><option value="boolean">Boolean</option><option value="symbol">Symbol</option><option value="string">String</option><option value="julia">Julia expression</option></select><input aria-label="Backend option value" value={entry.value} onChange={(event) => setExtraEntries((current) => current.map((item, itemIndex) => itemIndex === index ? { ...item, value: event.target.value } : item))} /><button className="danger icon-button" onClick={() => setExtraEntries((current) => current.filter((_, itemIndex) => itemIndex !== index))}><Trash2 size={14} /></button></div>)}</div>
          <div className="compact-actions"><button type="button" disabled={environmentMode === "default"} onClick={() => setExtraEntries((current) => [...current, { key: "", type: "string", value: "" }])}><Plus size={14} /> Backend option</button><button type="button" data-testid="apply-environment" onClick={applyEnvironment}><Check size={14} /> Apply environment</button></div>
          <div className="effective-environment"><strong>Effective bindings</strong><code>{JSON.stringify(application.environmentBindings || {}, null, 2)}</code>{application.environmentWindow !== null && application.environmentWindow !== undefined ? <code>{JSON.stringify(application.environmentWindow)}</code> : null}</div>
        </fieldset>

        <fieldset><legend>Output routing</legend>
          <div className="configuration-list">{application.outputs.map((output) => <label key={output.name}><code>{output.name}</code><select data-testid={`output-routing-${output.name}`} value={application.outputRouting[output.name] || "canonical"} onChange={(event) => onCommand({ action: "edit", kind: "set_output_routing", applicationRef: application.owner, output: output.name, route: event.target.value })}><option value="canonical">Canonical status owner</option><option value="stream_only">Stream only</option></select></label>)}</div>
        </fieldset>

        <fieldset><legend>Duplicate-writer ordering</legend>
          <div className="configuration-list">{updateRules.map((rule, index) => <div key={`${rule.variables.join(",")}:${rule.after.join(",")}`}><code>{rule.variables.join(", ")}</code><span>after {rule.after.join(", ")}</span><button className="danger icon-button" title="Remove update ordering" onClick={() => setUpdateRules((current) => current.filter((_, itemIndex) => itemIndex !== index))}><Trash2 size={14} /></button></div>)}</div>
          <div className="form-grid compact-configuration-row"><label>Output<select value={updateVariable} onChange={(event) => setUpdateVariable(event.target.value)}>{application.outputs.map((output) => <option key={output.name} value={output.name}>{output.name}</option>)}</select></label><label>Run after<select value={updateAfter} onChange={(event) => setUpdateAfter(event.target.value)}><option value="">Choose application</option>{otherApplications.map((item) => <option key={item.applicationId} value={item.owner.applicationId}>{item.owner.applicationId}</option>)}</select></label><button type="button" disabled={!updateVariable || !updateAfter} onClick={addUpdateRule}><Plus size={14} /> Add rule</button><button type="button" onClick={() => onCommand({ action: "edit", kind: "set_update_ordering", applicationRef: application.owner, updates: updateRules })}><Check size={14} /> Apply ordering</button></div>
        </fieldset>
      </div>
      <footer><button className="primary" onClick={onClose}>Done</button></footer>
    </section>
  </div>;
}

function extraConfigurationEntries(extra: Record<string, unknown> | undefined): ExtraEntry[] {
  return Object.entries(extra || {}).map(([key, value]) => ({
    key,
    type: typeof value === "number" ? (Number.isInteger(value) ? "integer" : "float") : typeof value === "boolean" ? "boolean" : "string",
    value: String(value ?? ""),
  }));
}

export function applicationEnvironmentConfiguration(
  mode: string,
  provider: string,
  sources: Record<string, string>,
  sink: string,
  extraEntries: ExtraEntry[],
) {
  if (mode === "default") return null;
  return {
    backendId: mode,
    provider: provider.trim() || null,
    sources: Object.fromEntries(Object.entries(sources).filter(([, value]) => value.trim()).map(([key, value]) => [key, value.trim()])),
    sink: sink.trim() || null,
    extra: Object.fromEntries(extraEntries.filter((entry) => entry.key.trim()).map((entry) => [entry.key.trim(), { type: entry.type, value: entry.value }])),
  };
}

import { useState } from "react";
import { Eye, Link2, X } from "lucide-react";
import type { ApplicationGraphNode, ApplicationOwner, GraphPort, ObjectGraphNode, PeriodDescriptor, SelectorDescriptor, SelectorPreview } from "./types";

export type BindingFormValue = {
  applicationRef: ApplicationOwner;
  input: string;
  selector: SelectorDescriptor;
};

export type BindingEndpoints = {
  sourceApplication: ApplicationGraphNode;
  sourcePort: GraphPort;
  targetApplication: ApplicationGraphNode;
  targetPort: GraphPort;
};

type BindingFormProps = {
  endpoints: BindingEndpoints;
  objects: ObjectGraphNode[];
  preview: SelectorPreview | null;
  onPreview: (value: BindingFormValue) => void;
  onSubmit: (value: BindingFormValue) => void;
  onClose: () => void;
};

export function BindingForm({ endpoints, objects, preview, onPreview, onSubmit, onClose }: BindingFormProps) {
  const sameTargets = sameValues(endpoints.sourceApplication.targetIds, endpoints.targetApplication.targetIds);
  const [multiplicity, setMultiplicity] = useState<SelectorDescriptor["multiplicity"]>(endpoints.sourceApplication.targetCount > 1 && endpoints.targetApplication.targetCount === 1 ? "many" : "one");
  const [relation, setRelation] = useState(sameTargets ? "self" : "");
  const [scope, setScope] = useState("local");
  const [scopeName, setScopeName] = useState("");
  const [ancestorScale, setAncestorScale] = useState("");
  const [scale, setScale] = useState(onlyOrEmpty(endpoints.sourceApplication.targetScales));
  const [kind, setKind] = useState(onlyOrEmpty(endpoints.sourceApplication.targetKinds));
  const [species, setSpecies] = useState(onlyOrEmpty(endpoints.sourceApplication.targetSpecies));
  const [sourceName, setSourceName] = useState("");
  const [sourceFilter, setSourceFilter] = useState<"application" | "process">("application");
  const [policy, setPolicy] = useState("automatic");
  const [windowValue, setWindowValue] = useState("");
  const [windowUnit, setWindowUnit] = useState("Hour");
  const scales = unique(objects.map((object) => object.scale));
  const kinds = unique(objects.map((object) => object.kind));
  const speciesOptions = unique(objects.map((object) => object.species));
  const names = unique(objects.map((object) => object.name));

  const value = (): BindingFormValue => {
    const criteria: Record<string, unknown> = {
      selectors: [],
      var: endpoints.sourcePort.name,
    };
    criteria[sourceFilter] = sourceFilter === "application"
      ? endpoints.sourceApplication.owner.applicationId
      : endpoints.sourceApplication.process;
    const within = scopeDescriptor(scope, scopeName, ancestorScale);
    if (within) criteria.within = within;
    if (relation) criteria.relation = relation;
    if (scale) criteria.scale = scale;
    if (kind) criteria.kind = kind;
    if (species) criteria.species = species;
    if (sourceName) criteria.name = sourceName;
    if (policy !== "automatic") criteria.policy = { type: policyType(policy) };
    if (windowValue.trim()) {
      const window = bindingWindowDescriptor(windowValue, windowUnit);
      if (window) criteria.window = window;
    }
    return {
      applicationRef: endpoints.targetApplication.owner,
      input: endpoints.targetPort.name,
      selector: { type: selectorType(multiplicity), multiplicity, criteria, julia: "" },
    };
  };

  return <div className="overlay-backdrop" onMouseDown={onClose}>
    <section className="overlay-panel binding-form" onMouseDown={(event) => event.stopPropagation()} data-testid="binding-form">
      <header><div><strong>Connect applications</strong><span>Julia resolves this declaration into concrete object bindings</span></div><button onClick={onClose}><X size={17} /></button></header>
      <div className="overlay-content">
        <div className="binding-route"><div><small>Producer</small><strong>{endpoints.sourceApplication.applicationId}</strong><code>{endpoints.sourcePort.name}</code></div><Link2 size={22} /><div><small>Consumer</small><strong>{endpoints.targetApplication.applicationId}</strong><code>{endpoints.targetPort.name}</code></div></div>
        <fieldset><legend>Source object selector</legend><div className="form-grid">
          <label>Multiplicity<select value={multiplicity} onChange={(event) => setMultiplicity(event.target.value as SelectorDescriptor["multiplicity"])}><option value="one">One</option><option value="optional_one">Optional one</option><option value="many">Many</option></select></label>
          <label>Scope<select value={scope} onChange={(event) => setScope(event.target.value)}><option value="local">Default / instance local</option><option value="scene">Explicit whole scene</option><option value="self">Consumer object</option><option value="subtree">Consumer subtree</option><option value="self_plant">Consumer plant</option><option value="ancestor">Ancestor subtree</option><option value="named_scope">Named object subtree</option></select></label>
          {scope === "ancestor" && <Criterion label="Ancestor scale" value={ancestorScale} options={scales} onChange={setAncestorScale} />}
          {scope === "named_scope" && <Criterion label="Scope root" value={scopeName} options={names} onChange={setScopeName} />}
          <label>Relation<select value={relation} onChange={(event) => setRelation(event.target.value)}><option value="">Any relation</option><option value="self">Same object</option><option value="parent">Parent</option><option value="children">Children</option><option value="ancestors">Ancestors</option><option value="descendants">Descendants</option><option value="siblings">Siblings</option></select></label>
          <label>Producer filter<select value={sourceFilter} onChange={(event) => setSourceFilter(event.target.value as "application" | "process")}><option value="application">This application</option><option value="process">Any application of this process</option></select></label>
          <Criterion label="Scale" value={scale} options={scales} onChange={setScale} />
          <Criterion label="Kind" value={kind} options={kinds} onChange={setKind} />
          <Criterion label="Species" value={species} options={speciesOptions} onChange={setSpecies} />
          <Criterion label="Object name" value={sourceName} options={names} onChange={setSourceName} />
          <label>Temporal policy<select value={policy} onChange={(event) => setPolicy(event.target.value)}><option value="automatic">Automatic</option><option value="hold_last">Hold last</option><option value="interpolate">Interpolate</option><option value="integrate">Integrate</option><option value="aggregate">Aggregate</option></select></label>
          <label>Window value<input type="number" min="1" step="1" value={windowValue} onChange={(event) => setWindowValue(event.target.value)} placeholder="Automatic" data-testid="binding-window-value" /></label>
          <label>Window unit<select value={windowUnit} onChange={(event) => setWindowUnit(event.target.value)} disabled={!windowValue.trim()} data-testid="binding-window-unit"><option>Second</option><option>Minute</option><option>Hour</option><option>Day</option></select></label>
        </div></fieldset>
        {preview && <section className="selector-preview" data-testid="binding-preview">
          <strong>{preview.bindingCount} resolved binding{preview.bindingCount === 1 ? "" : "s"}</strong>
          <span>{preview.consumerObjectIds.length} consumer object{preview.consumerObjectIds.length === 1 ? "" : "s"} from {preview.sourceObjectIds.length} source object{preview.sourceObjectIds.length === 1 ? "" : "s"}</span>
          {preview.sourceApplicationIds.length > 0 && <code>{preview.sourceApplicationIds.join(", ")}</code>}
          {preview.diagnostics.map((diagnostic) => <p key={diagnostic}>{diagnostic}</p>)}
        </section>}
      </div>
      <footer><button onClick={onClose}>Cancel</button><button onClick={() => onPreview(value())} data-testid="binding-preview-button"><Eye size={15} /> Preview resolution</button><button className="primary" onClick={() => onSubmit(value())} data-testid="binding-submit"><Link2 size={15} /> Apply binding</button></footer>
    </section>
  </div>;
}

function Criterion({ label, value, options, onChange }: { label: string; value: string; options: string[]; onChange: (value: string) => void }) {
  return <label>{label}<select value={value} onChange={(event) => onChange(event.target.value)}><option value="">Any</option>{options.map((option) => <option value={option} key={option}>{option}</option>)}</select></label>;
}

function sameValues(left: unknown[], right: unknown[]) { return left.length === right.length && left.every((value) => right.some((other) => String(other) === String(value))); }
function onlyOrEmpty(values: string[]) { return values.length === 1 ? values[0] : ""; }
function selectorType(value: SelectorDescriptor["multiplicity"]) { return value === "one" ? "One" : value === "optional_one" ? "OptionalOne" : "Many"; }
function unique(values: Array<string | null>) { return [...new Set(values.filter((value): value is string => Boolean(value)))].sort(); }
function policyType(value: string) { return value === "hold_last" ? "HoldLast" : value === "interpolate" ? "Interpolate" : value === "integrate" ? "Integrate" : "Aggregate"; }
function scopeDescriptor(scope: string, name: string, scale: string) {
  if (scope === "local") return null;
  if (scope === "scene") return { type: "SceneScope" };
  if (scope === "self") return { type: "Self" };
  if (scope === "subtree") return { type: "Subtree" };
  if (scope === "self_plant") return { type: "SelfPlant" };
  if (scope === "ancestor") return { type: "Ancestor", scale: scale || null };
  if (scope === "named_scope" && name) return { type: "Scope", name };
  return null;
}

export function bindingWindowDescriptor(value: string, unit: string): PeriodDescriptor | null {
  const parsed = Number(value);
  if (!Number.isInteger(parsed) || parsed <= 0) return null;
  return {
    mode: "period",
    value: parsed,
    unit,
    julia: `Dates.${unit}(${parsed})`,
  };
}

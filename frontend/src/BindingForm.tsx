import { useState } from "react";
import { Link2, X } from "lucide-react";
import type { ApplicationGraphNode, GraphPort, ObjectGraphNode, SelectorDescriptor } from "./types";

export type BindingFormValue = {
  applicationId: string;
  input: string;
  selector: SelectorDescriptor;
};

export type BindingEndpoints = {
  sourceApplication: ApplicationGraphNode;
  sourcePort: GraphPort;
  targetApplication: ApplicationGraphNode;
  targetPort: GraphPort;
};

export function BindingForm({ endpoints, objects, onSubmit, onClose }: { endpoints: BindingEndpoints; objects: ObjectGraphNode[]; onSubmit: (value: BindingFormValue) => void; onClose: () => void }) {
  const sameTargets = sameValues(endpoints.sourceApplication.targetIds, endpoints.targetApplication.targetIds);
  const [multiplicity, setMultiplicity] = useState<SelectorDescriptor["multiplicity"]>(endpoints.sourceApplication.targetCount > 1 && endpoints.targetApplication.targetCount === 1 ? "many" : "one");
  const [relation, setRelation] = useState(sameTargets ? "self" : "");
  const [scale, setScale] = useState(onlyOrEmpty(endpoints.sourceApplication.targetScales));
  const [kind, setKind] = useState(onlyOrEmpty(endpoints.sourceApplication.targetKinds));
  const [sourceName, setSourceName] = useState("");
  const scales = unique(objects.map((object) => object.scale));
  const kinds = unique(objects.map((object) => object.kind));
  const names = unique(objects.map((object) => object.name));

  const submit = () => {
    const criteria: Record<string, unknown> = {
      selectors: [],
      application: endpoints.sourceApplication.applicationId,
      var: endpoints.sourcePort.name,
    };
    if (relation) criteria.relation = relation;
    if (scale) criteria.scale = scale;
    if (kind) criteria.kind = kind;
    if (sourceName) criteria.name = sourceName;
    onSubmit({
      applicationId: endpoints.targetApplication.applicationId,
      input: endpoints.targetPort.name,
      selector: { type: selectorType(multiplicity), multiplicity, criteria, julia: "" },
    });
  };

  return <div className="overlay-backdrop" onMouseDown={onClose}>
    <section className="overlay-panel binding-form" onMouseDown={(event) => event.stopPropagation()} data-testid="binding-form">
      <header><div><strong>Connect applications</strong><span>Julia resolves this declaration into concrete object bindings</span></div><button onClick={onClose}><X size={17} /></button></header>
      <div className="overlay-content">
        <div className="binding-route"><div><small>Producer</small><strong>{endpoints.sourceApplication.applicationId}</strong><code>{endpoints.sourcePort.name}</code></div><Link2 size={22} /><div><small>Consumer</small><strong>{endpoints.targetApplication.applicationId}</strong><code>{endpoints.targetPort.name}</code></div></div>
        <fieldset><legend>Source object selector</legend><div className="form-grid">
          <label>Multiplicity<select value={multiplicity} onChange={(event) => setMultiplicity(event.target.value as SelectorDescriptor["multiplicity"])}><option value="one">One</option><option value="optional_one">Optional one</option><option value="many">Many</option></select></label>
          <label>Relation<select value={relation} onChange={(event) => setRelation(event.target.value)}><option value="">Any relation</option><option value="self">Same object</option><option value="parent">Parent</option><option value="children">Children</option><option value="ancestors">Ancestors</option><option value="descendants">Descendants</option><option value="siblings">Siblings</option></select></label>
          <Criterion label="Scale" value={scale} options={scales} onChange={setScale} />
          <Criterion label="Kind" value={kind} options={kinds} onChange={setKind} />
          <Criterion label="Object name" value={sourceName} options={names} onChange={setSourceName} />
        </div></fieldset>
      </div>
      <footer><button onClick={onClose}>Cancel</button><button className="primary" onClick={submit} data-testid="binding-submit"><Link2 size={15} /> Apply binding</button></footer>
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

import { useMemo, useState } from "react";
import { Check, Eye, X } from "lucide-react";
import type { ApplicationGraphNode, ModelConstructorField, ModelDescriptor, ObjectGraphNode, SelectorDescriptor, TargetPreview } from "./types";

export type ApplicationFormValue = {
  applicationId?: string;
  modelType: string;
  name: string;
  parameters: Record<string, { type: string; value: string }>;
  selector: SelectorDescriptor;
  timestep: { mode: "default" } | { mode: "clock"; dt: string; phase: string };
};

export function ApplicationForm({
  mode,
  models,
  objects,
  application,
  initialModelType,
  suggestedSelector,
  nameReadOnly=false,
  preview,
  onPreview,
  onSubmit,
  onClose,
}: {
  mode: "add" | "update";
  models: ModelDescriptor[];
  objects: ObjectGraphNode[];
  application?: ApplicationGraphNode;
  initialModelType?: string;
  suggestedSelector?: SelectorDescriptor;
  nameReadOnly?: boolean;
  preview: TargetPreview | null;
  onPreview: (selector: SelectorDescriptor) => void;
  onSubmit: (value: ApplicationFormValue) => void;
  onClose: () => void;
}) {
  const applicationModel = application ? modelDescriptorForApplication(models, application) : null;
  const initialType = applicationModel?.type || initialModelType || models[0]?.type || "";
  const [modelType, setModelType] = useState(initialType);
  const model = models.find((item) => item.type === modelType) ?? null;
  const [name, setName] = useState(application?.name || application?.applicationId || defaultApplicationName(model));
  const [parameters, setParameters] = useState<Record<string, { type: string; value: string }>>(() => parameterDefaults(model, application));
  const initialSelector = application?.selector || suggestedSelector || defaultSelector(objects);
  const [multiplicity, setMultiplicity] = useState(initialSelector.multiplicity);
  const [scale, setScale] = useState(stringCriterion(initialSelector, "scale"));
  const [kind, setKind] = useState(stringCriterion(initialSelector, "kind"));
  const [species, setSpecies] = useState(stringCriterion(initialSelector, "species"));
  const [objectName, setObjectName] = useState(stringCriterion(initialSelector, "name"));
  const initialWithin = structuredCriterion(initialSelector, "within");
  const [scope, setScope] = useState(initialWithin?.type === "Scope" ? "named_scope" : "scene");
  const [scopeName, setScopeName] = useState(initialWithin?.type === "Scope" ? String(initialWithin.name || "") : "");
  const [timestepMode, setTimestepMode] = useState<"default" | "clock">(application?.timestep ? "clock" : "default");
  const [dt, setDt] = useState("1.0");
  const [phase, setPhase] = useState("0.0");

  const selectModelType = (nextModelType: string) => {
    const selected = models.find((item) => item.type === nextModelType) ?? null;
    setModelType(nextModelType);
    setParameters(parameterDefaults(selected, mode === "update" ? application : undefined));
    if (mode === "add") setName(defaultApplicationName(selected));
  };

  const options = useMemo(() => ({
    scales: unique(objects.map((object) => object.scale)),
    kinds: unique(objects.map((object) => object.kind)),
    species: unique(objects.map((object) => object.species)),
    names: unique(objects.map((object) => object.name)),
  }), [objects]);

  const targetSummary = useMemo(() => {
    const clauses = [scale && `scale ${scale}`, kind && `kind ${kind}`, species && `species ${species}`, objectName && `name ${objectName}`].filter(Boolean);
    return clauses.length ? clauses.join(", ") : "all scene objects";
  }, [kind, objectName, scale, species]);

  const selector = (): SelectorDescriptor => {
    const criteria: Record<string, unknown> = { selectors: [] };
    criteria.within = scope === "named_scope" && scopeName ? { type: "Scope", name: scopeName } : { type: "SceneScope" };
    if (scale) criteria.scale = scale;
    if (kind) criteria.kind = kind;
    if (species) criteria.species = species;
    if (objectName) criteria.name = objectName;
    return { type: selectorType(multiplicity), multiplicity, criteria, julia: "" };
  };

  const submit = () => {
    onSubmit({
      applicationId: application?.applicationId,
      modelType,
      name: name.trim(),
      parameters,
      selector: selector(),
      timestep: timestepMode === "clock" ? { mode: "clock", dt, phase } : { mode: "default" },
    });
  };

  return (
    <div className="overlay-backdrop" onMouseDown={onClose}>
      <section className="overlay-panel application-form" onMouseDown={(event) => event.stopPropagation()} data-testid="application-form">
        <header><div><strong>{mode === "add" ? "Add application" : `Update ${application?.applicationId}`}</strong><span>A configured use of a model on selected scene objects</span></div><button onClick={onClose}><X size={17} /></button></header>
        <div className="overlay-content application-form-content">
          <label>Model<select value={modelType} onChange={(event) => selectModelType(event.target.value)} data-testid="application-model-select">{models.map((item) => <option value={item.type} key={item.type}>{item.package ? `${item.package} · ` : ""}{item.name} ({item.process})</option>)}</select></label>
          <label>Application name<input value={name} disabled={nameReadOnly} onChange={(event) => setName(event.target.value)} data-testid="application-name" /></label>

          {model && model.constructor.fields.length > 0 && <fieldset><legend>Model parameters</legend><ParameterFields fields={model.constructor.fields} values={parameters} onChange={setParameters} /></fieldset>}

          <fieldset><legend>Target selector</legend>
            <div className="form-grid">
              <label>Multiplicity<select value={multiplicity} onChange={(event) => setMultiplicity(event.target.value as SelectorDescriptor["multiplicity"])}><option value="one">One</option><option value="optional_one">Optional one</option><option value="many">Many</option></select></label>
              <label>Scope<select value={scope} onChange={(event) => setScope(event.target.value)}><option value="scene">Whole scene</option><option value="named_scope">Named object subtree</option></select></label>
              {scope === "named_scope" && <SelectCriterion label="Scope root" value={scopeName} options={options.names} onChange={setScopeName} />}
              <SelectCriterion label="Scale" value={scale} options={options.scales} onChange={setScale} />
              <SelectCriterion label="Kind" value={kind} options={options.kinds} onChange={setKind} />
              <SelectCriterion label="Species" value={species} options={options.species} onChange={setSpecies} />
              <SelectCriterion label="Object name" value={objectName} options={options.names} onChange={setObjectName} />
            </div>
            <p className="selector-summary">Julia will resolve <strong>{multiplicity.replace("_", " ")}</strong> target from {targetSummary}.</p>
            <button className="selector-preview-button" type="button" onClick={() => onPreview(selector())} data-testid="application-target-preview"><Eye size={15} /> Preview targets in Julia</button>
            {preview && <section className="selector-preview" data-testid="application-target-preview-result"><strong>{preview.count} target object{preview.count === 1 ? "" : "s"}</strong><code>{preview.objectIds.map(String).join(", ") || "No targets"}</code></section>}
          </fieldset>

          <fieldset><legend>Timestep</legend><div className="form-grid"><label>Mode<select value={timestepMode} onChange={(event) => setTimestepMode(event.target.value as "default" | "clock")}><option value="default">Model or environment default</option><option value="clock">Explicit clock</option></select></label>{timestepMode === "clock" && <><label>Step<input value={dt} onChange={(event) => setDt(event.target.value)} /></label><label>Phase<input value={phase} onChange={(event) => setPhase(event.target.value)} /></label></>}</div></fieldset>
        </div>
        <footer><button onClick={onClose}>Cancel</button><button className="primary" disabled={!modelType || !name.trim()} onClick={submit} data-testid="application-submit"><Check size={15} /> {mode === "add" ? "Add application" : "Apply changes"}</button></footer>
      </section>
    </div>
  );
}

export function modelDescriptorForApplication(
  models: ModelDescriptor[],
  application: ApplicationGraphNode,
) {
  return models.find((item) => item.type === application.modelType) ??
    models.find((item) => item.name === application.modelName && item.module === application.module) ??
    null;
}

export function ParameterFields({ fields, values, onChange }: { fields: ModelConstructorField[]; values: Record<string, { type: string; value: string }>; onChange: (value: Record<string, { type: string; value: string }>) => void }) {
  const firstByGroup = new Map<string, string>();
  for (const field of fields) if (field.typeParameter && !firstByGroup.has(field.typeParameter)) firstByGroup.set(field.typeParameter, field.name);
  const updateType = (field: ModelConstructorField, type: string) => {
    const names = field.typeParameter ? fields.filter((item) => item.typeParameter === field.typeParameter).map((item) => item.name) : [field.name];
    onChange(Object.fromEntries(Object.entries(values).map(([name, value]) => [name, names.includes(name) ? { ...value, type } : value])));
  };
  return <div className="parameter-list">{fields.map((field) => { const value = values[field.name] || { type: field.inferredChoice, value: "" }; const showType = !field.typeParameter || firstByGroup.get(field.typeParameter) === field.name; return <div className="parameter-row" key={field.name}><label><span>{field.name}</span><small>{field.declaredType}</small><input data-testid={`application-param-${field.name}`} value={value.value} onChange={(event) => onChange({ ...values, [field.name]: { ...value, value: event.target.value } })} /></label>{showType && <label className="parameter-type"><span>{field.typeParameter ? `${field.typeParameter} type` : "Value type"}</span><select data-testid={`application-param-type-${field.name}`} value={value.type} onChange={(event) => updateType(field, event.target.value)}>{field.choices.map((choice) => <option value={choice} key={choice}>{choice}</option>)}</select></label>}</div>; })}</div>;
}

function SelectCriterion({ label, value, options, onChange }: { label: string; value: string; options: string[]; onChange: (value: string) => void }) {
  return <label>{label}<select value={value} onChange={(event) => onChange(event.target.value)}><option value="">Any</option>{options.map((option) => <option value={option} key={option}>{option}</option>)}</select></label>;
}

export function parameterDefaults(model: ModelDescriptor | null, application?: ApplicationGraphNode) {
  if (!model) return {};
  return Object.fromEntries(model.constructor.fields.map((field) => {
    const current = application?.modelParameters[field.name];
    const type = current?.type || field.inferredChoice;
    const value = current ? current.julia : field.hasDefault ? type === "julia" ? field.defaultJulia || "" : displayDefault(field.default, type) : "";
    return [field.name, { type, value }];
  }));
}

function displayDefault(value: unknown, type: string) {
  const text = value === null || value === undefined ? "" : String(value);
  return type === "symbol" ? text.replace(/^:/, "") : text;
}

function defaultApplicationName(model: ModelDescriptor | null) { return model?.process || model?.name || "application"; }
function defaultSelector(objects: ObjectGraphNode[]): SelectorDescriptor { const scale = unique(objects.map((object) => object.scale))[0]; return { type: "Many", multiplicity: "many", criteria: scale ? { selectors: [], scale } : { selectors: [] }, julia: "" }; }
function stringCriterion(selector: SelectorDescriptor, key: string) { const value = selector.criteria[key]; return typeof value === "string" ? value : ""; }
function structuredCriterion(selector: SelectorDescriptor, key: string) { const value = selector.criteria[key]; return value && typeof value === "object" ? value as Record<string, unknown> : null; }
function selectorType(value: SelectorDescriptor["multiplicity"]) { return value === "one" ? "One" : value === "optional_one" ? "OptionalOne" : "Many"; }
function unique(values: Array<string | null>) { return [...new Set(values.filter((value): value is string => Boolean(value)))].sort(); }

import { Check, Trash2, X } from "lucide-react";
import { useMemo, useState } from "react";
import { modelDescriptorForApplication, ParameterFields, parameterDefaults } from "./ApplicationForm";
import type { ApplicationGraphNode, ApplicationOwner, InstanceDescriptor, ModelDescriptor } from "./types";

export type OverrideFormValue = {
  scope: "instance" | "object";
  instance: string;
  objectId?: unknown;
  applicationRef: ApplicationOwner;
  modelType: string;
  parameters: Record<string, { type: string; value: string }>;
};

export function OverrideForm({
  application,
  models,
  instances,
  onSubmit,
  onRemove,
  onClose,
}: {
  application: ApplicationGraphNode;
  models: ModelDescriptor[];
  instances: InstanceDescriptor[];
  onSubmit: (value: OverrideFormValue) => void;
  onRemove: (value: OverrideFormValue) => void;
  onClose: () => void;
}) {
  const matchingModels = useMemo(
    () => models.filter((model) => model.process === application.process),
    [application.process, models],
  );
  const initialModel = modelDescriptorForApplication(matchingModels, application) || matchingModels[0] || null;
  const [scope, setScope] = useState<"instance" | "object">("instance");
  const [instanceName, setInstanceName] = useState(application.targetInstances[0] || instances[0]?.name || "");
  const instance = instances.find((item) => item.name === instanceName);
  const objectIds = (instance?.objectIds || []).filter((id) => application.targetIds.some((target) => String(target) === String(id)));
  const [objectId, setObjectId] = useState<unknown>(objectIds[0] ?? "");
  const [modelType, setModelType] = useState(initialModel?.type || application.modelType);
  const model = matchingModels.find((item) => item.type === modelType) || initialModel;
  const [parameters, setParameters] = useState(() => parameterDefaults(model, application));
  const baseApplicationId = application.owner.applicationId;
  const hasInstanceOverride = Boolean(instance?.instanceOverrides.includes(baseApplicationId));
  const hasObjectOverride = Boolean(instance?.objectOverrides.some((entry) => {
    const record = entry as Record<string, unknown>;
    return String(record.object ?? record.objectId ?? "") === String(objectId) &&
      String(record.application ?? record.applicationId ?? "") === baseApplicationId;
  }));
  const canRemove = scope === "instance" ? hasInstanceOverride : hasObjectOverride;

  const selectModel = (value: string) => {
    setModelType(value);
    setParameters(parameterDefaults(matchingModels.find((item) => item.type === value) || null));
  };

  return <div className="overlay-backdrop" onMouseDown={onClose}>
    <section className="overlay-panel override-form" onMouseDown={(event) => event.stopPropagation()} data-testid="override-form">
      <header><div><strong>Create a model override</strong><span>The shared template remains unchanged outside the selected scope</span></div><button onClick={onClose}><X size={17} /></button></header>
      <div className="overlay-content override-form-content">
        <div className="override-scope-choice">
          <button className={scope === "instance" ? "active" : ""} onClick={() => setScope("instance")}><strong>One instance</strong><span>All targets of this application in one plant or object instance</span></button>
          <button className={scope === "object" ? "active" : ""} onClick={() => setScope("object")}><strong>One object</strong><span>Only one concrete execution receives the replacement model</span></button>
        </div>
        <div className="form-grid">
          <label>Instance<select value={instanceName} onChange={(event) => {
            const nextName = event.target.value;
            const nextInstance = instances.find((item) => item.name === nextName);
            const nextObject = (nextInstance?.objectIds || []).find((id) => application.targetIds.some((target) => String(target) === String(id)));
            setInstanceName(nextName);
            setObjectId(nextObject ?? "");
          }}>{instances.filter((item) => application.targetInstances.includes(item.name)).map((item) => <option key={item.name} value={item.name}>{item.name}</option>)}</select></label>
          {scope === "object" && <label>Object<select value={String(objectId)} onChange={(event) => setObjectId(event.target.value)}>{objectIds.map((id) => <option value={String(id)} key={String(id)}>{String(id)}</option>)}</select></label>}
          <label>Replacement model<select value={modelType} onChange={(event) => selectModel(event.target.value)}>{matchingModels.map((item) => <option key={item.type} value={item.type}>{item.package ? `${item.package} · ` : ""}{item.name}</option>)}</select></label>
        </div>
        {model && model.constructor.fields.length > 0 && <fieldset><legend>Model parameters</legend><ParameterFields fields={model.constructor.fields} values={parameters} onChange={setParameters} /></fieldset>}
        <div className="override-warning"><strong>{scope === "instance" ? `Override ${instanceName}` : `Override object ${String(objectId)}`}</strong><span>Julia validates that the replacement keeps the same process and declared variable contract.</span></div>
      </div>
      <footer><button onClick={onClose}>Cancel</button>{canRemove && <button className="danger" data-testid="remove-override" onClick={() => onRemove({ scope, instance: instanceName, objectId: scope === "object" ? objectId : undefined, applicationRef: application.owner, modelType, parameters })}><Trash2 size={15} /> Remove override</button>}<button className="primary" disabled={!instanceName || !modelType || (scope === "object" && !String(objectId))} onClick={() => onSubmit({ scope, instance: instanceName, objectId: scope === "object" ? objectId : undefined, applicationRef: application.owner, modelType, parameters })}><Check size={15} /> Apply override</button></footer>
    </section>
  </div>;
}

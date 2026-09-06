import { Check, Eye, X } from "lucide-react";
import { useMemo, useState } from "react";
import type { InstanceDescriptor, InstancePreview, ObjectGraphNode, TemplateDescriptor } from "./types";

export type InstanceFormValue = {
  name: string;
  templateId: string;
  rootId?: unknown;
  rootObject?: {
    objectId: string;
    configuration: {
      parent: string | null;
      scale: string | null;
      kind: string | null;
      species: string | null;
      name: string;
    };
  };
};

export function InstanceForm({
  templates,
  instances,
  objects,
  preview,
  onPreview,
  onSubmit,
  onClose,
}: {
  templates: TemplateDescriptor[];
  instances: InstanceDescriptor[];
  objects: ObjectGraphNode[];
  preview: InstancePreview | null;
  onPreview: (value: InstanceFormValue) => void;
  onSubmit: (value: InstanceFormValue) => void;
  onClose: () => void;
}) {
  const [templateId, setTemplateId] = useState(templates[0]?.id || "");
  const [name, setName] = useState("");
  const [rootMode, setRootMode] = useState<"existing" | "new">("existing");
  const roots = useMemo(() => unclaimedInstanceRoots(objects, instances), [instances, objects]);
  const [rootId, setRootId] = useState(String(roots[0]?.objectId ?? ""));
  const [newId, setNewId] = useState("");
  const [parent, setParent] = useState("");
  const [scale, setScale] = useState("");
  const [kind, setKind] = useState("");
  const [species, setSpecies] = useState("");

  const value = (): InstanceFormValue => rootMode === "existing" ? {
    name: name.trim(),
    templateId,
    rootId,
  } : {
    name: name.trim(),
    templateId,
    rootObject: {
      objectId: newId.trim(),
      configuration: {
        parent: parent || null,
        scale: scale.trim() || null,
        kind: kind.trim() || null,
        species: species.trim() || null,
        name: name.trim(),
      },
    },
  };
  const valid = Boolean(templateId && name.trim() && (rootMode === "existing" ? rootId : newId.trim()));

  return <div className="overlay-backdrop" onMouseDown={onClose}>
    <section className="overlay-panel instance-form" onMouseDown={(event) => event.stopPropagation()} data-testid="instance-form">
      <header><div><strong>Add template instance</strong><span>Mount one reusable coupled model set on an object subtree</span></div><button onClick={onClose}><X size={17} /></button></header>
      <div className="overlay-content instance-form-content">
        <div className="form-grid">
          <label>Template<select value={templateId} onChange={(event) => setTemplateId(event.target.value)} data-testid="instance-template">{templates.map((template) => <option value={template.id} key={template.id}>{template.name} · {template.source === "catalog" ? "preset" : "model-local"} · {template.applications.length} applications</option>)}</select></label>
          <label>Instance name<input value={name} onChange={(event) => setName(event.target.value)} placeholder="plant_1" data-testid="instance-name" /></label>
        </div>
        <div className="override-scope-choice">
          <button className={rootMode === "existing" ? "active" : ""} onClick={() => setRootMode("existing")}><strong>Use existing root</strong><span>All unclaimed descendants are mounted automatically</span></button>
          <button className={rootMode === "new" ? "active" : ""} onClick={() => setRootMode("new")}><strong>Create minimal root</strong><span>Create the object and mount the template atomically</span></button>
        </div>
        {rootMode === "existing" ? <label>Unclaimed root<select value={rootId} onChange={(event) => setRootId(event.target.value)} data-testid="instance-root"><option value="">Choose an object</option>{roots.map((object) => <option value={String(object.objectId)} key={object.id}>{object.name || String(object.objectId)} · {object.scale || "unscaled"}</option>)}</select></label> : <div className="form-grid">
          <label>Stable object ID<input value={newId} onChange={(event) => setNewId(event.target.value)} data-testid="instance-new-root-id" /></label>
          <label>Parent object<select value={parent} onChange={(event) => setParent(event.target.value)}><option value="">No parent</option>{objects.map((object) => <option value={String(object.objectId)} key={object.id}>{object.name || String(object.objectId)}</option>)}</select></label>
          <label>Scale<input value={scale} onChange={(event) => setScale(event.target.value)} /></label>
          <label>Kind<input value={kind} onChange={(event) => setKind(event.target.value)} /></label>
          <label>Species<input value={species} onChange={(event) => setSpecies(event.target.value)} /></label>
        </div>}
        {preview && <section className="selector-preview" data-testid="instance-preview"><strong>{preview.objectIds.length} claimed object{preview.objectIds.length === 1 ? "" : "s"}</strong><code>{preview.objectIds.map(String).join(", ")}</code>{preview.applications.map((application) => <div key={application.applicationId}><code>{application.applicationId}</code><span>{application.targetIds.length} resolved target{application.targetIds.length === 1 ? "" : "s"}</span></div>)}{preview.diagnostics.map((diagnostic) => <p key={diagnostic}>{diagnostic}</p>)}</section>}
      </div>
      <footer><button onClick={onClose}>Cancel</button><button disabled={!valid} onClick={() => onPreview(value())} data-testid="instance-preview-button"><Eye size={15} /> Preview mount</button><button className="primary" disabled={!valid} onClick={() => onSubmit(value())} data-testid="instance-submit"><Check size={15} /> Add instance</button></footer>
    </section>
  </div>;
}

export function unclaimedInstanceRoots(objects: ObjectGraphNode[], instances: InstanceDescriptor[]) {
  const claimed = new Set(instances.flatMap((instance) => instance.objectIds.map(String)));
  return objects.filter((object) => !claimed.has(String(object.objectId)));
}

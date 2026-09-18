import { Check, X } from "lucide-react";
import { objectChoiceValue, objectChoiceId, objectChoiceLabel, objectIdLabel } from "./ObjectChoice";
import { useMemo, useState } from "react";
import type { ObjectGraphNode } from "./types";

export type ObjectFormValue = {
  objectId: unknown;
  configuration: {
    parent: unknown;
    scale: string | null;
    kind: string | null;
    species: string | null;
    name: string | null;
  };
};

export function ObjectForm({
  mode,
  objects,
  object,
  onSubmit,
  onClose,
}: {
  mode: "add" | "update";
  objects: ObjectGraphNode[];
  object?: ObjectGraphNode;
  onSubmit: (value: ObjectFormValue) => void;
  onClose: () => void;
}) {
  const [objectId, setObjectId] = useState(objectIdLabel(object?.objectId ?? ""));
  const [parent, setParent] = useState(objectChoiceValue(objects.find((item) => item.id === object?.parent)?.objectId));
  const [scale, setScale] = useState(object?.scale || "");
  const [kind, setKind] = useState(object?.kind || "");
  const [species, setSpecies] = useState(object?.species || "");
  const [name, setName] = useState(object?.name || "");
  const parentOptions = useMemo(
    () => objects.filter((item) => objectChoiceValue(item.objectId) !== objectChoiceValue(mode === "update" ? object?.objectId : objectId)),
    [mode, object, objectId, objects],
  );

  const submit = () => onSubmit({
    objectId: mode === "update" ? object!.objectId : objectId.trim(),
    configuration: {
      parent: objectChoiceId(parent),
      scale: scale.trim() || null,
      kind: kind.trim() || null,
      species: species.trim() || null,
      name: name.trim() || null,
    },
  });

  return <div className="overlay-backdrop" onMouseDown={onClose}>
    <section className="overlay-panel object-form" onMouseDown={(event) => event.stopPropagation()} data-testid="object-form">
      <header><div><strong>{mode === "add" ? "Add scene object" : `Update object ${objectIdLabel(object?.objectId)}`}</strong><span>Objects define the concrete entities and topology targeted by applications</span></div><button onClick={onClose}><X size={17} /></button></header>
      <div className="overlay-content object-form-content">
        <label>Stable object ID<input value={objectId} disabled={mode === "update"} onChange={(event) => setObjectId(event.target.value)} data-testid="object-id" /></label>
        <label>Parent object<select value={parent} onChange={(event) => setParent(event.target.value)}><option value="">No parent</option>{parentOptions.map((item) => <option key={item.id} value={objectChoiceValue(item.objectId)}>{objectChoiceLabel(item)} · {item.scale || "unscaled"}</option>)}</select></label>
        <div className="form-grid">
          <label>Scale<input value={scale} onChange={(event) => setScale(event.target.value)} /></label>
          <label>Kind<input value={kind} onChange={(event) => setKind(event.target.value)} /></label>
          <label>Species<input value={species} onChange={(event) => setSpecies(event.target.value)} /></label>
          <label>Display name (optional)<input value={name} placeholder={objectId || "Uses the object ID"} onChange={(event) => setName(event.target.value)} /></label>
        </div>
      </div>
      <footer><button onClick={onClose}>Cancel</button><button className="primary" disabled={!objectId.trim()} onClick={submit} data-testid="object-submit"><Check size={15} /> {mode === "add" ? "Add object" : "Apply changes"}</button></footer>
    </section>
  </div>;
}

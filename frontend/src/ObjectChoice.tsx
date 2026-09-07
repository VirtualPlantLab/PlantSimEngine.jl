import type { ObjectGraphNode } from "./types";

// A select element stores strings; retain the original ID type in its value.
export function objectChoiceValue(id: unknown): string {
  return id === null || id === undefined ? "" : JSON.stringify(canonicalValue(id));
}

function canonicalValue(value: unknown): unknown {
  if (Array.isArray(value)) return value.map(canonicalValue);
  if (value && typeof value === "object") return Object.fromEntries(
    Object.entries(value).sort(([left], [right]) => left.localeCompare(right)).map(([key, item]) => [key, canonicalValue(item)]),
  );
  return value;
}

export function objectChoiceId(value: string): unknown {
  return value ? JSON.parse(value) : null;
}

export function objectChoiceLabel(object: ObjectGraphNode): string {
  const id = objectIdLabel(object.objectId);
  return object.name && object.name !== id ? `${object.name} · ID: ${id}` : id;
}

export function objectIdLabel(id: unknown): string {
  if (!id || typeof id !== "object") return String(id);
  const value = id as Record<string, unknown>;
  if (value.type === "Tuple" && Array.isArray(value.items)) return `(${value.items.map(objectIdLabel).join(", ")})`;
  if (value.type === "NamedTuple" && Array.isArray(value.items) && Array.isArray(value.names)) {
    const names = value.names;
    return `(${value.items.map((item, index) => `${names[index]}=${objectIdLabel(item)}`).join(", ")})`;
  }
  if (value.type === "Pair") return `${objectIdLabel(value.first)} => ${objectIdLabel(value.second)}`;
  if (value.type === "Symbol") return `:${String(value.value)}`;
  if ("value" in value) return objectIdLabel(value.value);
  return String(value.repr ?? JSON.stringify(id));
}

export function scopeObjectId(scope: Record<string, unknown> | null, objects: ObjectGraphNode[]): unknown {
  if (!scope || scope.type !== "Scope") return null;
  if ("id" in scope) return scope.id;
  const root = objects.find((object) => object.instance === scope.name &&
    !objects.some((parent) => parent.id === object.parent && parent.instance === scope.name));
  return root?.objectId ?? scope.name;
}

export function ObjectChoice({ label, value, objects, onChange, emptyLabel = "Any" }: {
  label: string;
  value: string;
  objects: ObjectGraphNode[];
  onChange: (value: string) => void;
  emptyLabel?: string;
}) {
  return <label>{label}<select value={value} onChange={(event) => onChange(event.target.value)}>
    <option value="">{emptyLabel}</option>
    {objects.map((object) => <option key={objectChoiceValue(object.objectId)} value={objectChoiceValue(object.objectId)}>{objectChoiceLabel(object)}</option>)}
  </select></label>;
}

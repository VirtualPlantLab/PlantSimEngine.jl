import { describe, expect, it } from "vitest";
import { objectChoiceId, objectChoiceLabel, objectChoiceValue, objectIdLabel, scopeObjectId } from "./ObjectChoice";
import { unclaimedInstanceRoots } from "./InstanceForm";
import type { InstanceDescriptor, ObjectGraphNode } from "./types";

function object(id: unknown, name: string | null = null): ObjectGraphNode {
  return { id: `object:${JSON.stringify(id)}`, objectId: id, name, scale: null, kind: null, species: null, instance: null, parent: null, children: [], hasGeometry: false, hasStatus: false };
}

describe("object identity in editor choices", () => {
  it("distinguishes numeric IDs from text IDs across form submission", () => {
    expect(objectChoiceValue(42)).not.toBe(objectChoiceValue("42"));
    expect(objectChoiceId(objectChoiceValue(42))).toBe(42);
    expect(objectChoiceId(objectChoiceValue("42"))).toBe("42");
    expect(objectChoiceId("")).toBeNull();
    const objects = [object(42), object("42")];
    expect(unclaimedInstanceRoots(objects, [{ objectIds: [42] }] as InstanceDescriptor[])).toEqual([objects[1]]);
  });

  it("shows the ID beside duplicate display labels, and uses the ID for unnamed objects", () => {
    expect(objectChoiceLabel(object(42, "Coffee plant"))).toBe("Coffee plant · ID: 42");
    expect(objectChoiceLabel(object(73, "Coffee plant"))).toBe("Coffee plant · ID: 73");
    expect(objectChoiceLabel(object(42))).toBe("42");
  });

  it("finds an instance root independently of its display name", () => {
    const root = { ...object(42, "Coffee plant"), instance: "coffee_a" };
    const leaf = { ...object(73), instance: "coffee_a", parent: root.id };
    expect(scopeObjectId({ type: "Scope", name: "coffee_a" }, [leaf, root])).toBe(42);
    expect(scopeObjectId({ type: "Scope", id: "42" }, [root])).toBe("42");
  });

  it("preserves tagged compound IDs regardless of JSON property order", () => {
    const id = { type: "ObjectId", value: { type: "Tuple", items: [{ type: "Symbol", value: "leaf" }, 42] } };
    const reordered = { value: { items: [{ value: "leaf", type: "Symbol" }, 42], type: "Tuple" }, type: "ObjectId" };
    expect(objectChoiceValue(id)).toBe(objectChoiceValue(reordered));
    expect(objectChoiceId(objectChoiceValue(id))).toEqual(id);
    expect(objectIdLabel(id)).toBe("(:leaf, 42)");
  });
});

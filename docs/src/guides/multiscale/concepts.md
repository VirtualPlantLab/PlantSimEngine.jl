# How Multiscale Composite Models Execute

An **application** is a model configured with `ModelSpec`: it says where the
model runs and where its inputs come from. For example,
`ModelSpec(model; on=Many(scale=:Leaf))` runs that model once on each leaf.
Each leaf keeps its own values in `Status`. You define the objects, their
labels, and their parent relationships when building the simulation.

Selectors choose objects by these labels and relationships. `Self()` means
the object whose model is currently running. `SelfPlant()` limits a search
to that object's plant, starting from the top of its structure.
`SceneScope()` allows the search to include the whole simulation. Wrap a
selection in `One`, `OptionalOne`, or `Many` to require exactly one match,
allow zero or one, or accept a collection.

Common choices are:

| Relationship | Pattern |
| --- | --- |
| application targets every leaf | `ModelSpec(model; on=Many(scale=:Leaf))` |
| input from this same object | omit `inputs` when exactly one model supplies the matching output |
| input from one ancestor | `One(Ancestor(scale=:Plant))` |
| input from this plant's leaves | `Many(scale=:Leaf, within=SelfPlant())` |
| input from shared soil | `One(scale=:Soil, within=SceneScope())` |
| optional organ with a known ID | `OptionalOne(id=:fruit, within=SelfPlant())` |

For a model running on a leaf, `Self()` means that leaf, not its plant or its
species. Use object IDs and labels to select specific objects or groups.
`Scope(:plant_a)` searches the root and descendants of the instance called
`:plant_a`. To choose a root directly by its object ID, use
`Scope(ObjectId(:plant_a))`. An object's display name does not define a scope
or affect selection.

Saved results identify the application, object, and variable. Each leaf's
history therefore stays separate, including when you use the same process
more than once. Removing an organ stops its future calculations but keeps
the results already saved for it.

Before a long run, use `Diagnostics.explain_objects` to check the plant
structure, `Diagnostics.explain_applications` to check where models run, and
`Diagnostics.explain_bindings` to check where they read their inputs.

# How Multiscale Scenes Execute

One application executes once for every object selected by `AppliesTo`. State
belongs to the object, while topology and labels belong to the scenario.
`Self()` is the current object, `SelfPlant()` is its plant-instance root, and
`SceneScope()` is scene-wide. Cardinality wrappers decide whether zero, one,
or many matches are valid.

More objects mean more qualified streams. Removing an object stops future
execution but preserves its accepted historical samples.

Canonical selector patterns are:

| Relationship | Pattern |
| --- | --- |
| application targets every leaf | `AppliesTo(Many(scale=:Leaf))` |
| input from this same object | omit `Inputs` when the producer is unique |
| input from one ancestor | `One(Ancestor(scale=:Plant))` |
| input from this plant's leaves | `Many(scale=:Leaf, within=SelfPlant())` |
| input from shared soil | `One(scale=:Soil, within=SceneScope())` |
| optional named organ | `OptionalOne(name=:fruit, within=SelfPlant())` |

`Self()` always means the current target object. It never implicitly means the
model, process, species, or plant. Prefer object IDs and labels for identity,
and use `Scope(name)` only when the scene explicitly defines that scope.

One application produces a separate stream for every selected object and
output variable. Stream keys also include application identity, so repeated
applications of the same process cannot overwrite each other. Use
`explain_scene_applications`, `explain_objects`, and `explain_bindings` to
verify target and source multiplicities before a long run.

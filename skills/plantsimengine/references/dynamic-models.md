# Lifecycle, initializers, and distributed outputs

Read this reference only when a simulation changes topology or geometry at
runtime, creates MTG organs, initializes newborn objects, or writes outputs to
other objects.

## Preserve identity and use lifecycle APIs

`ObjectId` is stable runtime identity. Keep structural identity separate from
functional state: dormancy, activity, senescence, and similar behavior usually
belong in status variables and model kernels, not in repeated removal and
recreation of objects.

Use:

- `register_object!` when the caller already owns a fully initialized `Object`;
- `remove_object!` to remove a registered object;
- `reparent_object!` to change topology;
- `move_object!` or `update_geometry!` for spatial changes;
- `mark_environment_binding_dirty!` only when a custom backend change cannot
  be expressed through the higher-level helpers.

Structural changes refresh affected targets, bindings, hard-call buffers,
writers, and schedules after the application that made the change. A new
object may run applications that remain later in the same timestep, never
applications that already ran. Removed objects keep retained output history.

Do not mutate registry topology, parent links, or geometry behind these APIs;
that bypasses cache and environment invalidation.

## MTG-backed organ creation

Use `add_organ!` when the `CompositeModel` was adapted from a
MultiScaleTreeGraph and a growth model creates a new organ:

```julia
new_leaf_status = add_organ!(
    source_node(context),
    runtime_model(context),
    :+,
    :Leaf,
    2;
    index=next_leaf_index,
    initial_status=(
        mass=zero(status.mass),
        area=zero(status.area),
    ),
)
```

`add_organ!` creates the node, reuses the model's MTG status policy, applies
initial values, attaches the status, and registers the runtime object. Do not
separately register the returned status/object.

Keep initial values generic and scientifically explicit. Do not seed a
newborn with arbitrary nonzero values merely to satisfy a downstream type.

## One-shot initializers

An initializer is a normally scheduled application that may additionally run
once on the object created during the current lifecycle event.

Declare it as a call binding:

```julia
ModelSpec(
    OrganCreator();
    name=:creator,
    on=One(scale=:Plant),
    calls=(
        leaf=Initializer(
            One(
                scale=:Leaf,
                within=Subtree(),
                application=:leaf_initializer,
            ),
        ),
    ),
)
```

After creating/registering the object inside the creator kernel:

```julia
initialized_status = run_initializer!(context, :leaf, new_leaf_status)
```

Initializer rules:

- the selector must be `One(...)` and must name one scheduled application;
- invoke it only for an object registered during the current lifecycle event;
- one call name/object pair is one-shot, even when the initializer fails after
  mutation;
- initializer execution does not publish an extra mid-step retained sample or
  distributed/environment update;
- use `run_initializer!`, not `run_call!` or `call_targets`, for this mode.

If one initial value depends on a temporal source, only an intentional
`PreviousTimeStep` policy has defined newborn semantics.

## Distributed outputs

Use distributed outputs when one application computes values for a declared
set of destination objects—for example, a scene radiation model assigning
incident radiation to leaves. Do not use them as a substitute for ordinary
consumer input bindings.

Declare destination groups on the application:

```julia
ModelSpec(
    SceneRadiation();
    name=:scene_radiation,
    on=One(scale=:Scene),
    outputs_to=(
        leaves=OutputTo(
            Many(scale=:Leaf, within=SceneScope());
            vars=(
                incident_par=Default(0.0),
                absorbed_par=Required(Real),
            ),
        ),
    ),
)
```

Inside `run!`, obtain the compiled target view and assign by object identity:

```julia
targets = output_targets(context, :leaves)
assign_outputs!(
    targets,
    object_ids_from_solver,
    (
        incident_par=incident_values,
        absorbed_par=absorbed_values,
    ),
)
```

Use `Default(value)` when the destination variable may be created with a real
default. Use `Required(T)` when every destination status must already own it.
Destination selectors describe objects only; do not add producer `process`,
`application`, `var`, temporal policy, or status-source criteria to an
`OutputTo` selector.

The identity-aware `assign_outputs!` form is preferable when an external
solver returns rows in a different order. Do not assume that collection order
has biological meaning.

## Dynamic validation checklist

- The new object receives a stable, non-colliding `ObjectId` and correct
  parent/labels.
- Its status contains every required variable with intended numeric types.
- Initializer and normally scheduled execution are not accidentally doubled.
- Applications already completed in the timestep are not expected to rerun.
- Removed-object history remains available when outputs are retained.
- Reparenting refreshes selectors whose scope depends on ancestry.
- Movement/geometry changes refresh the intended spatial environment handles.
- `Diagnostics.explain_applications`, `explain_bindings`, `explain_calls`, and
  `explain_schedule` match the post-change topology.
- One organ and many-organ batches are tested.

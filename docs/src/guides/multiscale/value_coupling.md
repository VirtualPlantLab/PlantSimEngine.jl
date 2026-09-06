# Coupling Values Across Objects

To read values from other objects, describe which objects supply the input:

- `One(...)` requires exactly one source object, such as the plant to which
  a leaf belongs.
- `OptionalOne(...)` allows zero or one source object.
- `Many(...)` supplies a collection, such as the areas of all leaves on a
  plant, ordered by object ID.

Set `var=` when the source variable has a different name from the input.
Set `application=` when you need to specify which model application supplies
the value, for example when using the same process more than once.

PlantSimEngine shares these values by reference: the receiving model reads
the current source values without copying them. A collection with the same
value type throughout uses `RefVector`; one with different types uses
`ObjectRefVector`. These collections are called **input carriers** in the
diagnostics. Use `Diagnostics.input_value` to read the values,
`Diagnostics.input_carrier` to inspect their container, and
`Diagnostics.explain_bindings` to see where they come from.

## Keep identities aligned with values

If a model only needs to sum or multiply the values in a `Many` input, use
the input's `status` field as usual. If it also needs to know which leaf or
other object each value belongs to, call `bound_input` using `context`, the
information PlantSimEngine passes to each `run!` call:

```julia
function PlantSimEngine.run!(model, status, environment, constants, context)
    irradiance = bound_input(context, :irradiance)

    @inbounds for index in eachindex(irradiance)
        object_id = object_ids(irradiance)[index]
        value = irradiance[index]
        # Use object_id and value as one aligned pair.
    end
    return nothing
end
```

The returned `BoundMany` gives access to both values and their object IDs,
without copying either. Its values are the same ones available through
`status.irradiance`. Their order follows `ObjectId`, not the position of an
organ on the plant. Use `irradiance[ObjectId(:leaf_12)]` to read a named leaf's
value, or an integer index to read a position in the collection.

Call `bound_input` each time the model runs. PlantSimEngine may replace the
collection after an object is added, removed, or moved to a different parent,
so do not store it in your model for later calls.

## Publish one computation to many objects

Some models run once for a scene or plant but compute one value per organ.
For example, a light model may calculate illumination for the whole scene
and then store each leaf's irradiance on that leaf. Declare these
destinations with `outputs_to`, and use object IDs to assign each result to
the right leaf:

```julia
PlantSimEngine.@process "scene light" verbose = false

struct SceneLightModel{F} <: AbstractScene_LightModel
    solve::F
end

PlantSimEngine.inputs_(::SceneLightModel) = NamedTuple()
PlantSimEngine.outputs_(::SceneLightModel) = NamedTuple()

function PlantSimEngine.run!(
    model::SceneLightModel,
    status,
    environment,
    constants,
    context,
)
    targets = output_targets(context, :leaves)
    result = model.solve(
        runtime_model(context),
        environment,
        object_ids(targets),
    )
    assign_outputs!(targets, result; id=:object_id)
    return nothing
end
```

Here `solve` calls your scene light calculation and returns its results as a
table supported by Tables.jl, such as a `DataFrame`. The table needs an
`object_id` column and one column for each declared output, for example
`incident_par` and `absorbed_par`. Rows may be in any order:
`assign_outputs!` uses `ObjectId` to put each result on the right leaf.

Declare the destinations on the scene application:

```julia
light_application = ModelSpec(
    SceneLightModel(solve_light);
    name=:scene_light,
    on=One(scale=:Scene),
    outputs_to=(
        leaves=OutputTo(
            Many(scale=:Leaf, within=SceneScope());
            vars=(
                incident_par=Default(0.0),
                absorbed_par=Default(0.0),
            ),
        ),
    ),
)
```

Inside `run!`, `targets.columns.incident_par` and
`targets.columns.absorbed_par` give direct access to the selected leaves'
values. `object_ids(targets)` lists their IDs in the same order; this list
cannot be modified. Write directly by position only if your calculation
already uses that exact order. For a separate result table with its own IDs,
use `assign_outputs!` to match the rows to leaves.

## Consume those values normally

The receiving leaf model remains an ordinary PlantSimEngine model:

```julia
PlantSimEngine.@process "leaf assimilation" verbose = false

struct LeafAssimilation <: AbstractLeaf_AssimilationModel end

PlantSimEngine.inputs_(::LeafAssimilation) = (
    absorbed_par=Required(Float64),
)
PlantSimEngine.outputs_(::LeafAssimilation) = (assimilation=0.0,)

function PlantSimEngine.run!(
    ::LeafAssimilation,
    status,
    environment,
    constants,
    context,
)
    # This coefficient is arbitrary and only illustrates value coupling.
    status.assimilation = 0.01 * status.absorbed_par
    return nothing
end

applications = (
    ModelSpec(
        LeafAssimilation();
        name=:leaf_assimilation,
        on=Many(scale=:Leaf),
    ),
    light_application,
)
```

PlantSimEngine knows that `:scene_light` supplies `:absorbed_par` for each
selected leaf and that `:leaf_assimilation` needs it. It connects the two and
runs the light calculation first, even though the assimilation model appears
first in the tuple. You do not need an extra model to copy the light values
or an `after=:scene_light` instruction to set their order.

## Rules for assigning results

`assign_outputs!` supports two public forms:

```julia
assign_outputs!(targets, result_table; id=:object_id)
assign_outputs!(targets, result_ids, result_columns)
```

The first accepts any row or column table supported by Tables.jl. The second
takes an `AbstractVector` of IDs and a `NamedTuple` of value columns, which
is useful when your solver already returns separate arrays. Both forms use
the same rules:

| Result content | Behavior |
|---|---|
| One row for every current destination | Required |
| Unknown, duplicate, extra, or missing IDs | Rejected before any destination value changes |
| Every variable declared by `OutputTo` | Required |
| Additional columns such as solver metadata | Ignored |
| Result columns sharing memory with destination columns | Rejected, except assigning a column to itself in exactly the same order |

Only `coverage=:exact` is supported: you must supply one result for every
selected object. If the light solver skips an organ because it has no
geometry or has been removed from its scene, decide how to handle it. Either
return an appropriate value or exclude that organ from the destination
selector. PlantSimEngine will report a missing result instead of keeping an
old value or substituting zero.

## Reuse stable columns efficiently

PlantSimEngine remembers how the result rows match the destination objects.
You can reuse the same ID vector to avoid repeating this work, but its IDs
and their order must remain unchanged. Update only the value columns. If
the objects or their order change, provide a new ID vector. After an object
is added, removed, or reparented, PlantSimEngine automatically rebuilds the
match on the next call.

When all destination values have the same concrete Julia type, PlantSimEngine
uses `RefVector` columns. With a stable ID order that already matches the
destinations, assignments can run without new memory allocations after
compilation. If the destinations hold different types, PlantSimEngine uses
`ObjectRefVector` and converts each value to its destination type. Both use
the same API; keeping types consistent is preferable when assigning results
to many organs.

Call `output_targets` each time your model runs, just as with `bound_input`.
Do not store the returned `OutputTargets` in the model: the selected objects
may change as the plant grows.

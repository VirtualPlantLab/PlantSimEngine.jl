# Coupling Values Across Objects

- `One(...)` requires exactly one source.
- `OptionalOne(...)` accepts zero or one.
- `Many(...)` supplies a stable object-ID ordered carrier.

Use `var=` to rename a source and `application=` to distinguish repeated
processes. Homogeneous many-source values use a `RefVector`; heterogeneous
values use an object-aware reference carrier. Inspect both through
`Diagnostics.input_carrier`, `Diagnostics.input_value`, and `Diagnostics.explain_bindings`, not internal fields.

## Keep identities aligned with values

A model that only reduces or broadcasts over a `Many` input can keep using the
ordinary status field. When a model must associate a value with the object that
owns it, request the identity-aware view from the current `RunContext`:

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

`BoundMany` wraps the same live `RefVector` or heterogeneous carrier already
installed in `status.irradiance`; it does not copy values or identities.
Positions follow compiled `ObjectId` order and have no botanical meaning.
Identity lookup is unambiguous when written as
`irradiance[ObjectId(:leaf_12)]`; integer indexing remains positional.

Obtain the view during each model invocation. Lifecycle refresh keeps the
current view aligned when possible and may replace it after insertion,
removal, or reparenting, so model code must not cache a `BoundMany` across a
lifecycle barrier.

## Publish one computation to many objects

Some models execute once on a scene or plant but compute one value per organ.
A light model is the typical example: the scene application owns the
calculation and cadence, while each leaf owns its local irradiance values.
Declare that relationship with `outputs_to`, then publish the solver result by
object identity:

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

Here `solve` is an adapter around the scene solver. It returns any
Tables.jl-compatible value with an `object_id` column and the declared result
columns, for example `incident_par` and `absorbed_par`. Rows may arrive in any
order because `assign_outputs!` maps them to destinations by `ObjectId`.

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

Inside the kernel, `targets.columns.incident_par` and
`targets.columns.absorbed_par` are the live destination carriers.
`object_ids(targets)` is the aligned, read-only identity view. Direct
positional writes are appropriate only when the producing algorithm is already
using that exact identity order; identified external results should go through
`assign_outputs!`.

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

The compiler knows that `:scene_light` owns `:absorbed_par` on each selected
leaf. It binds the leaf input and schedules the scene writer before the leaf
consumer even though the consumer appears first in the tuple. No per-leaf copy
model, `from_status=true`, or manual `after=:scene_light` declaration is
needed.

## Assignment contract

`assign_outputs!` supports two public forms:

```julia
assign_outputs!(targets, result_table; id=:object_id)
assign_outputs!(targets, result_ids, result_columns)
```

The first accepts any Tables.jl-compatible column or row table. The second
accepts an `AbstractVector` of IDs and a `NamedTuple` of columns, avoiding the
table adapter on a stable columnar path. Both forms use the same rules:

| Result content | Behavior |
|---|---|
| One row for every current destination | Required |
| Unknown, duplicate, extra, or missing IDs | Rejected before mutation |
| Every variable declared by `OutputTo` | Required |
| Additional columns such as solver metadata | Ignored |
| Source columns overlapping destination storage | Rejected, except exact-order self-assignment of the same column |

Only `coverage=:exact` is supported. A filtered, abscised, or non-geometrized
organ must therefore be handled deliberately by the scene adapter or excluded
by the destination selector; PlantSimEngine never silently retains an old
value or substitutes zero for a missing result.

## Reuse stable columns efficiently

PlantSimEngine caches the result-row permutation by the identity of the ID
column. Reusing the same ID vector promises that its IDs and order remain
unchanged; mutate only the result value columns in place. Replace the ID vector
when membership or ordering changes. A lifecycle refresh invalidates this
cache automatically, and the next invocation rebuilds it against the refreshed
destinations.

Homogeneous destination values use typed `RefVector` columns and the stable
exact-order path can run without allocations after compilation. If selected
statuses hold different concrete value types, PlantSimEngine falls back to an
`ObjectRefVector` and converts against each destination reference. The public
API is identical, but the homogeneous representation is the performance path
to prefer for large per-organ assignments.

Like `BoundMany`, an `OutputTargets` view belongs to the current invocation and
lifecycle generation. Obtain it from `RunContext` each time rather than storing
it in the model.

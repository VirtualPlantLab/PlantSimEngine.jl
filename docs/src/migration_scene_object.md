# Migrating To The Scene/Object API

## Refining early Scene/Object code

The stabilized public surface makes several early Scene/Object behaviors
explicit:

| Early spelling or behavior | Stabilized API |
| --- | --- |
| `Self()` searched self and descendants | `Self()` selects only the current object; use `Subtree()` for self plus descendants |
| omitted `tracked_outputs` retained everything | use explicit `outputs=:all`; the safe default is `outputs=:none` |
| `tracked_outputs=requests` | `outputs=requests` |
| `OutputRequest(:Leaf, :x; process=:p)` | `OutputRequest(Many(scale=:Leaf), :x; application=:app)` |
| repeated unnamed applications gained numbered IDs | name every repeated application with `ModelSpec(...; name=...)` |
| calling `run!(scene)` again implicitly looked like continuation | use `continue!(simulation)` or `step!(simulation)` |
| compiler/cache types imported from the default namespace | qualify them through `PlantSimEngine.Advanced` |

`tracked_outputs` remains a targeted deprecation bridge. It maps `nothing` to
`outputs=:all`, an empty request vector to `outputs=:none`, and requests to the
equivalent `outputs` value. `process=` in `OutputRequest` is likewise a bridge
to application-qualified requests. Singular scenario-level `Inputs` and
`Calls` also deprecate process-only filters; model-authored `Input`/`Call`
defaults may still discover a process because they cannot know scenario
application names. `Many(process=...)` remains an explicit discovery query for
collecting several applications, such as the mounted applications from several
instances. New singular scenario references should use `application=`. The
deprecated bridges are scheduled for removal in PlantSimEngine 0.15.

Calling `run!(scene; ...)` always creates a fresh result timeline starting at
step one, even when object status has already been mutated by an earlier run.
Continue the same timeline, environment position, temporal histories, and
multirate phase with:

```julia
simulation = run!(scene; steps=24, outputs=requests)
continue!(simulation; steps=24)
step!(simulation)
@assert current_step(simulation) == 49
```

The scene/object API replaces the historical multiscale mapping system with
one object-address graph.

New scenario code should be organized around:

```julia
Scene
Object
ModelSpec
AppliesTo
Inputs
Calls
Updates
TimeStep
Environment
```

Model implementations do not need to know about scenes, plants, objects, or
timesteps. They keep the existing kernel contract:

```julia
inputs_(model)
outputs_(model)
dep(model)
meteo_inputs_(model)
meteo_outputs_(model)
run!(model, models, status, meteo, constants, extra)
```

This page maps the legacy configuration concepts to their scene/object
equivalents.

## Scenario Structure

Legacy simulations split configuration between `ModelMapping` and
`MultiScaleModel`. The unified API stores runtime entities in one `Scene`:

`ModelMapping` has been removed. Historical code must be translated to the
scene/object form below.

```julia
scene = Scene(
    Object(:scene; scale=:Scene, kind=:scene),
    Object(:plant_1; scale=:Plant, kind=:plant, parent=:scene),
    Object(:leaf_1; scale=:Leaf, kind=:plant, parent=:plant_1),
    Object(:soil; scale=:Soil, kind=:soil, parent=:scene);
    applications=(
        ModelSpec(LeafModel(); name=:leaf_model) |>
        AppliesTo(Many(scale=:Leaf)),

        ModelSpec(SoilModel(); name=:soil_model) |>
        AppliesTo(One(scale=:Soil)),
    ),
    environment=(T=25.0, Rh=0.6, Wind=1.0),
)
```

`Object` labels describe runtime entities. They do not prescribe plant
topology. A plant may use any hierarchy of plants, axes, internodes, segments,
leaves, roots, fruits, or application-specific objects.

### Existing MTG Topologies

An existing MTG can be adapted without rebuilding its topology manually:

```julia
scene = Scene(
    mtg;
    applications=applications,
    environment=meteo,
    kind=node_kind,
    species=node_species,
    geometry=node_geometry,
)
```

`objects_from_mtg(mtg; ...)` exposes the intermediate object list when it is
useful to inspect or modify labels before constructing the scene. By default,
the adapter uses MTG node ids and scales, and reuses an existing
`:plantsimengine_status` attribute when present.

## Multiscale Inputs

Replace `MultiScaleModel(...)` variable mappings with consumer-side
`Inputs(...)`.

Legacy:

```julia
MultiScaleModel(
    AllocationModel(),
    [:leaf_carbon => [:Leaf => :leaf_carbon]],
)
```

Unified:

```julia
ModelSpec(AllocationModel(); name=:allocation) |>
    AppliesTo(Many(scale=:Plant)) |>
    Inputs(
        :leaf_carbon => Many(
            scale=:Leaf,
            within=Subtree(),
            var=:leaf_carbon,
        ),
    )
```

`Self()` selects only the object where the consumer runs. A plant-scale
allocation model uses `Subtree()` to read leaves below that plant. Use
`SceneScope()` for scene-wide aggregation and `SelfPlant()` to select the
nearest containing plant and its subtree from an organ.

Same-object renaming uses the same syntax:

```julia
Inputs(
    :consumer_name => One(
        within=Self(),
        application=:producer,
        var=:producer_name,
    ),
)
```

Same-rate bindings use shared references or reference vectors when possible.
Cross-rate bindings use typed temporal streams.

## Scene-Wide Values

Use an input selector on the consuming application:

```julia
ModelSpec(SceneWaterBalance(); name=:scene_water) |>
    AppliesTo(One(scale=:Scene)) |>
    Inputs(
        :leaf_transpiration => Many(
            kind=:plant,
            scale=:Leaf,
            within=SceneScope(),
            application=:transpiration,
            var=:transpiration,
        ),
    )
```

The compiler chooses the carrier. Scenario authors declare the source objects,
source variable, and temporal policy rather than a route implementation.

## Manual Hard Calls

Use `Calls(...)` when a parent model must control child execution.

```julia
ModelSpec(SceneEnergyBalance(); name=:scene_energy) |>
    AppliesTo(One(scale=:Scene)) |>
    Calls(
        :leaf_energy => Many(
            kind=:plant,
            scale=:Leaf,
            within=SceneScope(),
            application=:energy_balance,
        ),
        :soil => One(
            kind=:soil,
            scale=:Soil,
            within=SceneScope(),
            application=:soil_water,
        ),
    )
```

The parent model controls execution:

```julia
function PlantSimEngine.run!(model::SceneEnergyBalance, models, status, meteo,
                             constants, extra)
    leaf_targets = call_targets(extra, :leaf_energy)

    for iteration in 1:model.max_iterations
        for target in leaf_targets
            run_call!(target; meteo=trial_meteo(model, status))
        end
        converged(model, status, leaf_targets) && break
    end

    for target in leaf_targets
        run_call!(target; meteo=accepted_meteo(model, status), publish=true)
    end
    return nothing
end
```

`run_call!` defaults to `publish=false`. Trial calls mutate target status but
do not append temporal samples or write environment outputs. The accepted
state must use `publish=true`.

## Multiple Plants And Species

Represent repeated plant configurations with `ObjectTemplate` and
`ObjectInstance`.

```julia
oil_palm = ObjectTemplate(
    (
        ModelSpec(LeafEnergy()) |>
        AppliesTo(Many(scale=:Leaf)),

        ModelSpec(Allocation()) |>
        AppliesTo(One(scale=:Plant)) |>
        Inputs(
            :leaf_carbon => Many(
                scale=:Leaf,
                within=Subtree(),
                var=:leaf_carbon,
            ),
        ),
    );
    kind=:plant,
    species=:oil_palm,
)

palm_1 = ObjectInstance(
    :palm_1,
    oil_palm;
    root=Object(:plant_1; scale=:Plant, parent=:scene),
    objects=(Object(:palm_1_leaf_1; scale=:Leaf, parent=:plant_1),),
)

palm_2 = ObjectInstance(
    :palm_2,
    oil_palm;
    root=Object(:plant_2; scale=:Plant, parent=:scene),
    objects=(Object(:palm_2_leaf_1; scale=:Leaf, parent=:plant_2),),
)

scene = Scene(
    Object(:scene; scale=:Scene, kind=:scene),
    palm_1,
    palm_2,
)
```

Unmodified instances share model objects and parameters. Use instance
overrides for one plant and `Override(...)` for exceptional organs.

## Multirate Inputs

Replace `TimeStepModel(...)` with `TimeStep(...)`. Put temporal policy and
window information on the consuming `Inputs(...)` selector.

```julia
ModelSpec(HourlyLeafModel(); name=:leaf_flux) |>
    AppliesTo(Many(scale=:Leaf)) |>
    TimeStep(Hour(1))

ModelSpec(DailyPlantModel(); name=:daily_plant) |>
    AppliesTo(Many(scale=:Plant)) |>
    Inputs(
        :leaf_fluxes => Many(
            scale=:Leaf,
            within=Subtree(),
            application=:leaf_flux,
            var=:flux,
            policy=Integrate(),
            window=Day(1),
        ),
    ) |>
    TimeStep(Day(1))
```

Use `HoldLast()`, `Interpolate()`, `Integrate()`, or `Aggregate()` according to
the physical meaning of the input. `PreviousTimeStep(:x) => selector` expresses
an explicit lag and breaks a same-timestep dependency cycle.

If the input selector omits `policy=...`, the scene compiler uses the
producer's `output_policy(...)` trait for the selected source variable when the
publisher is unique. An explicit selector policy always wins over the trait.

If a model defines `timespec(::Type{<:MyModel})`, the scene scheduler uses that
cadence when the application has no explicit `TimeStep(...)`. A scenario-level
`TimeStep(...)` always wins over the model trait.

If the clock falls back to the scene base step, `timestep_hint(...)` required
bounds are validated against that base step. The hint is a compatibility
constraint, not a scheduling override.

## Ordered Variable Updates

When several models intentionally write the same variable, declare the order
on the later application:

```julia
ModelSpec(CarbonAllocation(); name=:allocation) |>
    AppliesTo(Many(scale=:Leaf))

ModelSpec(LeafPruning(); name=:pruning) |>
    AppliesTo(Many(scale=:Leaf)) |>
    Updates(:leaf_biomass; after=:allocation)
```

Do not encode this coupling in either model implementation. The scenario owns
the writer order.

## Environment And Microclimate

Models declare environment variables with `meteo_inputs_` and
`meteo_outputs_`. The scene binds each object to the active environment
backend:

```julia
ModelSpec(LeafEnergy(); name=:leaf_energy) |>
    AppliesTo(Many(scale=:Leaf)) |>
    Environment(provider=:grid)
```

Spatial bindings are cached. The default resolver uses the object's geometry,
then the nearest ancestor geometry, then the backend's global behavior.
Changing geometry invalidates only affected environment bindings.

Per-model source remapping also moves to `Environment(...)`:

```julia
ModelSpec(LeafGasExchange(); name=:gas_exchange) |>
    AppliesTo(Many(scale=:Leaf)) |>
    Environment(provider=:global, sources=(CO2=:Ca,))
```

The model still declares and reads `CO2`; the scene samples `Ca` from the
active environment backend and exposes it to the model as `meteo.CO2`.
`explain_environment_bindings(...)` reports both `required_inputs` and
`source_inputs`, so remapped meteorology is visible to users and agents.

Model authors can also provide default source remaps with
`meteo_hint(::Type{<:Model}) = (bindings=(CO2=(source=:Ca,),),)`. Scene
applications use those defaults when the scenario does not provide an explicit
source for the same variable. `Environment(; sources=...)` remains the
scenario-level override.

For global `Weather` tables, sampling follows the application's
`TimeStep(...)`. A slower model receives a PlantMeteo windowed sample using its
`meteo_hint` reducer and window instead of receiving only the current raw
weather row. A scenario source override preserves that reducer:

```julia
meteo_hint(::Type{<:GasExchange}) = (
    bindings=(CO2=(source=:Ca, reducer=MeanReducer()),),
)

ModelSpec(GasExchange()) |>
    AppliesTo(Many(scale=:Leaf)) |>
    TimeStep(Hour(2)) |>
    Environment(provider=:global, sources=(CO2=:canopy_CO2,))
```

Every leaf still reads `meteo.CO2`; the two-hour mean is computed from
`:canopy_CO2`. The sampled row is computed once per application and timestep,
then reused for all selected leaves.

## Growth, Pruning, And Movement

Use the public lifecycle operations:

```julia
register_object!(scene, new_leaf; parent=:plant_1)
new_leaf_status = add_organ!(
    parent_node,
    scene,
    :+,
    :Leaf,
    3;
    initial_status=(biomass=0.0,),
)
remove_object!(scene, :old_leaf)
reparent_object!(scene, :leaf_2, :axis_3)
move_object!(scene, :leaf_3, new_geometry)
```

For MTG-backed growth, prefer `add_organ!`: it creates the MTG node and its
scene object together and reuses the status initialization policy from
`Scene(mtg; status=...)`. Use `register_object!` when adapting another topology
backend or when a complete `Object` already exists.

Structural changes refresh application targets, input carriers, call targets,
writer validation, and schedules before the next timestep. Geometry-only
changes refresh environment bindings without rebuilding unrelated structural
bindings.

The refreshed runtime also rebuilds homogeneous execution batches. Use
`explain_execution_plan(scene_or_simulation)` to inspect the concrete
model/status/carrier types and the objects grouped into each specialized inner
loop. Exceptional per-object model overrides appear as separate ordered
batches.

## Output Collection

`run!(scene; steps=...)` returns a `SceneSimulation`. Use
`scene_outputs(sim)` for the retained typed streams, `explain_outputs(sim)` for
structured diagnostics, and `collect_outputs(sim)` for tabular rows.

```julia
request = OutputRequest(
    Many(scale=:Leaf),
    :transpiration;
    name=:leaf_transpiration_daily,
    application=:leaf_energy,
    policy=Integrate(),
    clock=Day(1),
)

sim = run!(scene; steps=48, outputs=request)
daily = collect_outputs(sim, :leaf_transpiration_daily)
```

Scene output requests are materialized from retained temporal streams after
the run. They use the same temporal policies as multirate inputs and export
dynamic objects only over the interval where that object published samples.
If several scene applications implement the same process, add
`application=:application_name` to select one explicitly. This is also the
way to request a named `:stream_only` publisher.
`outputs=:none` retains no user streams. Passing explicit requests retains only
their application/variable streams plus streams needed by temporal
`Inputs(...)`. Use `explain_output_retention(sim)`
to inspect why each retained stream was kept. Dependency-only streams retain a
bounded policy-specific horizon, while requested streams keep complete
histories for post-run export. Export is not yet a fully online path.

## Inspecting The Compiled Scenario

Use structured explanations instead of inspecting internal dictionaries:

```julia
explain_objects(scene)
explain_instances(scene)
explain_scopes(scene)
explain_scene_applications(scene)
explain_bindings(scene)
explain_calls(scene)
explain_environment_bindings(scene)
explain_schedule(scene)
explain_writers(scene)
explain_model_bundles(scene)
```

These functions return structured rows with concrete object ids, application
ids, processes, variables, temporal policies, carrier semantics, and resolved
targets. They are intended for both users and coding agents.

## Migration Table

| Legacy configuration | Scene/object replacement |
| --- | --- |
| `ModelMapping` scale assembly | `Scene` objects plus model applications |
| `MultiScaleModel(...)` | consumer `Inputs(...)` |
| `TimeStepModel(...)` | `TimeStep(...)` |
| `InputBindings(...)` | source, policy, and window on `Inputs(...)` |
| `MeteoBindings(...)` | automatic environment binding or `Environment(...)` |
| `ScopeModel(...)` | `AppliesTo(...)` and selector scopes |
| `SameScale()` rename | `Inputs(:local => One(within=Self(), var=:source))` |

The executable MAESPA migration in
`examples/maespa_scene_example.jl` demonstrates two plant species, shared
soil, plant-local aggregation, scene-wide iterative energy balance, hourly and
daily models, and automatic environment binding.

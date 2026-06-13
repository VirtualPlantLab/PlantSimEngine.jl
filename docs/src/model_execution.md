# Model Execution

This page describes how the native scene/object runtime executes model
applications. Use this path for new multi-object, multi-plant, soil,
microclimate, and multirate simulations.

The public configuration surface is:

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

Legacy `ModelMapping`, `MultiScaleModel`, domain, and route APIs are retained
as qualified compatibility tools while old examples are migrated. New
scenarios should start from `Scene` and model applications.

## Model Kernels And Applications

A model kernel is still an ordinary PlantSimEngine model:

- `inputs_(model)` declares required status variables;
- `outputs_(model)` declares variables the model computes;
- `meteo_inputs_(model)` declares environment variables it reads;
- `meteo_outputs_(model)` declares mutable environment variables it writes;
- `dep(model)` may declare model-author defaults;
- `run!(model, models, status, meteo, constants, extra)` contains the model
  equations.

The scene/object layer does not change that kernel contract. It adds a
scenario-specific application around the kernel:

```julia
ModelSpec(LeafEnergyBalance(); name=:leaf_energy) |>
    AppliesTo(Many(kind=:plant, scale=:Leaf)) |>
    Inputs(...) |>
    Calls(...) |>
    TimeStep(Dates.Hour(1)) |>
    Environment(provider=:canopy)
```

`ModelSpec` decides where the model runs, where its inputs come from, which
models it may call manually, which timestep it uses, and which environment
provider is bound to it. The model implementation stays reusable.

## Compilation Before Runtime

Before the timestep loop, `compile_scene(scene)` and `refresh_bindings!(scene)`
resolve the scenario into concrete runtime carriers:

1. `AppliesTo(...)` selectors are resolved to stable object ids.
2. `Inputs(...)` selectors are resolved to source object/application ids.
3. Same-rate inputs are wired as shared `Ref`s, `RefVector`s, or
   `ObjectRefVector`s.
4. Temporal inputs are compiled as stream lookups with a policy such as
   `HoldLast`, `Interpolate`, `Integrate`, or `Aggregate`.
5. `Calls(...)` declarations are compiled to callable target lists.
6. `Environment(...)` is bound to backend cells, layers, voxels, or global
   weather providers.
7. The root application order is topologically sorted from value inputs and
   `Updates(...)` ordering.
8. Root execution batches are grouped by concrete model/status/environment
   types where possible.

Selectors are not resolved in the hot loop. Runtime execution uses the
compiled indexes and carriers.

Useful inspection helpers:

```julia
compiled = refresh_bindings!(scene)

explain_scene_applications(compiled)
explain_bindings(compiled)
explain_calls(compiled)
explain_environment_bindings(refresh_environment_bindings!(scene, compiled))
explain_schedule(compiled)
explain_execution_plan(scene)
explain_writers(compiled)
```

These explanations are intended for both users and agents. They report the
compiled object ids, applications, carriers, clocks, environment bindings, and
manual-call targets that the runtime will use.

## Soft Dependencies With Inputs

Soft dependencies are value dependencies. A consumer model reads a variable
produced by another model through `Inputs(...)`.

```julia
ModelSpec(SceneLAI(ground_area); name=:scene_lai) |>
    AppliesTo(One(scale=:Scene)) |>
    Inputs(
        :leaf_areas => Many(
            kind=:plant,
            scale=:Leaf,
            within=SceneScope(),
            process=:leaf_state,
            var=:leaf_area,
        ),
    )
```

For same-rate inputs, the runtime installs a reference carrier into the
consumer status during compilation. A scene-scale model reading all leaf areas
therefore sees a `RefVector`-like object: reading pulls current values from
source leaf statuses, and writing through the carrier mutates source refs when
the carrier supports it.

If an input is not explicitly declared with `Inputs(...)`, the compiler can
infer simple same-object bindings when exactly one producer on the same object
outputs the same variable. Ambiguous producers are errors and should be
disambiguated with `process=...`, `application=...`, or `var=...`.

Use `PreviousTimeStep(:x) => selector` when a feedback dependency should read
the previous sample instead of creating a same-timestep scheduling edge.

## Hard Calls With Calls

Hard dependencies are manual calls. Use `Calls(...)` when a parent model must
control the call stack, for example during an iterative energy-balance solve.

```julia
ModelSpec(SceneEnergyBalance(); name=:scene_energy) |>
    AppliesTo(One(scale=:Scene)) |>
    Calls(
        :leaf_energy => Many(
            kind=:plant,
            scale=:Leaf,
            within=SceneScope(),
            process=:energy_balance,
        ),
        :soil => One(
            kind=:soil,
            scale=:Soil,
            within=SceneScope(),
            process=:soil_water,
        ),
    ) |>
    TimeStep(Dates.Hour(1))
```

Inside `run!`, the parent retrieves executable targets and decides when to
publish the accepted state:

```julia
function PlantSimEngine.run!(model::SceneEnergyBalance, models, status, meteo,
                             constants, extra)
    for target in call_targets(extra, :leaf_energy)
        run_call!(target; meteo=trial_meteo(model, status))
    end

    for target in call_targets(extra, :leaf_energy)
        run_call!(target; meteo=accepted_meteo(model, status), publish=true)
    end

    return nothing
end
```

`run_call!` defaults to `publish=false`. Trial calls mutate target statuses but
do not publish temporal samples or scatter mutable environment outputs. Call
`run_call!(target; publish=true)` once for the accepted state.

Applications selected only by `Calls(...)` are marked manual-call-only in
`explain_schedule(compiled)` and are skipped by the root `run!(scene)` loop.

## Duplicate Writers With Updates

By default, one application owns each `(object, output variable)` canonical
writer. If a scenario intentionally lets several models update the same
variable, later writers must declare that order explicitly:

```julia
ModelSpec(CarbonAllocation(); name=:carbon_allocation) |>
    AppliesTo(Many(scale=:Leaf))

ModelSpec(LeafPruning(); name=:leaf_pruning) |>
    AppliesTo(Many(scale=:Leaf)) |>
    Updates(:leaf_biomass; after=:carbon_allocation)
```

This keeps ordinary duplicate outputs as errors while allowing cases such as
allocation followed by pruning. `explain_writers(compiled)` reports writer
groups and the `Updates(...)` declarations that validate them.

## Multirate Execution

Use `TimeStep(...)` with `Dates.Period` values for model application clocks:

```julia
ModelSpec(HourlyLeafAssimilation(); name=:leaf_assim) |>
    AppliesTo(Many(scale=:Leaf)) |>
    TimeStep(Dates.Hour(1))

ModelSpec(DailyPlantAllocation(); name=:allocation) |>
    AppliesTo(Many(scale=:Plant)) |>
    Inputs(
        :leaf_assimilation => Many(
            scale=:Leaf,
            within=Self(),
            process=:leaf_assimilation,
            var=:A,
            policy=Integrate(),
            window=Dates.Day(1),
        ),
    ) |>
    TimeStep(Dates.Day(1))
```

Clock precedence is:

1. explicit `TimeStep(...)` on the `ModelSpec`;
2. non-default `timespec(model)` trait;
3. the scene environment base step.

`timestep_hint(model)` is a compatibility constraint and explanation hint. It
does not silently choose a clock. If a model uses the environment base step and
that step violates `timestep_hint.required`, scene compilation errors.

Temporal input policy precedence is:

1. explicit selector policy, such as `policy=Integrate()`;
2. producer `output_policy(model)` for that output;
3. `HoldLast()`.

Supported policies are:

- `HoldLast()`: use the latest producer sample;
- `Interpolate()`: interpolate or extrapolate from producer samples;
- `Integrate()`: reduce values over a window, defaulting to `SumReducer()`;
- `Aggregate()`: reduce values over a window, defaulting to `MeanReducer()`.

`Integrate(...)` and `Aggregate(...)` accept reducer objects or callables that
take either `(values)` or `(values, durations_seconds)`.

## Environment Sampling

`Environment(...)` chooses a provider and optional source-variable remapping:

```julia
ModelSpec(CO2Probe(); name=:co2_probe) |>
    AppliesTo(Many(scale=:Leaf)) |>
    Environment(provider=:canopy, sources=(CO2=:Ca,))
```

The compiler binds each application/object pair to the selected backend before
runtime. Constant weather, global tabular meteorology, grid, layer, voxel, or
octree-style microclimate backends all use the same contract:

- `meteo_inputs_(model)` says what the model reads;
- `meteo_outputs_(model)` says what the model writes back;
- `Environment(; sources=...)` maps model-facing names to backend names;
- geometry and position are used by spatial backends when available;
- object-to-environment links are cached and refreshed when objects move.

Model-level `meteo_hint(...)` can provide default source bindings and
aggregation rules. Scenario-level `Environment(...)` keeps precedence for
source names, while explicit sampling policy on `Inputs(...)` controls
model-to-model temporal values.

## Running And Outputs

Run a scene with:

```julia
sim = run!(scene; steps=30, constants=Constants())
```

The returned `SceneSimulation` contains the mutated scene, compiled bindings,
environment bindings, execution plan, and retained temporal output streams.

By default, scene runs retain all published streams. For large scenes, pass
`OutputRequest` values to retain only selected outputs and temporal dependency
streams:

```julia
request = OutputRequest(
    :Leaf,
    :A;
    name=:leaf_assimilation_daily,
    process=:leaf_assimilation,
    policy=Integrate(),
    clock=Dates.Day(1),
)

sim = run!(scene; steps=72, tracked_outputs=request)
collect_outputs(sim, :leaf_assimilation_daily; sink=nothing)
explain_output_retention(sim)
```

When several applications publish the same process and variable, use
`application=:application_name` in the request. This selects the named
application directly and can also request an explicitly named
`:stream_only` publisher.

Set `tracked_outputs=OutputRequest[]` to retain no output streams unless they
are required by temporal dependencies.

Temporal dependency streams that are not explicitly requested retain only the
history required by their input policy. `HoldLast` keeps the latest sample,
`Integrate` and `Aggregate` keep their input window, and `Interpolate` and
`PreviousTimeStep` keep sufficient recent source samples. Requested streams
retain complete histories for post-run export. `explain_output_retention(sim)`
reports `retention_steps` for bounded dependency-only streams and `nothing`
for full-history streams.

## Lifecycle Changes

Scene objects may be added, removed, reparented, moved, or have their geometry
updated between or during timesteps:

```julia
register_object!(scene, Object(:new_leaf; scale=:Leaf); parent=:plant_1)
remove_object!(scene, :old_leaf)
reparent_object!(scene, :leaf_3; parent=:plant_2)
move_object!(scene, :leaf_4; geometry=new_geometry)
update_geometry!(scene, :leaf_5, new_geometry)
```

Structural changes invalidate compiled object/model bindings. Movement and
geometry changes invalidate environment bindings without rebuilding structural
input carriers. The next `run!(scene)` step refreshes the necessary caches.

## Compatibility Runtime

Historical `ModelMapping` and MTG mapping simulations still work through
qualified compatibility constructors such as
`PlantSimEngine.ModelMapping(...)`, `PlantSimEngine.MultiScaleModel(...)`,
`PlantSimEngine.InputBindings(...)`, and
`PlantSimEngine.TimeStepModel(...)`.

Those names are no longer the primary API. For new work, use:

- `ModelMapping(...)` -> `Scene(...)` plus object-local `ModelSpec(...)`
  applications;
- `MultiScaleModel(...)` -> `Inputs(...)`;
- `InputBindings(...)` -> selector fields inside `Inputs(...)`;
- `MeteoBindings(...)` / `MeteoWindow(...)` -> `Environment(...)`,
  `meteo_hint(...)`, and model/application clocks;
- `TimeStepModel(...)` -> `TimeStep(...)`.

See [Migrating To The Scene/Object API](migration_scene_object.md) for worked
translation patterns.

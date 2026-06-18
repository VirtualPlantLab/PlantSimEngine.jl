---
name: plantsimengine
description: Use PlantSimEngine.jl to compose models with the unified Scene/Object API, AppliesTo, Inputs, Calls, TimeStep, Environment, and to implement or wrap generic model kernels with inputs_, outputs_, dep, meteo traits, and run!.
---

# PlantSimEngine Skill

Use this skill when helping with PlantSimEngine.jl scene/object simulations,
multiscale or multi-plant coupling, multirate execution, microclimate binding,
or implementing and wrapping models.

PlantSimEngine has two main user roles:

- **Users** compose existing models. They mostly need `Scene`, `Object`,
  `ModelSpec`, `AppliesTo`, `Inputs`, `Calls`, `Updates`, `TimeStep`, and
  `Environment`.
- **Modelers** implement or wrap generic kernels. They need process identity,
  `inputs_`, `outputs_`, `dep`, `meteo_inputs_`, `meteo_outputs_`, `run!`,
  model traits, and focused tests.

Use the unified scene/object API for multiscale, multi-plant, soil, scene, and
microclimate work. Translate released mapping-era code using
`docs/src/migration_scene_object.md`.

## First Steps

1. Identify whether the request is user-side scenario composition or
   modeler-side implementation.
2. Inspect existing model declarations before inventing names:
   - Search for process definitions with `rg "@process|abstract type Abstract.*Model" src examples docs test`.
   - Search for model APIs with `rg "inputs_\\(|outputs_\\(|PlantSimEngine.run!|dep\\(" src examples test`.
3. Check model IO with `inputs(model)`, `outputs(model)`, `variables(model)`, and process identity with `process(model)` when available.
4. Compile scenarios early with `refresh_bindings!(scene)` and inspect
   `explain_scene_applications`, `explain_bindings`, `explain_calls`,
   `explain_schedule`, `explain_writers`, and environment bindings.

## User Workflow: Existing Models

### Build the object graph

Represent every runtime entity as an `Object` with stable identity and useful
labels. Plant topology remains scenario-defined.

```julia
scene = Scene(
    Object(:scene; scale=:Scene, kind=:scene),
    Object(:plant_1; scale=:Plant, kind=:plant, parent=:scene),
    Object(:leaf_1; scale=:Leaf, kind=:plant, parent=:plant_1),
    Object(:soil; scale=:Soil, kind=:soil, parent=:scene);
    environment=(T=25.0, Rh=0.6, Wind=1.0),
)
```

Rules:

- `scale`, `kind`, `species`, and `name` are selector labels, not a fixed plant
  ontology.
- Use any hierarchy required by the simulated object.
- `Status` is reference-backed. Same-rate coupling should preserve those
  references instead of copying values.
- Use `ObjectTemplate` and `ObjectInstance` for repeated plants with shared
  model objects and parameters.
- Adapt an existing MTG with `Scene(mtg; applications=..., environment=...)`,
  or inspect `objects_from_mtg(mtg; ...)` before constructing the scene.
  Accessors can translate MTG attributes into ids, labels, status, and
  geometry.

### Apply models

Wrap each scenario application in `ModelSpec` and select its target objects
with `AppliesTo`.

```julia
applications = (
    ModelSpec(LeafModel(); name=:leaf_model) |>
    AppliesTo(Many(scale=:Leaf)),

    ModelSpec(SoilModel(); name=:soil_model) |>
    AppliesTo(One(scale=:Soil)),
)

scene = Scene(scene_objects...; applications=applications, environment=backend)
```

Use explicit application names when a process is applied more than once to the
same object set. Selectors can disambiguate producers by `process=` and
`application=`.

### Couple values with Inputs

Declare each consumer's value source with `Inputs`.

```julia
ModelSpec(AllocationModel(); name=:allocation) |>
    AppliesTo(Many(scale=:Plant)) |>
    Inputs(
        :leaf_carbon => Many(
            scale=:Leaf,
            within=Self(),
            process=:leaf_carbon,
            var=:leaf_carbon,
        ),
    )
```

Semantics:

- `One(...)`, `OptionalOne(...)`, and `Many(...)` make multiplicity explicit.
- `Self()` is the consumer object or subtree. `SelfPlant()` is the nearest
  containing plant. `SceneScope()` selects across the scene.
- Same-rate scalar and many-object inputs use shared `Ref`s or reference
  vectors where possible.
- Cross-rate values use typed temporal streams.
- Rename variables with
  `Inputs(:local_name => One(within=Self(), var=:source_name))`.
- Use `PreviousTimeStep(:x) => selector` for an explicit lag and cycle break.
- An unresolved `OptionalOne` input keeps its `inputs_` default.

### Control manual model calls

Use `Calls` when the parent model must own the call stack, such as an iterative
energy balance.

```julia
ModelSpec(SceneEnergyBalance(); name=:scene_energy) |>
    AppliesTo(One(scale=:Scene)) |>
    Calls(
        :leaf_energy => Many(
            scale=:Leaf,
            within=SceneScope(),
            process=:energy_balance,
        ),
    )
```

Inside `run!`, retrieve targets with `call_target(s)(extra, :name)`.
`run_call!` defaults to `publish=false` for trial iterations. Use
`publish=true` once for the accepted state.

### Configure rates and environment

Use `Dates.Period` values directly:

```julia
ModelSpec(DailyPlantModel(); name=:daily_plant) |>
    AppliesTo(Many(scale=:Plant)) |>
    Inputs(
        :leaf_fluxes => Many(
            scale=:Leaf,
            within=Self(),
            var=:flux,
            policy=Integrate(),
            window=Dates.Day(1),
        ),
    ) |>
    TimeStep(Dates.Day(1))
```

Policies are `HoldLast`, `Interpolate`, `Integrate`, and `Aggregate`. When an
`Inputs(...)` selector omits `policy=...`, a unique producer's
`output_policy(::Type{<:Model})` trait supplies the default policy; explicit
selector policies override the trait.
Environment variables come from `meteo_inputs_` and `meteo_outputs_`.
`meteo_hint(...).bindings` can provide model-author default source remaps, and
`Environment(; sources=...)` is the scenario-level override. Use
`Environment(provider=:grid)` only when overriding automatic binding.
For global `Weather` tables, scene applications sample meteorology at their
compiled clock using the `meteo_hint` reducer/window. An
`Environment(; sources=...)` override changes the source but preserves that
reducer, and all objects in one application reuse the same sampled row for a
given timestep. Spatial backends define their own temporal sampling semantics.
When no `TimeStep(...)` is provided, the scene scheduler honors
`timespec(::Type{<:Model})`; an explicit `TimeStep(...)` remains the
scenario-level override. If the clock falls back to the scene base step,
`timestep_hint(::Type{<:Model})` required bounds are validated as compatibility
constraints.

### Handle lifecycle changes

Use `register_object!`, `remove_object!`, `reparent_object!`, and
`move_object!`. Structural changes refresh selectors, carriers, calls,
writers, and schedules before the next timestep. Geometry-only changes refresh
the affected environment bindings.

### Validate the compiled scenario

```julia
compiled = refresh_bindings!(scene)
explain_scene_applications(compiled)
explain_bindings(compiled)
explain_calls(compiled)
explain_schedule(compiled)
explain_writers(compiled)
explain_model_bundles(compiled)
```

Run with `simulation = run!(scene; steps=n)` and inspect
`collect_outputs(simulation)` or `explain_outputs(simulation)`. Use
`run!(scene; tracked_outputs=OutputRequest(...))` when the user needs
resampled scene outputs; requests are materialized from retained typed streams
after the run, and dynamic objects are exported only across their own sample
interval. With explicit `tracked_outputs`, retained streams are pruned to
requested application/variable streams plus temporal `Inputs(...)`
dependencies; use `explain_output_retention(simulation)` to inspect that
decision.

## Modeler Workflow: New Or Wrapped Models

### Choose or create the process

Process identity is the abstract process type, not the concrete model name. Before adding a process, search for an existing one with the same biological or physical meaning. Reuse it when the new model is an alternative implementation of the same process.

Create a new process only when the simulated process is genuinely new:

```julia
PlantSimEngine.@process "maintenance_respiration" verbose=false
```

This creates an abstract process type such as `AbstractMaintenance_RespirationModel`. Concrete implementations subtype that abstract process.

### Implement the model contract

```julia
struct MyModel{T} <: AbstractSome_ProcessModel
    p::T
end

PlantSimEngine.inputs_(::MyModel) = (x=0.0, y=-Inf)
PlantSimEngine.outputs_(::MyModel) = (z=-Inf,)

function PlantSimEngine.run!(m::MyModel, models, status, meteo, constants, extra=nothing)
    status.z = f(status.x, status.y, meteo.T, m.p)
    return nothing
end
```

Rules:

- `inputs_` and `outputs_` are authoritative. Defaults are also initialization hints.
- Use `NamedTuple()` for no inputs or no outputs.
- Read and write model state through `status`. Do not store timestep-varying state in the model object.
- Read weather through `meteo` and physical constants through `constants`.
- In scene runs, `extra` is a `SceneRunContext`. Use its public hard-call and
  lifecycle APIs rather than attaching unrelated user data.
- If a variable appears in both `inputs_` and `outputs_` with the same name, remember that `variables(model)` merges declarations and later output declarations win.

### Wrapping existing code

When wrapping an external or existing model:

1. Identify its true inputs, outputs, parameters, weather needs, and mutable state.
2. Put fixed parameters in the struct.
3. Put timestep-varying inputs and outputs in `status`.
4. Convert internal side effects into explicit `status` assignments.
5. Keep units and timestep assumptions in docstrings and traits.
6. If the external model computes several processes internally, split it into several PlantSimEngine models when users need to couple or replace those subprocesses independently. Keep it as one model only when the subprocesses are inseparable implementation details.

### Hard dependencies

Use a `Call(...)` dependency default when a parent model directly calls a
required submodel inside its own `run!`. Scenario-level `Calls(...)` can
override the default selector without changing the kernel.

```julia
PlantSimEngine.dep(::ParentModel) = (
    child=Call(process=:child_process),
)

function PlantSimEngine.run!(m::ParentModel, models, status, meteo, constants, extra=nothing)
    child = call_target(extra, :child)
    run_call!(child)
    status.parent_output = g(status.child_output)
end
```

The scenario decides the concrete target objects:

```julia
ModelSpec(ParentModel()) |>
    AppliesTo(One(scale=:Scene)) |>
    Calls(:child => Many(scale=:Leaf, process=:child_process))
```

Hard calls are never automatically executed for the parent. Trial
`run_call!` calls do not publish; pass `publish=true` for the accepted state.

### Model traits

Add traits only when they are true for the model implementation, not merely convenient for one scenario.

```julia
PlantSimEngine.timespec(::Type{<:MyDailyModel}) = ClockSpec(24.0, 1.0)

PlantSimEngine.output_policy(::Type{<:MyFluxModel}) = (
    assimilation=Integrate(),
)

PlantSimEngine.timestep_hint(::Type{<:MyModel}) =
    (; required=(Dates.Hour(1), Dates.Hour(6)), preferred=Dates.Hour(1))

PlantSimEngine.meteo_hint(::Type{<:MyModel}) = (
    bindings=(T=MeanReducer(),),
    window=RollingWindow(),
)
```

Parallel traits are mainly for single-scale execution. Multirate MTG runs are currently sequential.

## Validation Checklist

For user scenarios:

- `refresh_bindings!(scene)` succeeds.
- `explain_scene_applications` shows the expected application/object pairs.
- `explain_bindings` shows the intended source ids, source applications,
  temporal policies, and carrier semantics.
- `explain_calls`, `explain_schedule`, and `explain_writers` match the intended
  manual call stack and execution order.
- `explain_execution_plan` groups large homogeneous object sets into concrete
  batches; unexpected one-object batches usually indicate heterogeneous model,
  status, binding, or environment types.
- Cycles are absent or intentionally broken with `PreviousTimeStep`.
- Ambiguous producers are resolved with `process=` or `application=`.
- Environment explanations show the expected provider, cell, geometry source,
  source variables, and whether a temporal sampler is compiled.

For model implementations:

- Unit-test `inputs_`, `outputs_`, and a direct `run!` call with a minimal `Status`.
- Test scene composition when the model is meant to couple by variable name.
- Test `Inputs(...)` when the model expects scalar refs, `RefVector` inputs, or
  renamed variables.
- Test multirate behavior when `TimeStep`, temporal policies, windows, or
  output routing matter.
- Check hard dependencies by proving the parent actually calls the child and uses the child's outputs.

## Common Pitfalls

- Do not confuse hard dependencies with soft dependency scheduling. Hard dependencies are manual calls.
- Do not rely on object topology or declaration order for model execution
  order. Compiled input and update edges control scheduling.
- Do not attach biological meaning to incidental collection order. Selectors
  use stable object-id order.
- Do not use `One(...)` when several objects can match; use `Many(...)` or
  disambiguate explicitly.
- Do not use strings for new scale declarations. Use symbols.
- Do not mutate object topology outside `register_object!`, `remove_object!`,
  or `reparent_object!`; bypassing lifecycle hooks leaves caches stale.
- Do not publish every iterative hard call. Publish only the accepted state.
- Do not use `PreviousTimeStep` as a numerical lag unless the initial value and expected temporal semantics are explicit.

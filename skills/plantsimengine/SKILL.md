---
name: plantsimengine
description: Use PlantSimEngine.jl to compose, run, diagnose, and optimize simulations with the unified CompositeModel/Object API, and to implement or wrap generic model kernels with explicit input schemas, environments, hard calls, lifecycle support, and multirate execution.
---

# PlantSimEngine Skill

Use this skill when helping with PlantSimEngine.jl model/object simulations,
multiscale or multi-plant coupling, multirate execution, microclimate binding,
or implementing and wrapping models.

PlantSimEngine has two main user roles:

- **Users** compose existing models. They mostly need `CompositeModel`, `Object`,
  `ModelSpec`, `Updates`, and `Environment`.
- **Modelers** implement or wrap generic kernels. They need process identity,
  `inputs_`, `outputs_`, `dep`, `environment_inputs_`, `environment_outputs_`, `run!`,
  model traits, and focused tests.

Use the unified model/object API for multiscale, multi-plant, soil, model, and
microclimate work. `ModelMapping`, `MultiScaleModel`, `GraphSimulation`, and
the other mapping-era scenario layers have been removed; do not recreate them
as aliases or compatibility wrappers. Translate historical code with
`docs/src/migration_composite_model.md`.

## First Steps

1. Identify whether the request is user-side scenario composition or
   modeler-side implementation.
2. Inspect existing model declarations before inventing names:
   - Search for process definitions with `rg "@process|abstract type Abstract.*Model" src examples docs test`.
   - Search for model APIs with `rg "inputs_\\(|outputs_\\(|PlantSimEngine.run!|dep\\(" src examples test`.
3. Check model IO with `inputs(model)`, `outputs(model)`, `variables(model)`,
   and process identity with `process(model)` when available.
4. Validate scenarios early with `Diagnostics.explain_initialization(model)`
   and inspect applications, bindings, calls, writers, schedules, execution
   batches, environments, and output retention through `Diagnostics`.
5. Prefer supported `Diagnostics` helpers over compiler-field inspection.
   Reach for `PlantSimEngine.Advanced` only when the task is explicitly about
   compiler integration or cache behavior.

## User Workflow: Existing Models

### Build the object graph

For one object with ordinary same-object inference, use the thin constructor
that lowers directly to the same Composite Model/Object runtime:

```julia
model = CompositeModel(
    ModelA(),
    ModelB();
    status=(initial_value=1.0,),
    timestep=Dates.Hour(1),
)
```

Use the explicit object graph below as soon as models require different target
sets or scenario policies.

Represent every runtime entity as an `Object` with stable identity and useful
labels. Plant topology remains scenario-defined.

```julia
model = CompositeModel(
    Object(:scene; scale=:Scene, kind=:scene),
    Object(:plant_1; scale=:Plant, kind=:plant, parent=:scene),
    Object(:leaf_1; scale=:Leaf, kind=:leaf, parent=:plant_1),
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
- Use `CompositeModelTemplate` and `ObjectInstance` for repeated plants with shared
  model objects and parameters.
- Use `Override` only when one instance or selected object genuinely needs a
  different implementation while remaining part of the same logical
  application.
- Adapt an existing MTG with `CompositeModel(mtg; applications=..., environment=...)`,
  or inspect `objects_from_mtg(mtg; ...)` before constructing the model.
  Accessors can translate MTG attributes into ids, labels, status, and
  geometry.

### Apply models

Wrap each scenario application in `ModelSpec` and select its target objects
with `on`.

```julia
applications = (
    ModelSpec(LeafModel(); name=:leaf_model, on=Many(scale=:Leaf)),

    ModelSpec(SoilModel(); name=:soil_model, on=One(scale=:Soil)),
)

model = CompositeModel(model_objects...; applications=applications, environment=backend)
```

Use explicit application names when a process is applied more than once to the
same object set. Singular producer references use `application=`. A
`Many(process=...)` filter is reserved for explicit discovery across several
applications, such as mounted template instances.

### Couple values with `inputs`

Declare each consumer's value source with the `inputs` keyword.

```julia
ModelSpec(
    AllocationModel();
    name=:allocation,
    on=Many(scale=:Plant),
    inputs=(
        :leaf_carbon => Many(
            scale=:Leaf,
            within=Subtree(),
            application=:leaf_carbon,
            var=:leaf_carbon,
        ),
    ),
)
```

Semantics:

- `One(...)`, `OptionalOne(...)`, and `Many(...)` make multiplicity explicit.
- `Self()` is only the consumer object. `Subtree()` is that object plus its
  descendants. `SelfPlant()` is the nearest containing plant and its subtree.
  `SceneScope()` selects across the model.
- Same-rate scalar and many-object inputs use shared `Ref`s or reference
  vectors where possible.
- Cross-rate values use typed temporal streams.
- Rename variables with
  `inputs=(:local_name => One(within=Self(), var=:source_name),)`.
- Use `PreviousTimeStep(:x) => selector` for an explicit lag and cycle break.
- An unresolved `OptionalOne` input keeps its `inputs_` default.

### Control manual model calls

Use `calls` when the parent model must own the call stack, such as an iterative
energy balance.

```julia
ModelSpec(
    SceneEnergyBalance();
    name=:scene_energy,
    on=One(scale=:Scene),
    calls=(
        :leaf_energy => Many(
            scale=:Leaf,
            within=SceneScope(),
            application=:energy_balance,
        ),
    ),
)
```

Inside `run!`, execute all targets with `run_call!(context, :name)`, which
always returns a vector-like `CallTargets` collection. For selective or
iterative control, retrieve the cached collection with
`call_targets(context, :name)` and execute individual targets. `run_call!`
defaults to `publish=false` for trial iterations. Use `publish=true` once for
the accepted state. Applications used only as call targets are not scheduled
independently and do not receive inferred soft bindings.

### Configure rates and environment

Use `Dates.Period` values directly:

```julia
ModelSpec(
    DailyPlantModel();
    name=:daily_plant,
    on=Many(scale=:Plant),
    inputs=(
        :leaf_fluxes => Many(
            scale=:Leaf,
            within=Subtree(),
            var=:flux,
            policy=Integrate(),
            window=Dates.Day(1),
        ),
    ),
    every=Dates.Day(1),
)
```

Policies are `HoldLast`, `Interpolate`, `Integrate`, and `Aggregate`. When an
`ModelSpec(...; inputs=...)` selector omits `policy=...`, a unique producer's
`output_policy(::Type{<:Model})` trait supplies the default policy; explicit
selector policies override the trait.
Environment variables come from `environment_inputs_` and `environment_outputs_`.
`environment_hint(...).bindings` can provide model-author default source remaps, and
`Environment(; sources=...)` is the scenario-level override. Use
`Environment(provider=:grid)` only when overriding automatic binding.
For global `Weather` tables, model applications sample meteorology at their
compiled clock using the `environment_hint` reducer/window. An
`Environment(; sources=...)` override changes the source but preserves that
reducer, and all objects in one application reuse the same sampled row for a
given timestep. Spatial backends define their own temporal sampling semantics.
When no `every` value is provided, the model scheduler honors
`timespec(::Type{<:Model})`; an explicit `every` remains the scenario-level
override. If the clock falls back to the model base step,
`timestep_hint(::Type{<:Model})` required bounds are validated as compatibility
constraints.

### Handle lifecycle changes

Use `add_organ!` for MTG-backed growth: it creates the node, applies the MTG
status policy and initial values, attaches status, and registers the object.
Use `register_object!` only when the caller already owns a fully initialized
`Object`. `remove_object!` and `reparent_object!` change topology;
`move_object!`, `update_geometry!`, and
`mark_environment_binding_dirty!` invalidate spatial bindings.

Structural changes made inside a kernel refresh applications, value carriers,
hard-call targets, writers, and schedules after that application. New objects
may run applications still remaining in the same timestep, but never ones that
already completed. Removed objects keep retained output history.

### Validate the compiled scenario

```julia
Diagnostics.explain_initialization(model)
Diagnostics.explain_applications(model)
Diagnostics.explain_bindings(model)
Diagnostics.explain_calls(model)
Diagnostics.explain_schedule(model)
Diagnostics.explain_writers(model)
Diagnostics.explain_execution_plan(model)
```

Run with `simulation = run!(model; steps=n, outputs=:none)`. Use
`outputs=:all` or `outputs=OutputRequest(...)` when the user needs retained or
resampled outputs. Requests are materialized from retained typed streams after
the run, and dynamic objects are exported only across their own sample
interval. Continue the same time/environment/multirate state with
`continue!(simulation; steps=n)` or `step!(simulation)`. Read the latest status
without retaining streams through `final_state(simulation[, selector])`. Use
`outputs(simulation)` for retained typed streams and `collect_outputs` only
when rows must be materialized. Inspect retention afterward with
`Diagnostics.explain_output_retention(simulation)`.

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

PlantSimEngine.inputs_(::MyModel) = (
    x=Required(Real),
    offset=Default(0.0),
)
PlantSimEngine.outputs_(model::MyModel) = (z=zero(model.p),)

function PlantSimEngine.run!(model::MyModel, status, environment, constants, context)
    status.z = model.p * status.x + status.offset
    return nothing
end
```

Rules:

- `inputs_` must return a `NamedTuple` containing only `Required(T)` and
  `Default(value)` declarations. `Required(T)` is a type contract, not an
  initial value. Use `Default` only for a scientifically meaningful fallback.
- `outputs_` returns initial output-state values; keep them generic with
  respect to model parameter and status types.
- Use `NamedTuple()` for no inputs or no outputs.
- Read and write model state through `status`. Do not store timestep-varying state in the model object.
- Read sampled forcing through `environment` and physical constants through `constants`.
- In model runs, `context` is a `RunContext`. Use its public hard-call and
  lifecycle APIs rather than attaching unrelated user data. Obtain the live
  model with `runtime_model(context)`; do not inspect `context.compiled.model`.
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
required submodel inside its own `run!`. Scenario-level `ModelSpec(...; calls=...)` can
override the default selector without changing the kernel.

```julia
PlantSimEngine.dep(::ParentModel) = (
    child=Call(One(process=:child_process)),
)

function PlantSimEngine.run!(model::ParentModel, status, environment, constants, context)
    child = only(run_call!(context, :child; publish=true))
    status.parent_output = g(child.status.child_output)
    return nothing
end
```

The scenario decides the concrete target objects:

```julia
ModelSpec(
    ParentModel();
    name=:parent,
    on=One(scale=:Scene),
    calls=(:child => Many(scale=:Leaf, application=:child),),
)
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

PlantSimEngine.environment_hint(::Type{<:MyModel}) = (
    bindings=(T=PlantMeteo.MeanReducer(),),
    window=PlantMeteo.RollingWindow(),
)
```

There is currently no public parallel executor API. Do not promise parallel or
distributed execution; establish correctness and independence before any
future parallel implementation.

### Performance rules

- Keep model parameters, status values, carriers, and output streams concrete
  and generic; do not force `Float64`.
- Preserve reference carriers instead of copying same-rate values.
- Keep dynamic dispatch at compiled batch boundaries, not inside the per-object
  kernel loop.
- Preserve cached hard-call targets and homogeneous execution batches.
- After a lifecycle event, the ordinary steady-state path should return to the
  precompiled schedule rather than rebuilding the whole scene each step.
- Add allocation checks for hot loops over many organs, and separate scene
  construction, steady-state steps, lifecycle refresh, output collection, and
  full-cycle runtime when benchmarking.

### Source ownership

- `src/composite_model_api.jl` is only the dependency-ordered include boundary.
- `src/composite_model/registry_topology.jl` owns objects, instances, and lifecycle.
- `src/composite_model/selectors.jl` owns selector resolution.
- `src/composite_model/compilation.jl` owns bindings, calls, writers, and schedules.
- `src/composite_model/environment_bindings.jl` owns environment coupling.
- `src/composite_model/runtime_outputs.jl` owns execution and output streams.

## Validation Checklist

For user scenarios:

- `Diagnostics.explain_initialization(model)` contains no unresolved required
  values.
- `Diagnostics.explain_applications` shows the expected application/object
  pairs.
- `Diagnostics.explain_bindings` shows the intended source ids, source applications,
  temporal policies, and carrier semantics.
- `Diagnostics.explain_calls`, `Diagnostics.explain_schedule`, and
  `Diagnostics.explain_writers` match the intended manual call stack and
  execution order.
- `Diagnostics.explain_execution_plan` groups large homogeneous object sets into concrete
  batches; unexpected one-object batches usually indicate heterogeneous model,
  status, binding, or environment types.
- Cycles are absent or intentionally broken with `PreviousTimeStep`.
- Ambiguous singular producers are resolved with `application=`.
- Environment explanations show the expected provider, cell, geometry source,
  source variables, and whether a temporal sampler is compiled.
- Test one object, many objects, templates, instances, and overrides when the
  scenario supports them.
- Test object creation, removal, reparenting, movement, and removed-object
  history when lifecycle behavior is in scope.

For model implementations:

- Unit-test `inputs_`, `outputs_`, and a direct `run!` call with a minimal `Status`.
- Test model composition when the model is meant to couple by variable name.
- Test `ModelSpec(...; inputs=...)` when the model expects scalar refs, `RefVector` inputs, or
  renamed variables.
- Test multirate behavior when `every`, temporal policies, windows, or
  output routing matter.
- Check hard dependencies by proving the parent actually calls the child and uses the child's outputs.
- Test generic numeric types and allocation-sensitive execution for hot
  kernels.

## Common Pitfalls

- Do not confuse hard dependencies with soft dependency scheduling. Hard dependencies are manual calls.
- Do not rely on object topology or declaration order for model execution
  order. Compiled input and update edges control scheduling.
- Do not attach biological meaning to incidental collection order. Selectors
  use stable object-id order.
- Do not use `One(...)` when several objects can match; use `Many(...)` or
  disambiguate explicitly.
- Do not use strings for new scale declarations. Use symbols.
- Do not mutate object topology or geometry outside the lifecycle helpers;
  bypassing their invalidation hooks leaves caches stale.
- Do not publish every iterative hard call. Publish only the accepted state.
- Do not use `PreviousTimeStep` as a numerical lag unless the initial value and expected temporal semantics are explicit.
- Do not inspect internal carrier or compiled fields when a `Diagnostics`
  helper exists.

## High-Signal Local References

- Scenario quickstart: `docs/src/composite_model/quickstart.md`.
- User journeys: `docs/src/journeys/users/`.
- Modeler journeys: `docs/src/journeys/modelers/`.
- Migration from removed APIs: `docs/src/migration_composite_model.md`.
- Public namespaces: `docs/src/API/API_public.md` and
  `docs/src/API/public_symbols.md`.
- Compiler/runtime ownership: `src/composite_model/` and
  `src/composite_model_api.jl`.
- Broad integration coverage: `test/test-unified-model-object-api.jl` and
  `test/test-model-*.jl`.

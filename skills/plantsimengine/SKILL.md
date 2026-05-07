---
name: plantsimengine
description: Use PlantSimEngine.jl to compose existing process models with ModelMapping, spatial multiscale MTG mappings, multirate ModelSpec configuration, and to implement or wrap new models by defining processes, inputs_, outputs_, run!, hard dependencies, and model traits.
---

# PlantSimEngine Skill

Use this skill when helping with PlantSimEngine.jl simulations, model mappings, multiscale MTG coupling, multirate execution, or implementing/wrapping models.

PlantSimEngine has two main user roles:

- **Users** compose existing models. They mostly need `ModelMapping`, `MultiScaleModel`/`ModelSpec`, status initialization, variable mappings, spatial scale symbols, and multirate policies.
- **Modelers** implement or wrap models. They need process identity, `inputs_`, `outputs_`, `run!`, hard dependencies, model traits, and tests that prove the model composes correctly.

Prefer current APIs: `ModelMapping`, `ModelSpec`, `MultiScaleModel`, `Status`, `PreviousTimeStep`, and `run!`. Treat legacy `ModelList` as compatibility plumbing unless the user is working on legacy code.

## First Steps

1. Identify whether the request is user-side mapping work or modeler-side implementation work.
2. Inspect existing model declarations before inventing names:
   - Search for process definitions with `rg "@process|abstract type Abstract.*Model" src examples docs test`.
   - Search for model APIs with `rg "inputs_\\(|outputs_\\(|PlantSimEngine.run!|dep\\(" src examples test`.
3. Check model IO with `inputs(model)`, `outputs(model)`, `variables(model)`, and process identity with `process(model)` when available.
4. Validate mappings early with `dep(mapping)`, `to_initialize(mapping[, mtg])`, `resolved_model_specs(mapping)`, and `explain_model_specs(mapping)` when relevant.

## User Workflow: Existing Models

### Single-scale mapping

Use `ModelMapping` when all models share one status.

```julia
mapping = ModelMapping(
    ModelA(args...),
    ModelB(args...);
    status=(x=1.0, y=0.0),
)

out = run!(mapping, meteo)
```

Rules:

- Inputs are matched to outputs by variable name after model declarations are flattened.
- Variables not produced by another model must be initialized through `status`, model defaults, meteo, or another supported input source.
- If two models produce the same canonical variable, inspect the graph and disambiguate before relying on incidental order.
- `Status` values are reference-backed. Writing `status.x = value` mutates the cell used by coupled models.

### Spatial multiscale mapping

Use `ModelMapping` keyed by scale symbols when running on an MTG. Prefer symbol scales such as `:Scene`, `:Plant`, `:Leaf`, `:Internode`; string scale names are deprecated.

```julia
mapping = ModelMapping(
    :Scene => (
        SceneModel(),
    ),
    :Plant => (
        MultiScaleModel(
            PlantModel(),
            [:TT_cu => (:Scene => :TT_cu)],
        ),
    ),
    :Leaf => (
        LeafModel(),
        Status(carbon_biomass=1.0),
    ),
)

out = run!(mtg, mapping, meteo)
```

Each scale tuple can contain models, `ModelSpec`s, `MultiScaleModel`s, and optional `Status(...)` initializers for variables local to that scale. A model only sees variables in its local status unless they are mapped from another scale or supplied by runtime input binding.

### Variable mapping forms

Use `MultiScaleModel(model, mapped_variables)` or pipe through `ModelSpec(model) |> MultiScaleModel(mapped_variables)`.

Common forms:

```julia
:x => :Plant                         # scalar read from :Plant, same variable name
:x => (:Plant => :y)                 # scalar read from :Plant variable :y
:x => [:Leaf]                        # vector read from all :Leaf nodes
:x => [:Leaf, :Internode]            # vector read from several scales
:x => [:Leaf => :a, :Internode => :b] # vector read with per-scale renaming
:x => (Symbol("") => :y)             # same-scale rename or alias
PreviousTimeStep(:x)                 # break current-step dependency inference
PreviousTimeStep(:x) => (:Plant => :y)
```

Semantics:

- Scalar cross-scale mappings share a `Ref`; the source scale is expected to be unique at runtime.
- Vector mappings create a `RefVector`; models must handle vector inputs, and order follows MTG traversal order.
- Same-scale renaming creates a per-status alias, not a graph-wide shared variable.
- `PreviousTimeStep` prevents same-step dependency edges and is the standard way to break cycles.

### Multirate configuration

Use `ModelSpec` when models run at different clocks, consume streams with temporal policies, aggregate meteo, or need scoped streams.

```julia
daily = ClockSpec(24.0, 1.0)

plant_spec =
    ModelSpec(PlantDailyModel()) |>
    MultiScaleModel([:leaf_assim => [:Leaf => :A]]) |>
    TimeStepModel(daily) |>
    InputBindings(;
        leaf_assim=(process=:leafassimilation, scale=:Leaf, var=:A, policy=Integrate()),
    ) |>
    ScopeModel(:plant)
```

Policies:

- `HoldLast()` uses the latest producer value.
- `Interpolate()` interpolates or holds/extrapolates producer streams.
- `Integrate()` reduces over the consumer window, usually for fluxes or accumulations.
- `Aggregate()` reduces over the consumer window, usually for means, extrema, or summaries.

Precedence:

1. Input policy: explicit `InputBindings(..., policy=...)` > producer `output_policy` > `HoldLast()`.
2. Timestep: `TimeStepModel(...)` > non-default `timespec(model)` > meteo base step.
3. Meteo sampling: explicit `MeteoBindings(...)`/`MeteoWindow(...)` > `meteo_hint(...)` > runtime defaults.

Use explicit `InputBindings` when several models/scales can produce the same variable, names differ, or the default temporal policy is not correct. Use `OutputRouting(; x=:stream_only)` when a producer should publish a stream without becoming the canonical status owner for `x`.

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
- In MTG runs, `extra` is the `GraphSimulation`; do not use user-defined `extra` arguments for MTG APIs.
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

Use hard dependencies when a parent model directly calls a required submodel inside its own `run!`. The runtime records the dependency but does not automatically execute it for the parent.

```julia
PlantSimEngine.dep(::ParentModel) = (
    child_process=AbstractChild_ProcessModel,
)

function PlantSimEngine.run!(m::ParentModel, models, status, meteo, constants, extra=nothing)
    run!(models.child_process, models, status, meteo, constants, extra)
    status.parent_output = g(status.child_output)
end
```

For multiscale hard dependencies, declare the target scale:

```julia
PlantSimEngine.dep(::ParentModel) = (
    child_process=AbstractChild_ProcessModel => (:Leaf,),
)
```

Then call the child model explicitly on the correct target status, usually via `extra.statuses[:Leaf]` and `extra.models[:Leaf]`. Be careful: hard-dependency IO still participates in graph compilation through the owning soft node.

### Model traits

Add traits only when they are true for the model implementation, not merely convenient for one scenario.

```julia
PlantSimEngine.TimeStepDependencyTrait(::Type{<:MyModel}) =
    PlantSimEngine.IsTimeStepIndependent()

PlantSimEngine.ObjectDependencyTrait(::Type{<:MyModel}) =
    PlantSimEngine.IsObjectIndependent()

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

For user mappings:

- `to_initialize(mapping)` or `to_initialize(mapping, mtg)` lists only variables the user should really provide.
- `dep(mapping)` succeeds and the dependency graph matches the expected coupling.
- `explain_model_specs(mapping)` is sensible for multirate runs.
- Cycles are either absent or intentionally broken with `PreviousTimeStep`.
- Ambiguous multirate producers are resolved with `InputBindings`.

For model implementations:

- Unit-test `inputs_`, `outputs_`, and a direct `run!` call with a minimal `Status`.
- Test single-scale composition when the model is meant to couple by variable name.
- Test MTG/multiscale mapping when the model expects scalar refs, `RefVector` inputs, or cross-scale writes.
- Test multirate behavior when traits, `InputBindings`, `MeteoBindings`, or `OutputRouting` matter.
- Check hard dependencies by proving the parent actually calls the child and uses the child's outputs.

## Common Pitfalls

- Do not confuse hard dependencies with soft dependency scheduling. Hard dependencies are manual calls.
- Do not rely on MTG topology for model execution order. Soft dependency order controls model order.
- Do not assume `RefVector` order has biological meaning.
- Do not map scalar reads from a scale that can have several runtime nodes unless the model really expects the chosen unique source behavior.
- Do not use strings for new scale declarations. Use symbols.
- Do not mutate MTG topology after status initialization unless you reinitialize or use supported dynamic helpers.
- Do not use `PreviousTimeStep` as a numerical lag unless the initial value and expected temporal semantics are explicit.

---
name: plantsimengine
description: Use PlantSimEngine.jl from either the user perspective, composing existing models into single-scale, multiscale, vector-of-object, or multirate simulations, or the modeler perspective, implementing, wrapping, translating, testing, and documenting models with processes, inputs_, outputs_, run!, hard dependencies, traits, and ModelMapping integration.
---

# PlantSimEngine Skill

Use this skill when helping with PlantSimEngine.jl simulations, model mappings,
multiscale MTG coupling, vector-of-object workflows, multirate execution, or
implementing/wrapping process models.

PlantSimEngine work usually has one of two viewpoints:

- **User viewpoint**: compose existing process models into a bigger simulation.
  The main tools are `ModelMapping`, `Status`, `MultiScaleModel`, `ModelSpec`,
  `InputBindings`, `to_initialize`, `dep`, `graph_view`, and `run!`.
- **Modeler viewpoint**: define, wrap, or translate models so users can compose
  them. The main tools are `@process`, `inputs_`, `outputs_`, `run!`, `dep`,
  model traits, and tests that prove the model works in mappings.

Prefer current APIs: `ModelMapping`, `ModelSpec`, `MultiScaleModel`, `Status`,
`PreviousTimeStep`, and `run!`. Treat `ModelList` as legacy compatibility unless
the user is explicitly working on old code. For Julia execution, use Kaimon.

## First Decision

Before editing or answering, decide which role the request is about.

Use the **user workflow** when the user says things like:

- "couple these models"
- "build a plant/scene model"
- "convert this single-scale simulation to multiscale"
- "map leaves into a plant model"
- "run one model hourly and another daily"
- "why does this mapping ask me to initialize this variable?"

Use the **modeler workflow** when the user says things like:

- "implement a new model/process"
- "wrap this equation/code/package"
- "translate this model to PlantSimEngine"
- "make this model usable in multiscale simulations"
- "add hard dependencies or traits"
- "write tests for this model"

When in doubt, start by inspecting existing declarations:

```sh
rg "@process|abstract type Abstract.*Model|inputs_\\(|outputs_\\(|PlantSimEngine.run!|dep\\(" src examples docs test
```

Useful runtime queries are `process(model)`, `inputs(model)`, `outputs(model)`,
`variables(model)`, `to_initialize(mapping[, mtg])`, `dep(mapping)`,
`graph_view(mapping)`, `resolved_model_specs(mapping)`, and
`explain_model_specs(mapping)`.

## User Workflow: Compose Existing Models

The user is trying to make existing models work together. Optimize for a
working mapping, then for clarity.

### 1. Inventory model IO

For each model, identify:

- the process name: `process(model)`;
- required inputs: `inputs(model)`;
- produced outputs: `outputs(model)`;
- variables still needing user initialization after coupling:
  `to_initialize(mapping)`.

Do not decide initialization from `inputs(model)` alone. In a coupled mapping,
some inputs are computed by upstream models and should not be put in `Status`.

### 2. Single-scale coupling

Use `ModelMapping` when every model shares one status.

```julia
mapping = ModelMapping(
    ModelA(args...),
    ModelB(args...);
    status=(driver=1.0,),
)

to_initialize(mapping)
out = run!(mapping, meteo)
```

Rules:

- Soft dependencies are inferred by matching input names to output names.
- The order in the `ModelMapping` is not the semantic model order; the
  dependency graph controls execution.
- Variables not produced by another model must come from `status`, model
  defaults, meteo, constants, or another supported source.
- In single-scale runs, vector values in `status` are usually timestep series:
  the runtime updates the current value each timestep.
- If two models publish the same canonical output, inspect the graph and
  disambiguate before relying on incidental behavior.

### 3. Move from single-scale to multiscale

Use a scale-keyed `ModelMapping` when running on an MTG. Scales should be
symbols such as `:Scene`, `:Plant`, `:Leaf`, and `:Internode`; string scale
names are deprecated.

```julia
mapping = ModelMapping(
    :Scene => (
        SceneDriverModel(),
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

to_initialize(mapping)
out = run!(mtg, mapping, meteo)
```

Core rule: a model sees only its local scale status unless an input is mapped
from another scale or supplied by multirate input binding. A scale in the
mapping does not run unless the MTG contains nodes with that scale symbol.

### 4. Choose scalar or vector mappings deliberately

Use `MultiScaleModel(model, mapped_variables)` or:

```julia
ModelSpec(model) |> MultiScaleModel(mapped_variables)
```

Common mapping forms:

```julia
:x => :Plant                         # scalar read from :Plant, same variable
:x => (:Plant => :y)                 # scalar read from :Plant variable :y
:x => [:Leaf]                        # vector read from all :Leaf nodes
:x => [:Leaf, :Internode]            # vector read from several scales
:x => [:Leaf => :a, :Internode => :b] # vector read with per-scale renaming
:x => (Symbol("") => :y)             # same-scale rename or alias
PreviousTimeStep(:x)                 # remove current-step dependency edge
PreviousTimeStep(:x) => (:Plant => :y)
```

Semantics:

- Scalar cross-scale mappings use shared `Ref`s and assume the source scale is
  unique enough for the scenario.
- Vector mappings create a `RefVector`, even when there is currently one source
  node. Treat it as a vector-like object, not as a scalar.
- `RefVector` reads dereference source statuses; writes mutate the source
  status cells. Use broadcasting for in-place vector outputs when appropriate.
- `RefVector` order follows MTG traversal/initialization order, not biological
  priority.
- Same-scale renaming creates a per-status alias, not a graph-wide shared
  variable.
- `PreviousTimeStep` is the standard way to break a same-step dependency cycle,
  but only use it when the initial value and lag semantics are intentional.

Vector-of-object mappings are for models such as carbon allocation at the plant
scale consuming values from many leaf or internode objects. The model
implementation must tolerate vector inputs, dynamic length changes in growing
MTGs, and traversal-order semantics.

### 5. Use ModelSpec for scenario configuration

`ModelSpec` is user-side configuration around an existing model. Use it when
the scenario needs runtime policy, not when the model definition itself should
change.

```julia
plant_spec =
    ModelSpec(PlantDailyModel()) |>
    MultiScaleModel([:leaf_assim => [:Leaf => :A]]) |>
    TimeStepModel(ClockSpec(24.0, 1.0)) |>
    InputBindings(;
        leaf_assim=(process=:leafassimilation, scale=:Leaf, var=:A, policy=Integrate()),
    ) |>
    ScopeModel(:plant)
```

Use explicit `InputBindings` when:

- several producers can provide the same variable;
- a producer is cross-scale and inference is ambiguous;
- variable names differ;
- the temporal policy must be `Integrate`, `Aggregate`, or `Interpolate`
  instead of default `HoldLast`.

Policy precedence:

1. Input policy: explicit `InputBindings(..., policy=...)` > producer
   `output_policy` > `HoldLast()`.
2. Timestep: `TimeStepModel(...)` > non-default `timespec(model)` > meteo base
   step.
3. Meteo sampling: explicit `MeteoBindings(...)`/`MeteoWindow(...)` >
   `meteo_hint(...)` > runtime defaults.

Use `OutputRouting(; x=:stream_only)` when a model should publish a temporal
stream without becoming the canonical status owner for `x`.

### 6. Validate before long runs

Recommended order:

1. Build the smallest mapping that should work.
2. Run `to_initialize(mapping)` or `to_initialize(mapping, mtg)`.
3. Run `dep(mapping)` to check graph construction and cycles.
4. Use `graph_view(mapping)` or `write_graph_view(...)` for visual debugging.
5. For multirate mappings, inspect `resolved_model_specs(mapping)` and
   `explain_model_specs(mapping)`.
6. Run a short simulation with minimal `tracked_outputs`.

## Modeler Workflow: Implement, Wrap, Or Translate Models

The modeler is creating code that users will compose later. Optimize for a
clear model contract and predictable coupling behavior.

### 1. Choose the process

Process identity is the abstract process type, not the concrete model name.
Search before adding a new process. Reuse an existing process when the new
model is an alternative implementation of the same biological or physical
process.

Create a new process only when the simulated process is genuinely new:

```julia
PlantSimEngine.@process "maintenance_respiration" verbose=false
```

This creates an abstract process type such as
`AbstractMaintenance_RespirationModel`. Concrete implementations subtype that
abstract process.

### 2. Implement the model contract

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

- `inputs_` and `outputs_` are authoritative and must return `NamedTuple`s.
- Use `NamedTuple()` for no inputs or no outputs.
- Defaults are initialization hints; choose values that make missing data
  obvious unless a true default is meaningful.
- `variables(model)` merges inputs and outputs; if a variable appears in both,
  the output declaration wins.
- `run!` is one timestep for one status. Do not loop over timesteps inside a
  normal model `run!`.
- Read and write timestep-varying state through `status`, not model fields.
- Put fixed parameters in the model struct.
- Read weather through `meteo` and constants through `constants`.
- In MTG runs, `extra` is the `GraphSimulation`; do not rely on user-defined
  `extra` arguments for MTG APIs.

Prefer parametric fields and promotion/default constructors when useful:

```julia
struct MyModel{T} <: AbstractSome_ProcessModel
    p1::T
    p2::T
end

MyModel(p1, p2) = MyModel(promote(p1, p2)...)
MyModel(; p1=1.0, p2=2.0) = MyModel(p1, p2)
```

### 3. Wrap or translate existing code

When wrapping an existing model, first separate its contract from its
implementation details:

1. Identify true inputs, outputs, parameters, weather needs, constants, units,
   timestep assumptions, and mutable state.
2. Put fixed parameters in the struct.
3. Put timestep-varying state, intermediate variables that must be coupled, and
   outputs in `Status`.
4. Convert internal side effects into explicit `status` assignments.
5. Keep unit and timestep assumptions in docstrings and traits.
6. Split a large external model into several PlantSimEngine models when users
   need to couple, replace, or inspect subprocesses independently.
7. Keep it as one model only when subprocesses are inseparable implementation
   details.

Do not preserve an external model's timestep loop inside `run!` unless you are
intentionally implementing a model that internally solves a subproblem at a
finer scale and exposes only one PlantSimEngine timestep result.

### 4. Write vector-aware models carefully

A model that consumes or produces values across many MTG objects should declare
vector defaults:

```julia
PlantSimEngine.inputs_(::AllocationModel) =
    (carbon_assimilation=[-Inf], carbon_demand=[-Inf])

PlantSimEngine.outputs_(::AllocationModel) =
    (carbon_allocation=[-Inf],)
```

Implementation rules:

- Expect `status.x` to be a `RefVector` or another vector-like object.
- Use `sum`, broadcasting, `map`, and generic `AbstractVector` operations.
- For vector outputs backed by source statuses, mutate in place:
  `status.carbon_allocation .= values`.
- In dynamic MTGs, source and target vector lengths can temporarily differ.
  Handle shared prefixes and initialize remaining values deliberately.
- Do not attach semantics to vector order unless the MTG traversal order is part
  of the model contract and tested.

### 5. Declare hard dependencies only for direct calls

Use hard dependencies when a parent model directly calls another process inside
its own `run!`. The runtime records the dependency but the parent model is
responsible for executing it.

```julia
PlantSimEngine.dep(::ParentModel) = (
    child_process=AbstractChild_ProcessModel,
)

function PlantSimEngine.run!(m::ParentModel, models, status, meteo, constants, extra=nothing)
    run!(models.child_process, models, status, meteo, constants, extra)
    status.parent_output = g(status.child_output)
    return nothing
end
```

For multiscale hard dependencies, declare target scale(s):

```julia
PlantSimEngine.dep(::ParentModel) = (
    child_process=AbstractChild_ProcessModel => (:Leaf,),
)
```

Then call the child on the correct scale status, usually via
`extra.statuses[:Leaf]` and `extra.models[:Leaf]`, or through the status
returned by dynamic MTG helpers such as `add_organ!`. Do not call a child model
with the parent's status when the child lives at another scale.

Hard-dependency IO still participates in graph compilation through the owning
soft node. Test both the manual call and the graph shape.

### 6. Add traits only when they are true

Traits describe model behavior. `ModelSpec` describes scenario configuration.
Do not use traits to hide a one-off scenario choice.

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

Parallel traits are mainly for single-scale execution. Multirate MTG execution
is currently sequential.

## Validation Checklist

For user mappings:

- `to_initialize(mapping)` or `to_initialize(mapping, mtg)` lists only variables
  the user should provide.
- `dep(mapping)` succeeds and the graph matches the intended coupling.
- `graph_view(mapping)` makes producer/consumer relationships clear.
- Cycles are absent or intentionally broken with `PreviousTimeStep`.
- Scalar mappings point to genuinely unique sources for the scenario.
- Vector mappings are consumed by models that expect vector-like values.
- Ambiguous multirate producers are resolved with `InputBindings`.
- Duplicate publishers are either removed or routed with `OutputRouting`.

For model implementations:

- Test `inputs_`, `outputs_`, and `variables`.
- Test a direct `run!` call with a minimal `Status`.
- Test single-scale composition when the model should couple by variable name.
- Test MTG scalar mapping when the model reads from another scale.
- Test vector mapping when the model expects `RefVector` inputs or outputs.
- Test cycle breaking when `PreviousTimeStep` is part of the workflow.
- Test multirate behavior when traits, bindings, meteo sampling, output routing,
  or scopes matter.
- Test hard dependencies by proving the parent declares and calls the child.

## Common Pitfalls

- Using `inputs(model)` instead of `to_initialize(mapping)` to decide what users
  must provide.
- Putting a model at a scale that does not exist in the MTG and expecting it to
  run.
- Passing a multiscale mapping to `run!(mapping, meteo)` instead of
  `run!(mtg, mapping, meteo)`.
- Using strings for new scale declarations. Use symbols.
- Treating vector mappings as copied arrays instead of shared `RefVector`s.
- Assuming `RefVector` order has biological meaning.
- Mapping scalar reads from a scale that can have several runtime nodes.
- Putting timestep vectors directly in multiscale `Status` when a driver model
  or generated status-vector helper would be clearer.
- Using `PreviousTimeStep` as a casual numerical lag without specifying the
  initial value and intended lag semantics.
- Declaring `dep` for a soft dependency that should be inferred from
  input/output names.
- Forgetting that hard dependencies are manual calls.
- Storing timestep-varying state in model fields.
- Omitting explicit `InputBindings` in ambiguous multirate cases.
- Forgetting `OutputRouting(; x=:stream_only)` when duplicate producers should
  publish streams but not own the canonical status variable.

## High-Signal Local References

- User coupling: `docs/src/step_by_step/simple_model_coupling.md`,
  `docs/src/model_coupling/model_coupling_user.md`.
- Single to multiscale: `docs/src/multiscale/single_to_multiscale.md`.
- Multiscale mapping and vector inputs: `docs/src/multiscale/multiscale.md`,
  `docs/src/multiscale/multiscale_coupling.md`,
  `examples/ToyCAllocationModel.jl`.
- Cycles: `docs/src/multiscale/multiscale_cyclic.md`.
- Multirate: `docs/src/multirate/introduction.md`,
  `docs/src/multirate/multirate_tutorial.md`,
  `docs/src/multirate/advanced_configuration.md`.
- Model implementation: `docs/src/step_by_step/implement_a_model.md`,
  `docs/src/step_by_step/implement_a_model_additional.md`,
  `docs/src/FAQ/translate_a_model.md`.
- Internals: `src/component_models/Status.jl`,
  `src/component_models/RefVector.jl`, `src/mtg/MultiScaleModel.jl`,
  `src/mtg/ModelSpec.jl`, `src/mtg/mapping/compute_mapping.jl`,
  `src/run.jl`.

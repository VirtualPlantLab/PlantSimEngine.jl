# Port an existing model

Start from the scientific calculation and separate four concerns: immutable
parameters, object state, environment forcing, and produced values. The
`run!` method should remain a readable account of one target and one
timestep, while PlantSimEngine owns object selection, scheduling, and value
transport.

## A complete small kernel

This pedagogical model grows leaf area index from temperature. Its numerical
values illustrate the interface only; they are not a calibrated plant model.

```@example port-existing-model
using Dates
using PlantSimEngine

PlantSimEngine.@process "docs_lai_growth" verbose=false

struct DocsLAIGrowth{T} <: AbstractDocs_Lai_GrowthModel
    rate::T
end

PlantSimEngine.inputs_(::DocsLAIGrowth) = (lai=Required(Real),)
PlantSimEngine.outputs_(model::DocsLAIGrowth) = (
    lai_next=zero(model.rate),
)
PlantSimEngine.environment_inputs_(model::DocsLAIGrowth) = (
    T=zero(model.rate),
)
PlantSimEngine.environment_outputs_(::DocsLAIGrowth) = NamedTuple()

const DOCS_LAI_CONTRACT = VariableContract(
    unit=:m2_leaf_per_m2_ground,
    basis=:ground,
    temporal=:instantaneous,
    aggregation=:state,
    extent=:intensive,
)
const DOCS_TEMPERATURE_CONTRACT = VariableContract(
    unit=:degree_celsius,
    basis=:air,
    temporal=:instantaneous,
    aggregation=:state,
    extent=:intensive,
)

PlantSimEngine.variable_contracts_(::DocsLAIGrowth) = (
    lai=DOCS_LAI_CONTRACT,
    lai_next=DOCS_LAI_CONTRACT,
    T=DOCS_TEMPERATURE_CONTRACT,
)

function PlantSimEngine.run!(
    model::DocsLAIGrowth,
    status,
    environment,
    constants,
    context,
)
    status.lai_next = status.lai + model.rate * environment.T
    return nothing
end
```

The struct contains only fixed parameters. Status fields contain values that
can change between timesteps. The environment contains sampled forcing.
`VariableContract` records scientific meaning at coupling boundaries without
wrapping the numerical values.

Keep parameter and status types generic. `Required(Real)`,
`zero(model.rate)`, and a parametric model field allow compatible values such
as `Float32`, measurements with uncertainty, or automatic-differentiation
numbers. Do not convert inputs to `Float64` inside the kernel.

## Test before composing

Call the kernel directly first:

```@example port-existing-model
growth = DocsLAIGrowth(0.02f0)
status = Status(lai=1.0f0, lai_next=0.0f0)
PlantSimEngine.run!(
    growth,
    status,
    (T=10.0f0,),
    nothing,
    nothing,
)
(lai_next=status.lai_next, value_type=typeof(status.lai_next))
```

Then exercise initialization, environment binding, and scheduling through the
ordinary runtime:

```@example port-existing-model
model = CompositeModel(
    growth;
    status=(lai=1.0f0,),
    environment=(T=10.0f0, duration=Day(1)),
)

validation = Authoring.validate_model(growth; strict=true)
@assert validation.valid
initialization = Diagnostics.explain_initialization(model)
simulation = run!(model)
@assert final_state(simulation).lai_next == 1.2f0
final_state(simulation)
```

These levels separate a scientific-equation error from a model-contract error
and a scenario-binding error. Continue with
[Model repository layout and tests](@ref) for the full test pyramid.

## Keep the scientific narrative visible

Prefer one continuous kernel that can be read from inputs to outputs. Extract a
helper only when it is:

- a named scientific equation worth testing or citing separately;
- reused by several model implementations;
- an iterative or numerical algorithm that would obscure the process
  equation; or
- a measured optimization whose details should be isolated.

Do not split every arithmetic line into a helper. Conversely, if users need to
replace a subprocess independently, implement that subprocess as its own
PlantSimEngine model instead of hiding it in a helper or a large
`variant` branch.

Reset instantaneous outputs before an early return, keep timestep-varying state
out of the model struct, and finish `run!` with `return nothing`. Model code
should not search the object graph or infer its own timestep; declare those
requirements through ports, selectors, hard calls, and traits.

## Porting checklist

1. Identify fixed parameters, status inputs, environment inputs, outputs, and
   mutable state.
2. Decide whether independently replaceable subprocesses need separate models.
3. Replace implicit defaults and sentinels with `Required(T)` or a
   scientifically meaningful `Default(value)`.
4. Declare units, basis, temporal meaning, aggregation, and extent with
   `VariableContract` where values are coupled.
5. Convert hidden calls into a declared `Call` only when the parent must own
   child execution.
6. Test the kernel, then a minimal composition, before a full scenario.

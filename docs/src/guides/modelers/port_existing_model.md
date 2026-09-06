# Port an existing model

Start from a calculation you already understand and test it before moving it.
Identify its fixed parameters, the values that change during a simulation,
the environmental data it needs, and the results it calculates. Keep the
equation unchanged while giving each quantity a clear place.

## Begin with an existing calculation

This small teaching function computes a new leaf area index from its current
value and a linear temperature response. The coefficients are arbitrary;
this is not a calibrated growth model. It represents one update over a fixed
interval.

```@example port-existing-model
using Dates, Test, PlantSimEngine

old_lai_step(lai, temperature, response) = lai + response * temperature
expected = old_lai_step(1.0f0, 10.0f0, 0.02f0)
expected
```

Before porting a real model, record its units, time interval, assumptions,
and expected results. If it calculates a rate, check how that rate becomes
an amount: for example, where a daily growth rate is multiplied by the
number of days.

## Map each quantity to its role

| Quantity | Role in this example | Place in PlantSimEngine |
|---|---|---|
| Response coefficient | Fixed parameter for one update | Model field |
| Current LAI | Current leaf area per ground area | `status.lai` |
| Air temperature | Environmental input, degrees Celsius | `environment.T` |
| New LAI | Result of this update | `status.lai_next` |

The complete declarations are:

```@example port-existing-model
@process "docs_lai_growth" verbose=false
struct DocsLAIGrowth{T} <: AbstractDocs_Lai_GrowthModel
    response::T
end

PlantSimEngine.inputs_(::DocsLAIGrowth) = (lai=Required(Real),)
PlantSimEngine.outputs_(model::DocsLAIGrowth) = (
    lai_next=zero(model.response),
)
PlantSimEngine.environment_inputs_(model::DocsLAIGrowth) = (
    T=zero(model.response),
)
PlantSimEngine.environment_outputs_(::DocsLAIGrowth) = NamedTuple()
```

`Required` means the simulation must supply the current LAI. The output and
environment declarations use the parameter's numerical type. A real model
should reuse its package's existing process where appropriate; see
[New process or new model?](@ref).

## Preserve the physical meanings

Both LAI values describe leaf area per unit ground area. Temperature is in
degrees Celsius. We record these meanings with `VariableContract`, which
also describes whether each variable is a current value, a rate, or a total:

```@example port-existing-model
const DOCS_LAI_CONTRACT = VariableContract(
    unit=:m2_leaf_per_m2_ground, basis=:ground, temporal=:instantaneous,
    aggregation=:state, extent=:intensive,
)
const DOCS_TEMPERATURE_CONTRACT = VariableContract(
    unit=:degree_celsius, basis=:air, temporal=:instantaneous,
    aggregation=:state, extent=:intensive,
)
PlantSimEngine.variable_contracts_(::DocsLAIGrowth) = (
    lai=DOCS_LAI_CONTRACT,
    lai_next=DOCS_LAI_CONTRACT,
    T=DOCS_TEMPERATURE_CONTRACT,
)
```

Here `temporal=:instantaneous` and `aggregation=:state` describe current
values. `extent=:intensive` means that adding values from two objects does
not give their combined value: two air temperatures, for example, cannot
be added to obtain the temperature of both objects together.

These descriptions help check that connected models interpret a variable in
the same way. They do not convert values or prove that the equation is
scientifically valid.

## Keep the calculation readable

The function now reads from the declared locations and assigns the result:

```@example port-existing-model
function PlantSimEngine.run!(
    model::DocsLAIGrowth, status, environment, constants, context,
)
    status.lai_next = status.lai + model.response * environment.T
    return nothing
end
```

Use helpers for substantial equations, reused calculations, or numerical
algorithms. Keep a short equation visible rather than splitting every
arithmetic step into a separate function.

## Compare with the original before composing

```@example port-existing-model
growth = DocsLAIGrowth(0.02f0)
status = Status(lai=1.0f0, lai_next=0.0f0)
PlantSimEngine.run!(growth, status, (T=10.0f0,), nothing, nothing)
@test status.lai_next == expected
@test status.lai_next isa Float32
@test Authoring.validate_model(growth; strict=true).valid
status.lai_next
```

Then check the ordinary simulation path with the same inputs:

```@example port-existing-model
scenario = CompositeModel(
    growth;
    status=(lai=1.0f0,),
    environment=(T=10.0f0, duration=Day(1)),
)
result = final_state(run!(scenario)).lai_next
@test result == expected
result
```

This example computes a single new value. For repeated updates, decide
explicitly how that value becomes the next input; see
[State, History, And Repeated Updates](@ref).

## Extend only what your model needs

Keep values that change over time in each object's status and fixed
parameters in the model. Preserve the numerical types your model supports
rather than converting every value to `Float64`. If an output describes the
current step, assign it every time the model runs, including when a condition
ends the calculation early. Otherwise, an old result may be mistaken for
today's result.

If users need to replace one part of the calculation or run it at a different
frequency, make that part a separate model. Use [Coupling models](@ref) for its connections and
[Model repository layout and tests](@ref) for broader validation.

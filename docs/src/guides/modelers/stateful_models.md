# State, History, And Repeated Updates

A model may need yesterday's value or a short memory of earlier values.
Keep that changing memory in each object's `Status`. The model itself holds
fixed parameters and may be shared by many objects.

These are different needs:

| Need | Where it belongs |
|---|---|
| Current state used by the next calculation | The object's `Status` |
| A previous value from a model output | An explicit `PreviousTimeStep` input |
| Internal memory needed by an algorithm | Declared state fields in each object's `Status` |
| A record to plot or analyse after the run | Retained simulation outputs |

## Example: a mean of three daily observations

Suppose we want the mean of today's soil-water fraction and the two preceding
daily observations:

**mean = (today + previous observation + older observation) / 3**

All three observations are dimensionless fractions. This example shows how
each soil object keeps its own past observations. It does not model plant
water stress.

```@example object_memory
using Dates, Test, PlantSimEngine

@process "docs_three_day_mean" verbose=false
struct DocsThreeDayMean <: AbstractDocs_Three_Day_MeanModel end

PlantSimEngine.inputs_(::DocsThreeDayMean) = (
    water_fraction=Required(Real),
)
PlantSimEngine.outputs_(::DocsThreeDayMean) = (
    previous_fraction=0.0,
    older_fraction=0.0,
    mean_fraction=0.0,
)
PlantSimEngine.environment_inputs_(::DocsThreeDayMean) = NamedTuple()
PlantSimEngine.environment_outputs_(::DocsThreeDayMean) = NamedTuple()
```

The two memory fields are outputs because this model updates them. Their
initial values must represent observations before the first simulated day.
Each object can supply different initial values. The `VariableContract`
descriptions below record that the observations are soil-water fractions,
while the result is a mean of three daily samples.

```@example object_memory
const FRACTION_SAMPLE = VariableContract(
    unit=:fraction, basis=:soil_water, temporal=:instantaneous,
    aggregation=:state, extent=:intensive,
)
const FRACTION_MEAN = VariableContract(
    unit=:fraction, basis=:soil_water, temporal=:three_daily_samples,
    aggregation=:mean, extent=:intensive,
)
PlantSimEngine.variable_contracts_(::DocsThreeDayMean) = (
    water_fraction=FRACTION_SAMPLE,
    previous_fraction=FRACTION_SAMPLE,
    older_fraction=FRACTION_SAMPLE,
    mean_fraction=FRACTION_MEAN,
)

function PlantSimEngine.run!(
    ::DocsThreeDayMean, status, environment, constants, context,
)
    status.mean_fraction =
        (status.water_fraction + status.previous_fraction + status.older_fraction) / 3
    status.older_fraction = status.previous_fraction
    status.previous_fraction = status.water_fraction
    return nothing
end
```

Calculate the mean before shifting the memory: reversing that order would
use today's observation twice.

## Check the calculation directly

```@example object_memory
model = DocsThreeDayMean()
sample = Status(
    water_fraction=0.6, previous_fraction=0.3, older_fraction=0.3,
    mean_fraction=0.0,
)
PlantSimEngine.run!(model, sample, nothing, nothing, nothing)
@test sample.mean_fraction ≈ 0.4
@test sample.previous_fraction == 0.6
@test sample.older_fraction == 0.3
sample.mean_fraction
```

## Keep two objects' histories independent

Here the observations stay constant during the example. A real simulation
would read each day's value from a dataset or another model.

```@example object_memory
dry = Object(
    :dry_soil; scale=:Soil,
    status=Status(water_fraction=0.6, previous_fraction=0.3, older_fraction=0.3),
)
wet = Object(
    :wet_soil; scale=:Soil,
    status=Status(water_fraction=0.9, previous_fraction=0.9, older_fraction=0.9),
)
scenario = CompositeModel(
    dry, wet;
    applications=(ModelSpec(model; name=:water_mean, on=Many(scale=:Soil)),),
    environment=(duration=Day(1),),
)
@test Authoring.validate_model(model; strict=true).valid

simulation = run!(scenario; outputs=:all)
day_one = (
    dry=final_state(simulation, :dry_soil).mean_fraction,
    wet=final_state(simulation, :wet_soil).mean_fraction,
)
@test day_one.dry ≈ 0.4
@test day_one.wet ≈ 0.9

step!(simulation)
day_two = (
    dry=final_state(simulation, :dry_soil).mean_fraction,
    wet=final_state(simulation, :wet_soil).mean_fraction,
)
@test day_two.dry ≈ 0.5
@test day_two.wet ≈ 0.9
(day_one=day_one, day_two=day_two)
```

Both objects use the same model. Their separate status fields keep the dry
soil's earlier observations from affecting the wet soil's mean. If an
algorithm stores earlier values in an array, give each object its own array
as well. An array stored in the shared model would mix the objects' histories.

## Delays, repeated calls, and output history

Use `PreviousTimeStep` when an input should read another model's accepted
result from the previous time step. The
[model execution reference](../../model_execution.md) shows how to declare
this input. If several models deliberately update the same variable, use
`Updates` to set their order; see [Control Advanced Execution](@ref).

A trial call with `publish=false` does not save its result as an accepted
output sample. It can still change values in `status`, and those changes
are not automatically undone. A model that tries several solutions must
decide which changes to keep. Update a history like the one above once per
accepted observation, so rejected trials do not enter the mean.

Use [Collecting And Plotting Outputs](@ref) to retain and analyse a result
series. Keeping outputs and maintaining a model's own short memory serve
different purposes.

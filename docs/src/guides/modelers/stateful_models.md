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

All three observations are dimensionless fractions. This is a teaching
example of memory ownership, not a model of plant water stress.

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
Each object can supply different initial values.

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

Here the observations stay constant during the example. A real scenario
would supply the daily values from forcing data or another model.

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
algorithm needs a mutable history array, each object must own its own array
as well; do not put one shared buffer in the model.

## Delays, repeated calls, and output history

Use `PreviousTimeStep` when an input should read a producer's previous
accepted timestep. The [model execution reference](../../model_execution.md)
shows that declaration. [Control Advanced Execution](@ref) explains intentional
multiple writers with `Updates`.

A call with `publish=false` suppresses publication; it does not automatically
restore every state field the scientific algorithm mutates. An iterative
controller must manage trial state and acceptance deliberately. Advance a
history like the one above once per accepted observation.

Use [Collecting And Plotting Outputs](@ref) to retain and analyse a result
series. Keeping outputs and maintaining a model's own short memory serve
different purposes.

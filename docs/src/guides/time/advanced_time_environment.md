# Choose Compatible Time Steps

Use this page when a simulation rejects an application cadence, or when
several models need different time steps. For choosing how values pass between
those models, start with [Different model cadences](../../journeys/users/cadences.md).

## Find a common base step

The simulation advances on a fixed base step, supplied by the environment's
`duration`. Each `every` must be a positive integer multiple of that duration.
PlantSimEngine does not insert intermediate steps automatically.

| Model cadences | A suitable base step |
|:--|:--|
| Every hour and every day | One hour |
| Every hour and every 90 minutes | 30 minutes |
| Every 250 ms and every second | 250 ms |

A smaller step may also work, but increases the number of simulation steps.
Choose one supported by the equations and by the available forcing data.
Resampling measurements requires an explicit interpolation or aggregation
choice; changing `duration` alone does not create the missing observations.

## Example: hourly and 90-minute sampling

Two temperature readers illustrate the schedule without introducing a new
scientific model. Both start at the first time point, then run at their own
cadence:

```@example compatible_steps
using PlantSimEngine, Dates, DataFrames
using PlantSimEngine.Examples

model = CompositeModel(
    Object(:hourly; scale=:Sensor, name=:hourly),
    Object(:ninety_minutes; scale=:Sensor, name=:ninety_minutes);
    applications=(
        ModelSpec(ToyEnvironmentReaderModel(); name=:hourly,
            on=One(name=:hourly), every=Hour(1)),
        ModelSpec(ToyEnvironmentReaderModel(); name=:ninety_minutes,
            on=One(name=:ninety_minutes), every=Minute(90)),
    ),
    environment=(T=20.0, duration=Minute(30)),
)
simulation = run!(model; steps=7, outputs=:all)
rows = collect_outputs(simulation; sink=DataFrame)
combine(groupby(rows, :application_id), nrow => :samples)
```

The seven base time points cover 0 to 3 hours: the hourly reader publishes
four samples, and the other publishes three. The first sample is at the
origin, not after a completed hour.

```@example compatible_steps
@assert count(==(:hourly), rows.application_id) == 4 # hide
@assert count(==(:ninety_minutes), rows.application_id) == 3 # hide
nothing # hide
```

## Check the resolved configuration

Use `Diagnostics.explain_schedule(model)` to inspect cadence and clock origin.
Use `Diagnostics.explain_bindings(model)` for the selected producer, temporal
policy, and window, and `Diagnostics.explain_environment_bindings(model)` for
environment sources and reducers.

`every` overrides a model's default `timespec`. When cadence comes from the
environment base step, a `timestep_hint` can check compatibility; an explicit
`every` is the scenario author's choice and must suit the equations. Fixed
periods such as `Day(1)` are supported. Calendar months have varying lengths,
so `Month(1)` is rejected. Windows are rolling durations, not automatically
aligned civil days or previous complete calendar periods.

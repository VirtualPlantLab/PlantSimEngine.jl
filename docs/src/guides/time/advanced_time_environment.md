# Choose Compatible Time Steps

Use this page when a simulation rejects how often you want a model to run,
or when several models need different time steps. To choose how those models
share values between updates, start with
[Different model cadences](../../journeys/users/cadences.md).

## Find a common base step

The simulation advances by a fixed interval, called the **base step**. Set it
with the environment's `duration`. A model's `every` value must be a positive
whole number of base steps. PlantSimEngine does not add smaller steps for you.

| Model cadences | A suitable base step |
|:--|:--|
| Every hour and every day | One hour |
| Every hour and every 90 minutes | 30 minutes |
| Every 250 ms and every second | 250 ms |

A smaller step may also work, but increases the number of simulation steps.
Choose one that suits the equations and your weather data. If you need values
between measurements, choose how to estimate them. If you need less frequent
values, choose how to combine the measurements, for example by averaging.
Changing `duration` alone does not calculate these values.

## Example: hourly and 90-minute sampling

Two simple models read temperature at different intervals. Both run at the
start of the simulation, then one runs every hour and the other every
90 minutes:

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

The seven time points cover 0 to 3 hours. The hourly reader records four
results, and the other records three. Both record their first result at
time zero.

```@example compatible_steps
@assert count(==(:hourly), rows.application_id) == 4 # hide
@assert count(==(:ninety_minutes), rows.application_id) == 3 # hide
nothing # hide
```

## Check when models run and where inputs come from

Use these tables to check the configuration:

- `Diagnostics.explain_schedule(model)` shows when each model starts and how
  often it runs.
- `Diagnostics.explain_bindings(model)` shows which model supplies each input
  and how earlier values are used, including the rule and time window.
- `Diagnostics.explain_environment_bindings(model)` shows the weather or
  spatial data each model reads and how values are combined over time.

Setting `every` replaces the model's default cadence from `timespec`. If you
leave the cadence to the environment's base step, the model can check it with
`timestep_hint`. If you set `every` yourself, you must check that the equations
support that interval.

Fixed periods such as `Day(1)` are supported. Calendar months vary in length,
so `Month(1)` is rejected. A time window looks back over its specified
duration. For example, `Day(1)` does not automatically mean the preceding
midnight-to-midnight day.

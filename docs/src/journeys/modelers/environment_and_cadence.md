# Implement Environment And Cadence Traits

A model may need air temperature or may be intended to run once a day.
Describe these requirements alongside the model's equation. The simulation
setup then chooses where the temperature comes from and how often the model
runs. This update frequency is also called its **cadence**.

Start with [Understand Environments](@ref) and
[Give Models Different Cadences](@ref) for the scenario-user perspective.

## Declare an environmental input

This teaching model simply copies the environmental temperature to an output.
It shows how to read environmental data before adding a biological equation.
These are its actual definitions in `examples/ToySpatialEnvironment.jl`:

```@eval
Main.DocsSources.section(
    "examples/ToySpatialEnvironment.jl",
    "struct ToyEnvironmentReaderModel",
    "\"\"\"\n    ToyEnvironmentControllerModel",
)
```

`environment_inputs_` declares `T`, and `run!` reads it from
`environment.T`. The model does not need to know whether the temperature
comes from a weather file or varies with position in the canopy.

Test that read directly:

```@example modeler_environment_time
using Dates, Test, PlantSimEngine
using PlantSimEngine.Examples

reader = ToyEnvironmentReaderModel()
sample = Status(temperature_seen=0.0)
PlantSimEngine.run!(reader, sample, (T=25.0,), nothing, nothing)
@test sample.temperature_seen == 25.0
sample.temperature_seen
```

Then supply an environment through the simulation:

```@example modeler_environment_time
model = CompositeModel(
    reader;
    environment=(T=25.0, duration=Hour(1)),
)
result = final_state(run!(model)).temperature_seen
@test result == 25.0
result
```

A scientific model should also declare the temperature's units and meaning
with `variable_contracts_`, as in [Implement a basic model](@ref).
Use [Port an existing model](@ref) for an equation that combines environmental
temperature with object state.

## Give a model a default cadence

The next teaching model adds a fixed increment whenever it runs. By default,
it runs every 24 simulation steps. Other models can keep reading its latest
result until it runs again:

```@eval
Main.DocsSources.section(
    "examples/ToyModelDeveloper.jl",
    "PlantSimEngine.inputs_(::ToyDailyDevelopmentModel)",
)
```

`timespec` sets the default update frequency. `output_policy` describes how
other models read the result between updates. Here `HoldLast` tells them to
use the latest available value; it does not run this equation again.

`ClockSpec(24.0, 1.0)` means every 24 base steps, starting at step 1. It
corresponds to a day only when the base step is an hour. In a scenario,
`every=Day(1)` expresses the intended duration directly:

```@example modeler_environment_time
daily = ToyDailyDevelopmentModel(2.0)
daily_model = CompositeModel(
    Object(:plant; scale=:Plant);
    applications=(
        ModelSpec(
            daily; name=:daily_development, on=One(scale=:Plant),
            every=Day(1),
        ),
    ),
    environment=[(duration=Hour(1),) for _ in 1:25],
)

daily_simulation = run!(daily_model; steps=25, outputs=:all)
growth = final_state(daily_simulation).daily_growth
@test growth == 4.0
growth
```

The model runs at steps 1 and 25, adding 2 each time. When connecting another
model, you can choose to average or add results over an interval instead of
keeping the last value. The choice depends on what the variable represents;
see [Give Models Different Cadences](@ref).

Give a model a default update frequency only when its equations require one.
Choose weather data, timing for a particular study, and results to save in
the simulation setup.

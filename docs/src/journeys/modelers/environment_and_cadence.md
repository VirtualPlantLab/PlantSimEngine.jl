# Implement Environment And Cadence Traits

A process may read air temperature from its environment and may have a
preferred time step. Declare those requirements beside the model; the scenario
chooses the data provider and can configure its execution cadence.

Start with [Understand Environments](@ref) and
[Give Models Different Cadences](@ref) for the scenario-user perspective.

## Declare an environmental input

This teaching model simply copies the environmental temperature to an output.
It isolates the interface before introducing a biological equation.
These are its actual definitions in `examples/ToySpatialEnvironment.jl`:

```@eval
Main.DocsSources.section(
    "examples/ToySpatialEnvironment.jl",
    "struct ToyEnvironmentReaderModel",
    "\"\"\"\n    ToyEnvironmentControllerModel",
)
```

`environment_inputs_` declares `T`, and `run!` reads it from
`environment.T`. The model does not choose a weather file or spatial provider.

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

The next teaching model adds a fixed increment whenever it runs. Its source
declares a default of 24 simulation steps and allows consumers to hold its
last output between updates:

```@eval
Main.DocsSources.section(
    "examples/ToyModelDeveloper.jl",
    "PlantSimEngine.inputs_(::ToyDailyDevelopmentModel)",
)
```

`timespec` gives a model default. `output_policy` gives a default interpretation
for consumers reading between publications. The equation still updates only
when the application runs.

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

The model runs at steps 1 and 25, adding 2 each time. A consumer can override
`HoldLast` when averaging or accumulating values has the appropriate physical
meaning. See [Give Models Different Cadences](@ref) before choosing that policy.

Keep a model default only when it belongs to the scientific implementation.
Data providers, scenario-specific timing, and the choice of output history
remain part of the simulation configuration.

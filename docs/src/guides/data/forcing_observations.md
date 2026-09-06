# Use Observed Values In A Simulation

You can supply measured leaf area index (LAI) while calculating light
interception. This is useful for testing the light model independently of a
model that predicts LAI. Here LAI is m² leaf per m² ground, and incident PAR
is an energy flux in W m⁻² ground.

## One fixed observation

Supply a constant LAI in status and use only the light model:

```@example observed_lai
using PlantSimEngine, Dates, DataFrames
using PlantSimEngine.Examples

fixed_model = CompositeModel(
    Beer(0.6);
    status=(LAI=2.0,), id=:canopy, scale=:Canopy,
    environment=(Ri_PAR_f=100.0, duration=Day(1)),
)
fixed_simulation = run!(fixed_model; outputs=:all)
final_state(fixed_simulation).aPPFD
```

Do not add a second model that also writes LAI: its output would replace the
supplied value. A status value is an initial or fixed input, not a rule that
overrides a running producer.

## A sequence of observations

For time-varying observations, use a model that reads each observation and
publishes LAI. The small `ObservedLAI` definition below only copies the value;
it performs no fitting, interpolation, or unit conversion. Include it from the
downloadable source to run the example:

```@example observed_lai
include("observed_lai.jl")

observations = DataFrame(
    duration=fill(Day(1), 3),
    measured_LAI=[1.0, 2.0, 3.0],
    Ri_PAR_f=fill(100.0, 3),
)
model = CompositeModel(
    ObservedLAI(), Beer(0.6);
    id=:canopy, scale=:Canopy, environment=observations,
)
simulation = run!(model; steps=nrow(observations), outputs=:all)
rows = collect_outputs(simulation; sink=DataFrame)
filter(row -> row.variable == :LAI || row.variable == :aPPFD, rows)
```

```@example observed_lai
@assert final_state(simulation).LAI == 3.0 # hide
@assert count(==(:LAI), rows.variable) == 3 # hide
nothing # hide
```

`Beer` receives the published LAI through the usual same-object connection.
To predict LAI instead, replace `ObservedLAI()` with `ToyLAIModel()` and supply
the thermal time that model requires. A change of model can change the inputs
you must provide; [compare alternatives](../../step_by_step/model_switching.md)
before making a replacement.

## The observation model

The complete [source file](observed_lai.jl) is short:

```@eval
Main.DocsSources.section("docs/src/guides/data/observed_lai.jl", "struct ObservedLAI")
```

Before using real measurements, check their units, area basis, time stamps,
and missing values. The example has one observation per regular daily row.
For sparse measurements, choose and document an interpolation or holding rule
before supplying the forcing. This workflow prescribes a measured variable;
it is not a data-assimilation method that estimates uncertainty or updates
other state variables.

See [Collect and plot results](outputs_plotting.md) for displaying predictions
alongside observations and [Parameter fitting](../../working_with_data/fitting.md)
when the objective is to estimate model parameters.

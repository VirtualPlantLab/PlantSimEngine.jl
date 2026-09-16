# Use Observed Values In A Simulation

You can supply measured leaf area index (LAI) while calculating light
interception. This is useful for testing the light model independently of a
model that predicts LAI. Here LAI is m² leaf per m² ground, and incident PAR
is an energy flux in W m⁻² ground.

## One fixed observation

Supply a constant LAI in `status`, where the canopy stores its values, and
use only the light model:

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

If you add a model that calculates LAI, it will replace this supplied value
when it runs. To keep the observed LAI fixed, use it without an LAI model.

## A sequence of observations

For observations that change over time, use a model that reads each
observation and supplies it as LAI. The small `ObservedLAI` model below only copies the value;
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

PlantSimEngine passes LAI from `ObservedLAI` to `Beer` automatically: one model
supplies it and the other needs it on the same canopy.
To predict LAI instead, replace `ObservedLAI()` with `ToyLAIModel()` and supply
the thermal time that model requires. A change of model can change the inputs
you must provide; [compare alternatives](../../step_by_step/model_switching.md)
before making a replacement.

## The observation model

The complete [source file](observed_lai.jl) is short:

```@eval
Main.DocsSources.section("docs/src/guides/data/observed_lai.jl", "struct ObservedLAI")
```

Before using real measurements, check their units, whether they refer to
leaf or ground area, their time stamps, and any missing values. This example
has one observation per day. If your measurements are less frequent, decide
how to fill the gaps: for example, interpolate between measurements or keep
the last measured value until the next one. Document that choice before
using the data. This approach supplies a measured input directly. It does
not perform data assimilation, which would use observations to estimate or
correct the model state and could account for measurement uncertainty.

See [Collect and plot results](outputs_plotting.md) for displaying predictions
alongside observations and [Parameter fitting](../../working_with_data/fitting.md)
when the objective is to estimate model parameters.

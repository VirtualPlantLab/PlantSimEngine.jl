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
when it runs. To keep the observed LAI fixed, leave out that predictive model,
or replace it with a model that supplies the observed value. In a composed
scenario, the observation model should own the supplied output. Adding it
alongside another writer of the same variable can create a writer conflict;
`Diagnostics.explain_writers(model)` helps check ownership.

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

## Match measurements to the simulation

Before using real measurements, check their source, units, whether they refer
to leaf or ground area, their time stamps or measurement intervals, and any
missing or rejected values. Associate measurements with stable object IDs;
display names need not be unique. A plot-scale observation may also need an
explicit aggregation or conversion before it can supply an organ-scale model.

This example has one observation per simulation day and one canopy. Its
environment rows are already in simulation order; the observation model does
not look up values by date or object ID. Prepare that alignment before using
it. For several objects, arrange the observation source and bindings so each
object receives its own measurement.

If measurements are less frequent than model execution, choose how to fill
the gaps: for example, interpolate between measurements or keep the last
measured value until the next one. State the interval over which each value
applies and the policy for gaps or values outside the measured period.
Document that choice before using the data. Filling a gap does not create
a new independent observation for evaluation.

This approach supplies a measured input directly. It does not perform data
assimilation, which would use observations to estimate or correct the model
state and could account for measurement uncertainty. It also changes the
question being tested: predicted light absorption under measured LAI checks
the light component while treating canopy development as supplied data.

See [Collect and plot results](outputs_plotting.md) for retaining outputs and
matching predictions with measurements, and [Parameter fitting](../../working_with_data/fitting.md)
for calibration followed by independent evaluation. The observation-forcing
prompt in [Work with an AI coding agent](../../agent_skill.md) can help you
adapt this pattern to documented measurements and your intended objects.

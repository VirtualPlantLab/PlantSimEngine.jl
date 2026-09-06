# Couple Models On One Object

## New concept: automatic same-object coupling over time

This teaching example couples three existing models on one simulated entity,
called an **object**. Here, that object represents a canopy without describing
individual organs. A **process** is a scientific calculation, such as thermal
time or light interception; a model implements its equations. The toy models
below demonstrate coupling and are not a calibrated crop model:

1. `ToyDegreeDaysCumulModel` reads temperature and accumulates thermal time.
2. `ToyLAIModel` reads cumulative thermal time and computes LAI.
3. `Beer` reads LAI and radiation and computes absorbed PAR.

Start with the [tutorial installation](../../prerequisites/installing_plantsimengine.md)
if these packages are not yet available in your Julia project.

The weather file is supplied forcing data for now. Environments get their own
journey later. Its radiation columns contain daily totals in MJ m⁻² d⁻¹;
we convert them to mean fluxes in W m⁻², as required by `Beer`.

```@example journey_one_object
using PlantSimEngine, PlantMeteo, Dates, DataFrames
using PlantSimEngine.Examples

weather = read_weather(
    joinpath(pkgdir(PlantSimEngine), "examples/meteo_day.csv"),
    :Ri_SW_f => (x -> x .* 1e6 ./ 86_400) => :Ri_SW_f,
    :Ri_PAR_f => (x -> x .* 1e6 ./ 86_400) => :Ri_PAR_f,
    :Ri_NIR_f => (x -> x .* 1e6 ./ 86_400) => :Ri_NIR_f;
    duration=Day,
)

model = CompositeModel(
    ToyDegreeDaysCumulModel(),
    ToyLAIModel(),
    Beer(0.6);
    environment=weather,
)
```

No `ModelSpec` or selector is needed when all models run on the one object made
by the concise constructor.

Run the first thirty daily steps and retain the model outputs. This short
winter window is useful for learning how to run and continue a simulation;
thermal time accumulates slowly and LAI stays small. The
[homepage](../../index.md) and [plotting guide](../../guides/data/outputs_plotting.md)
show longer or more varied runs.

```@example journey_one_object
simulation = run!(model; steps=30, outputs=:all)
results = collect_outputs(simulation)

thermal_time = results[results.variable .== :TT_cu, :value]
lai = results[results.variable .== :LAI, :value]
evolution = DataFrame(
    step=1:length(thermal_time),
    TT_cu=thermal_time,
    LAI=lai,
)
vcat(first(evolution, 3), last(evolution, 3))
```

`TT_cu` is cumulative thermal time in °C d; LAI is leaf area per ground area
in m² m⁻². The table is retained history. The latest values are also available directly,
whether or not history was requested:

```@example journey_one_object
state_at_day_30 = final_state(simulation)
(
    current_step=current_step(simulation),
    TT_cu=state_at_day_30.TT_cu,
    LAI=state_at_day_30.LAI,
    aPPFD=state_at_day_30.aPPFD,
    retained_streams=length(outputs(simulation)),
)
```

`aPPFD` is absorbed PAR in μmol m⁻² of ground s⁻¹, averaged over the daily
forcing interval. It is not a flux per unit leaf area.

PlantSimEngine inferred both status connections because each has one
unambiguous producer on the same object. This focused diagnostic shows the
resolved sources and the live reference carriers:

```@example journey_one_object
select(
    DataFrame(Diagnostics.explain_bindings(model)),
    :application_id,
    :input,
    :source_application_ids,
    :carrier_kind,
)
```

A `Simulation` owns a continuing timeline. Advancing it does not rebuild a
separate result object:

```@example journey_one_object
step!(simulation)
state_at_day_31 = final_state(simulation)
(current_step=current_step(simulation), TT_cu=state_at_day_31.TT_cu)
```

You have now extended the same history to day 31. Continue with
[several independent objects](several_objects.md), or
[plot the results](../../guides/data/outputs_plotting.md).

!!! tip "Optional numerical choices"
    If your study needs `Float32` or uncertainty values, see
    [Numerical Reliability](@ref). Those choices are independent of the
    coupling and output steps introduced here.

## Page recap

- **You added:** three models, supplied weather, a 30-step run, and retained
  outputs.
- **PlantSimEngine inferred:** the one object, three applications, their
  execution order, and the `TT_cu` and `LAI` connections.
- **You keep explicit:** model parameters, forcing data, number of steps, and
  whether output history is retained.
- **New API names:** `CompositeModel`, `run!`, `Simulation`, `final_state`,
  `collect_outputs`, `outputs`, `current_step`, `step!`, and
  `Diagnostics.explain_bindings`.

# Couple Models On One Object

## New concept: automatic same-object coupling over time

This first executable simulation couples three existing models on one object:

1. `ToyDegreeDaysCumulModel` reads temperature and accumulates thermal time.
2. `ToyLAIModel` reads cumulative thermal time and computes LAI.
3. `Beer` reads LAI and radiation and computes absorbed PAR.

The weather file is supplied forcing data for now. Environments get their own
journey later.

```@example journey_one_object
using PlantSimEngine, PlantMeteo, Dates, DataFrames
using PlantSimEngine.Examples

weather = read_weather(
    joinpath(pkgdir(PlantSimEngine), "examples/meteo_day.csv");
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

!!! tip "Choose a status type for the whole scenario"
    Add `type_promotion=Dict(Float64 => Float32)` to the constructor to
    materialize every matching status scalar, model input default, and model
    output default as `Float32`. Ordinary numeric arrays are converted element
    by element. Model parameters such as `Beer(0.6)` and values supplied by
    `weather` keep their own types.

    Use `status_transform=(variable, value) -> ...` when only selected
    variables need another representation. The precise transform runs before
    the general type mapping. See [Numerical Reliability](@ref) for complete
    `Float32` and uncertainty-propagation examples.

Run thirty daily steps and retain the model outputs:

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

The table is retained history. The latest values are also available directly,
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
- **Optional status policies:** `type_promotion` for a general type mapping and
  `status_transform` for a variable-specific conversion.

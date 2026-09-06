# Run The Coupling On Several Objects

## New concept: stable object identity and `Many`

Run the same teaching models on two independent canopies with different
initial development stages. Each canopy is one object; `Many(scale=:Canopy)`
selects both. This lets you compare the two canopies without writing a loop
inside any process model. The selected initial thermal times make their
different leaf area indices visible even over this short, five-day run.

```@example journey_several_objects
using PlantSimEngine, PlantMeteo, Dates, DataFrames
using PlantSimEngine.Examples

weather = read_weather(
    joinpath(pkgdir(PlantSimEngine), "examples/meteo_day.csv"),
    :Ri_SW_f => (x -> x .* 1e6 ./ 86_400) => :Ri_SW_f,
    :Ri_PAR_f => (x -> x .* 1e6 ./ 86_400) => :Ri_PAR_f,
    :Ri_NIR_f => (x -> x .* 1e6 ./ 86_400) => :Ri_NIR_f;
    duration=Day,
)

canopies = (
    Object(
        :canopy_a;
        scale=:Canopy,
        kind=:canopy,
        status=Status(TT_cu=600.0),
    ),
    Object(
        :canopy_b;
        scale=:Canopy,
        kind=:canopy,
        status=Status(TT_cu=900.0),
    ),
)
canopy_targets = Many(scale=:Canopy)

model = CompositeModel(
    canopies...;
    applications=(
        ModelSpec(
            ToyDegreeDaysCumulModel();
            name=:degree_days,
            on=canopy_targets,
        ),
        ModelSpec(ToyLAIModel(); name=:lai, on=canopy_targets),
        ModelSpec(Beer(0.6); name=:light, on=canopy_targets),
    ),
    environment=weather,
)
```

`:canopy_a` and `:canopy_b` are stable object identities. Their initial
cumulative thermal times differ, but the same three model kernels execute for
both. The model implementations contain no loop over canopies.

Run five steps and inspect each independent final status:

```@example journey_several_objects
simulation = run!(model; steps=5, outputs=:all)
states = final_state(simulation, Many(scale=:Canopy))
Dict(
    id => (TT_cu=state.TT_cu, LAI=state.LAI, aPPFD=state.aPPFD)
    for (id, state) in states
)
```

LAI is in m² of leaves per m² of ground; `aPPFD` is in μmol of absorbed PAR
per m² of ground per second. The CSV radiation totals were converted to mean
fluxes just as in the one-object example.

Retained streams are keyed by application, object, and variable, so the two
objects do not overwrite one another:

```@example journey_several_objects
rows = collect_outputs(simulation)
lai_rows = rows[rows.variable .== :LAI, [
    :timestep,
    :application_id,
    :object_id,
    :value,
]]
first(lai_rows, 6)
```

The application diagnostic confirms that each application compiled to both
objects:

```@example journey_several_objects
select(
    DataFrame(Diagnostics.explain_applications(model)),
    :application_id,
    :target_ids,
)
```

This remains a same-scale simulation. Parent/child topology and cross-object
value selection are introduced in [one multiscale plant](one_plant.md). To compare the time
series visually, follow [Collecting And Plotting Outputs](../../guides/data/outputs_plotting.md).

## Page recap

- **You added:** two explicit `Object`s, stable ids, one shared `Many` selector,
  and named `ModelSpec` applications.
- **PlantSimEngine inferred:** two targets per application plus independent
  same-object `TT_cu` and `LAI` connections for each canopy.
- **You keep explicit:** which objects exist, their initial status, application
  names, and the selector describing the target set.
- **New API names:** `Object`, `Status`, `ModelSpec`, `Many`, and
  `Diagnostics.explain_applications`.

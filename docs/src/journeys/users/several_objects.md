# Run The Coupling On Several Objects

## New concept: stable object identity and `Many`

The previous page ran one model chain on one automatically created object. The
smallest extension is to create two same-scale objects and target both with one
reusable `Many` selector.

```@example journey_several_objects
using PlantSimEngine, PlantMeteo, Dates, DataFrames
using PlantSimEngine.Examples

weather = read_weather(
    joinpath(pkgdir(PlantSimEngine), "examples/meteo_day.csv");
    duration=Day,
)

plants = (
    Object(
        :plant_a;
        scale=:Plant,
        kind=:plant,
        status=Status(TT_cu=0.0),
    ),
    Object(
        :plant_b;
        scale=:Plant,
        kind=:plant,
        status=Status(TT_cu=200.0),
    ),
)
plant_targets = Many(scale=:Plant)

model = CompositeModel(
    plants...;
    applications=(
        ModelSpec(
            ToyDegreeDaysCumulModel();
            name=:degree_days,
            on=plant_targets,
        ),
        ModelSpec(ToyLAIModel(); name=:lai, on=plant_targets),
        ModelSpec(Beer(0.6); name=:light, on=plant_targets),
    ),
    environment=weather,
)
```

`:plant_a` and `:plant_b` are stable object identities. Their initial
cumulative thermal times differ, but the same three model kernels execute for
both. The model implementations contain no loop over plants.

The application diagnostic confirms that each application compiled to both
objects:

```@example journey_several_objects
select(
    DataFrame(Diagnostics.explain_applications(model)),
    :application_id,
    :target_ids,
)
```

Run five steps and inspect each independent final status:

```@example journey_several_objects
simulation = run!(model; steps=5, outputs=:all)
states = final_state(simulation, Many(scale=:Plant))
Dict(
    id => (TT_cu=state.TT_cu, LAI=state.LAI, aPPFD=state.aPPFD)
    for (id, state) in states
)
```

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

This remains a same-scale simulation. Parent/child topology and cross-object
value selection are introduced on the next journey, after independent object
execution is established.

## Page recap

- **You added:** two explicit `Object`s, stable ids, one shared `Many` selector,
  and named `ModelSpec` applications.
- **PlantSimEngine inferred:** two targets per application plus independent
  same-object `TT_cu` and `LAI` connections for each plant.
- **You keep explicit:** which objects exist, their initial status, application
  names, and the selector describing the target set.
- **New API names:** `Object`, `Status`, `ModelSpec`, `Many`, and
  `Diagnostics.explain_applications`.


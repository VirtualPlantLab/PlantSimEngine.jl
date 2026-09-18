# Run The Coupling On Several Objects

Run the same teaching models on two independent canopies with different
initial development stages. Each canopy is one object; `Many(scale=:Canopy)`
selects both. This lets you compare the two canopies without writing a loop
inside each model. We start the canopies at different cumulative thermal
times so their leaf area indices differ visibly over this short, five-day run.

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

The IDs `:canopy_a` and `:canopy_b` identify the canopies throughout the
simulation. Both use the same three models, but each keeps its own values.
PlantSimEngine runs the models for each canopy, so the model code does not
need a loop over canopies.

Run five daily steps and read the final values for each canopy:

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

The saved results include the model application name, canopy ID, and
variable name. This keeps the two LAI time series separate:

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

You can also check which objects each model will run on. The table below
should list both canopies for each application:

```@example journey_several_objects
select(
    DataFrame(Diagnostics.explain_applications(model)),
    :application_id,
    :target_ids,
)
```

The two canopies run independently here. In [one multiscale plant](one_plant.md),
you will connect a plant to its leaves and pass values between them. To
compare the canopy time series visually, follow
[Collecting And Plotting Outputs](../../guides/data/outputs_plotting.md).

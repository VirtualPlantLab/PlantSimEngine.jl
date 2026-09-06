# Couple Models On One Object

In this example, we combine three models to calculate how a canopy develops
and absorbs light over 30 days. We represent the whole canopy as one
**object**: one part of the simulated system, with its own values. We do not
describe individual leaves here.

The three models pass values to one another:

1. `ToyDegreeDaysCumulModel` uses temperature to calculate cumulative thermal
   time, a measure of accumulated warmth.
2. `ToyLAIModel` uses that thermal time to calculate leaf area index (LAI).
3. `Beer` uses LAI and incoming radiation to calculate the light absorbed by the canopy.

These are teaching models with illustrative parameters. They show how to
connect calculations; their results are not predictions for a particular crop.

Start with the [tutorial installation](../../prerequisites/installing_plantsimengine.md)
if these packages are not yet available in your Julia project.

## Prepare the weather data

We use a weather file included with PlantSimEngine. Each row describes one day.
The file records daily radiation totals in MJ m⁻² d⁻¹. `Beer` needs the average
radiation during that day in W m⁻², so the code below converts those columns.
`SW` means shortwave radiation, `PAR` is the light used for photosynthesis,
and `NIR` means near-infrared radiation. The weather data are called the
**environment** in this simulation.

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
nothing # hide

```

## Connect the models

Put the three models together in a `CompositeModel` and give it the weather data:

```@example journey_one_object
model = CompositeModel(
    ToyDegreeDaysCumulModel(),
    ToyLAIModel(),
    Beer(0.6);
    environment=weather,
)
```

PlantSimEngine connects these models automatically. The thermal-time model
provides `TT_cu` to the LAI model, which provides `LAI` to `Beer`. Each input
has the same name as an output from exactly one other model on this canopy.
PlantSimEngine also runs the models in that order, so each calculation can
use the result it needs.

## Run 30 days and look at the results

`run!` starts the simulation. Here, `steps=30` runs the first 30 weather rows,
and `outputs=:all` saves the results from every model at each step.
`collect_outputs(simulation; sink=DataFrame)` gathers those saved results
into a DataFrame, the table type provided by DataFrames.jl. `DataFrame` is
already the default, so you can also write `collect_outputs(simulation)`.

These first 30 days fall in winter, so thermal time increases slowly and LAI
stays small. The [plotting guide](../../guides/data/outputs_plotting.md) shows
how to plot results and compare two canopies.

```@example journey_one_object
simulation = run!(model; steps=30, outputs=:all)
results = collect_outputs(simulation; sink=DataFrame)
first(select(results, :timestep, :variable, :value), 8)
```

Each row records one variable on one day. The last line selects three
columns and shows the first eight rows: four variables for each of the first
two days. `TT` is daily thermal time and `TT_cu` is cumulative thermal time,
both in °C d. LAI is leaf area per ground area, in m² m⁻².

`final_state` gives the latest values, here at the end of day 30. It is also
available when you run a simulation without saving its history:

```@example journey_one_object
state_at_day_30 = final_state(simulation)
(
    current_step=current_step(simulation),
    TT_cu=state_at_day_30.TT_cu,
    LAI=state_at_day_30.LAI,
    aPPFD=state_at_day_30.aPPFD,
)
```

`aPPFD` measures absorbed photosynthetically active radiation (PAR), the light
available for photosynthesis. Its unit here is μmol of photons per m² of
ground per second, averaged over the day. The area refers to the ground
covered by the canopy, rather than the area of its leaves.

## Continue for another day

`step!` runs the next day and adds its results to the same simulation:

```@example journey_one_object
step!(simulation)
state_at_day_31 = final_state(simulation)
(current_step=current_step(simulation), TT_cu=state_at_day_31.TT_cu)
```

You have now extended the same history to day 31. Continue with
[several independent objects](several_objects.md), or
[plot the results](../../guides/data/outputs_plotting.md).

# Collecting And Plotting Outputs

Plot absorbed light through a day, then compare two canopies with different
leaf area indices. This page uses the existing `Beer` model, so you can focus
on running a simulation and analysing its results. The radiation values are
illustrative, not observations from an experiment.

The [tutorial installation](../../prerequisites/installing_plantsimengine.md)
includes DataFrames for tables and CairoMakie for plots.

## Run and plot one canopy

Supply thirteen hourly PAR fluxes, from 06:00 to 18:00, in W m⁻² of ground.
The canopy has 2 m² of leaves per m² of ground throughout this example.

```@example collect-output
using Dates, DataFrames, CairoMakie, PlantSimEngine
using PlantSimEngine.Examples

incident_par = [0.0, 50, 150, 300, 500, 650, 700, 650, 500, 300, 150, 50, 0]
weather = [(Ri_PAR_f=par, duration=Hour(1)) for par in incident_par]
model = CompositeModel(
    Beer(0.6);
    id=:canopy, scale=:Canopy,
    status=(LAI=2.0,), environment=weather,
)
simulation = run!(model; steps=length(weather), outputs=:all)
rows = collect_outputs(simulation; sink=DataFrame)
light = rows[rows.variable .== :aPPFD, :]
first(light, 3)
```

`sink=DataFrame` asks for a DataFrame; this is already the default if you
leave out `sink`. Each row records one variable for one object at one time,
and identifies which model application produced it.
`aPPFD` is absorbed PAR in μmol m⁻² of ground s⁻¹. The `time` column uses
simulation steps rather than clock hours, with the first record at 1. In
this example each step lasts one hour and the first record is at 06:00, so
`6 + (time - 1)` gives the hour of day. Use your weather data's actual dates
and durations when they follow a different timetable.

```@example collect-output
light.hour_of_day = 6 .+ (light.time .- 1)
figure_one = Figure(size=(740, 380), fontsize=16)
axis_one = Axis(figure_one[1, 1],
    xlabel="Hour of day",
    ylabel="Absorbed PAR\n(μmol m⁻² ground s⁻¹)",
    xticks=6:2:18,
)
scatterlines!(axis_one, light.hour_of_day, light.value;
    color=:seagreen, linewidth=2.5, markersize=7)
@assert nrow(light) == length(incident_par)
@assert first(light.value) == last(light.value) == 0.0
figure_one
```

With fixed leaf area, absorption follows the supplied radiation. This curve
shows a mean flux for each hourly record. To calculate the total absorbed
over an interval, multiply each flux by its duration in seconds and add the
amounts. See [different model cadences](../../journeys/users/cadences.md) for
models that run at different intervals.

## Keep two canopies separate

Apply the same model to two independent canopies. Only their LAI differs.
An application name such as `:light` identifies this configured use of `Beer`.

```@example collect-output
two_canopies = CompositeModel(
    Object(:open_canopy; scale=:Canopy, status=Status(LAI=1.0)),
    Object(:dense_canopy; scale=:Canopy, status=Status(LAI=3.0));
    applications=(ModelSpec(Beer(0.6); name=:light, on=Many(scale=:Canopy)),),
    environment=weather,
)
comparison = run!(two_canopies; steps=length(weather), outputs=:all)
comparison_rows = collect_outputs(comparison; sink=DataFrame)
comparison_light = comparison_rows[
    (comparison_rows.application_id .== :light) .& (comparison_rows.variable .== :aPPFD), :]
comparison_light.hour_of_day = 6 .+ (comparison_light.time .- 1)

figure_two = Figure(size=(740, 380), fontsize=16)
axis_two = Axis(figure_two[1, 1],
    xlabel="Hour of day",
    ylabel="Absorbed PAR\n(μmol m⁻² ground s⁻¹)",
    xticks=6:2:18,
)
for series in groupby(comparison_light, [:application_id, :object_id])
    sort!(series, :time)
    scatterlines!(axis_two, series.hour_of_day, series.value;
        label=string(first(series.object_id)), linewidth=2.5, markersize=6)
end
axislegend(axis_two; position=:lt, framevisible=false)
@assert nrow(comparison_light) == 2 * length(incident_par)
figure_two
```

The denser canopy absorbs more PAR per unit ground area under the same
incoming light. Grouping by application and object keeps the two curves
separate. Filtering only by variable and drawing one line would incorrectly
join different objects.

## Retain only the outputs you need

`outputs=:all` is convenient for these small examples. Larger simulations
can save selected variables with `OutputRequest`. Here, the new run keeps
only the light result requested from the two canopies:

```@example collect-output
selected_simulation = run!(
    two_canopies;
    steps=length(weather),
    outputs=OutputRequest(
        Many(scale=:Canopy), :aPPFD;
        name=:absorbed_light, application=:light,
    ),
)
selected = collect_outputs(selected_simulation, :absorbed_light; sink=DataFrame)
@assert nrow(selected) == 2 * length(incident_par)
first(selected, 4)
```

A new `run!` starts a fresh timeline. Use `step!` or `continue!` when you want
to extend an existing simulation instead. Runs default to `outputs=:none`;
`final_state(simulation)` remains available when you only need the latest
values.

PlantSimEngine may also keep past values because another model needs them,
even if you did not request those values for analysis. When memory use
matters, `Diagnostics.explain_output_retention(simulation)` explains why
each time series is being stored.

## Reading the result tables

The basic result table has the columns `timestep`, `time`, `application_id`,
`object_id`, `variable` and `value`. Tables produced by an `OutputRequest`
also identify `scale` and `process`. Requests that combine values over time
or sample them at new times can return `missing` if there is not enough
saved history. Check when the model ran and when the simulation started
before interpreting a missing result as a gap in the weather observations.

Saved values, including arrays, record the result at that time. Later changes
do not rewrite earlier rows, and removing an organ does not delete its past
results. Compatible numerical types are preserved, including values with
attached physical units when your model uses them.

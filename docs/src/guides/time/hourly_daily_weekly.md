# Hourly, Daily, And Weekly Models

Compare daily and weekly water uptake from the same hourly leaf rates. The
rates below are deliberately constant teaching values: 1 and 2 mg of water
per leaf per second. They demonstrate timing and aggregation, not a model of
plant water demand.

Each total integrates the hourly rates over its own rolling window, then adds
the two leaf amounts. The daily and weekly applications both read the hourly
source, so the weekly result does not add overlapping daily windows.

## Load the two equations

The reusable [teaching models](teaching_models.jl) publish a supplied rate and
sum supplied amounts. Their definitions are included at the end of this page;
you only need to load them to configure this simulation.

```@example hourly-daily
using Dates, DataFrames, PlantSimEngine
include(joinpath(pkgdir(PlantSimEngine), "docs", "src", "guides", "time", "teaching_models.jl"))
using .TeachingTimeModels
```

## Choose the clocks and windows

`every` says when a model runs; `window` says how much source history its
input uses. Hourly, daily and weekly durations all fit an hourly base step.
The reducer multiplies each rate by its represented duration in seconds,
converting mg s⁻¹ into mg before the plant adds the leaf amounts.

```@example hourly-daily
integrate_rate = Integrate((values, durations_seconds) -> sum(values .* durations_seconds))

model = CompositeModel(
    Object(:plant; scale=:Plant),
    Object(:leaf_1; scale=:Leaf, parent=:plant, status=Status(rate_mg_s=1.0)),
    Object(:leaf_2; scale=:Leaf, parent=:plant, status=Status(rate_mg_s=2.0));
    applications=(
        ModelSpec(HourlyWaterRate(); name=:hourly, on=Many(scale=:Leaf), every=Hour(1)),
        ModelSpec(
            SumWaterAmounts(); name=:daily, on=One(scale=:Plant),
            inputs=(amounts_mg=Many(
                scale=:Leaf, within=Subtree(), application=:hourly,
                var=:water_rate_mg_s, policy=integrate_rate, window=Day(1),
            ),),
            every=Day(1),
        ),
        ModelSpec(
            WeeklyWaterAmount(); name=:weekly, on=One(scale=:Plant),
            inputs=(amounts_mg=Many(
                scale=:Leaf, within=Subtree(), application=:hourly,
                var=:water_rate_mg_s, policy=integrate_rate, window=Week(1),
            ),),
            every=Week(1),
        ),
    ),
    environment=[(duration=Hour(1),) for _ in 1:169],
)

simulation = run!(model; steps=169, outputs=:all)
rows = collect_outputs(simulation; sink=DataFrame)
totals = rows[in.(rows.application_id, Ref((:daily, :weekly))),
              [:timestep, :application_id, :variable, :value]]
totals
```

The first execution is at step 1. Both totals initially contain only one
hour of available history: `(1 + 2) × 3600 = 10800 mg`. That is a startup
value, not a complete day or week. The daily application runs again at steps
25, 49, and so on; the weekly application runs again at step 169.

```@example hourly-daily
first_daily = only(totals[(totals.application_id .== :daily) .& (totals.timestep .== 1), :value])
full_day = only(totals[(totals.application_id .== :daily) .& (totals.timestep .== 25), :value])
full_week = only(totals[(totals.application_id .== :weekly) .& (totals.timestep .== 169), :value])
@assert first_daily == 3 * 3600
@assert full_day == 3 * 24 * 3600
@assert full_week == 3 * 7 * 24 * 3600
(startup_mg=first_daily, daily_mg=full_day, weekly_mg=full_week)
```

These are fixed-duration rolling windows, not calendar-aligned civil days or
weeks. All application durations must be integer multiples of the base step;
choose a finer common step if necessary. Calendar months and adaptive steps
are not supported by this scheduler.

`Integrate()` without a reducer only sums samples. Use it for values that are
already the amounts you intend to add, after checking the selected window and
sample boundaries. Rates require duration weighting as above. Use
`Aggregate(reducer)` when the intended result is a mean or another statistic.

## Scientific contracts and outputs

The teaching models leave variable contracts undeclared so this page can
isolate the numeric time policies. These policies do not change contract
metadata. A production model with declared rate and amount contracts needs
an explicit conversion model between those contracts; see
[Coupling models](../coupling.md).

Input windows retain the history needed by the simulation. Your analysis
outputs are a separate choice: see [Collecting And Plotting Outputs](../data/outputs_plotting.md)
for retaining selected results. Inspect the schedule when checking how many
daily or weekly publications to expect, including startup.

## Teaching model source

These simple equations are shared with the [cadence tutorial](../../journeys/users/cadences.md).
They copy each leaf's supplied rate and sum the converted leaf amounts. The
weekly model uses a separate output name so both totals coexist on the plant.

```@eval
using Markdown, PlantSimEngine
Markdown.MD([Markdown.Code("julia", read(joinpath(pkgdir(PlantSimEngine), "docs", "src", "guides", "time", "teaching_models.jl"), String))])
```

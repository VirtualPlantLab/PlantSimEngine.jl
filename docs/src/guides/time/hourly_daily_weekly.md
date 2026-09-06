# Hourly, Daily, And Weekly Models

Compare daily and weekly water uptake from the same hourly leaf rates. The
rates below are deliberately constant teaching values: 1 and 2 mg of water
per leaf per second. They show how to calculate totals over different time
intervals; they do not predict plant water demand.

To calculate each total, multiply the hourly rates by the duration they
represent, then add the two leaves' amounts over a day or a week. Both totals
use the hourly values directly. This avoids counting the same water twice
by adding daily totals whose periods might overlap.

## Load the two equations

The reusable [teaching models](teaching_models.jl) return a supplied rate and
add supplied amounts. Their definitions are included at the end of this page;
load them now to configure this simulation.

```@example hourly-daily
using Dates, DataFrames, PlantSimEngine
include(joinpath(pkgdir(PlantSimEngine), "docs", "src", "guides", "time", "teaching_models.jl"))
using .TeachingTimeModels
```

## Choose update intervals and time windows

`every` says how often a model runs; `window` says how far back it looks for
input values. Hourly, daily and weekly durations all fit an hourly base step.
The function passed to `Integrate` multiplies each rate by the duration it
represents, in seconds. This converts mg s⁻¹ into mg before the plant adds
the leaf amounts.

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

Both totals are calculated at step 1, when only one hour of values is
available: `(1 + 2) × 3600 = 10800 mg`. This first result does not represent
a complete day or week. The daily total is calculated again at steps 25, 49,
and so on; the weekly total is calculated again at step 169.

```@example hourly-daily
first_daily = only(totals[(totals.application_id .== :daily) .& (totals.timestep .== 1), :value])
full_day = only(totals[(totals.application_id .== :daily) .& (totals.timestep .== 25), :value])
full_week = only(totals[(totals.application_id .== :weekly) .& (totals.timestep .== 169), :value])
@assert first_daily == 3 * 3600
@assert full_day == 3 * 24 * 3600
@assert full_week == 3 * 7 * 24 * 3600
(startup_mg=first_daily, daily_mg=full_day, weekly_mg=full_week)
```

Each window looks back over its specified duration. It does not automatically
start at midnight or at the beginning of a calendar week. Each model's cadence
must be a whole number of base steps; choose a smaller common step if needed.
Calendar months and timesteps that change during a run are not supported.

`Integrate()` without a function only adds values. Use it when the values
already represent amounts, and check that the selected window includes each
intended amount once. For rates, multiply by duration as above. Use
`Aggregate(reducer)` to calculate a mean or another statistic, supplying your
calculation as the `reducer` function.

## Scientific contracts and outputs

These teaching models do not declare `VariableContract`s, which describe a
variable's units and physical meaning. The rules for combining values over
time do not change these declarations. If your models declare a rate contract
on one side and an amount contract on the other, connect them through a small
model that performs the conversion and declares both meanings. See
[Coupling models](../coupling.md).

PlantSimEngine keeps the earlier values needed for each input window. Choose
separately which results to save for your own analysis: see
[Collecting And Plotting Outputs](../data/outputs_plotting.md). Check the
schedule to find how many daily or weekly results to expect, including the
first partial result.

## Teaching model source

These simple equations are shared with the [cadence tutorial](../../journeys/users/cadences.md).
They copy each leaf's supplied rate and add the converted leaf amounts. The
weekly model uses a different output name so the plant can store both totals.

```@eval
using Markdown, PlantSimEngine
Markdown.MD([Markdown.Code("julia", read(joinpath(pkgdir(PlantSimEngine), "docs", "src", "guides", "time", "teaching_models.jl"), String))])
```

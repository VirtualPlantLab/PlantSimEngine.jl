# Multi-rate tutorial (hourly + daily + weekly)

This tutorial builds one MTG simulation that mixes three model rates:
- hourly at `Leaf`,
- daily at `Plant`,
- weekly at `Plant`.

It runs for one week and exports clean series at each rate.

## Decision flow quick examples

### Unset model timestep uses meteo cadence (preferred is informational)

```@example multirate_timestep_flow
using PlantSimEngine
using PlantMeteo
using MultiScaleTreeGraph
using DataFrames
using Dates

mtg = Node(NodeMTG("/", :Scene, 1, 0))
plant = Node(mtg, NodeMTG("+", :Plant, 1, 1))
internode = Node(plant, NodeMTG("/", :Internode, 1, 2))
Node(internode, NodeMTG("+", :Leaf, 1, 2))

PlantSimEngine.@process "tutorialmeteodriven" verbose=false
struct TutorialMeteoDrivenModel <: AbstractTutorialmeteodrivenModel
    n::Base.RefValue{Int}
end
PlantSimEngine.inputs_(::TutorialMeteoDrivenModel) = NamedTuple()
PlantSimEngine.outputs_(::TutorialMeteoDrivenModel) = (count=-Inf,)
function PlantSimEngine.run!(m::TutorialMeteoDrivenModel, models, status, meteo, constants=nothing, extra=nothing)
    m.n[] += 1
    status.count = float(m.n[])
end
PlantSimEngine.timestep_hint(::Type{<:TutorialMeteoDrivenModel}) = (; required=(Minute(30), Hour(2)), preferred=Hour(1))

mapping = ModelMapping(:Leaf => (ModelSpec(TutorialMeteoDrivenModel(Ref(0))),))
meteo_30min = Weather([
    Atmosphere(date=DateTime(2025, 6, 12, 12, 0, 0), duration=Minute(30), T=20.0, Wind=1.0, Rh=0.6),
    Atmosphere(date=DateTime(2025, 6, 12, 12, 30, 0), duration=Minute(30), T=21.0, Wind=1.0, Rh=0.6),
    Atmosphere(date=DateTime(2025, 6, 12, 13, 0, 0), duration=Minute(30), T=22.0, Wind=1.0, Rh=0.6),
])

out_meteo_driven = run!(
    mtg,
    mapping,
    meteo_30min;
    executor=SequentialEx(),
    tracked_outputs=Dict(:Leaf => (:count,)),
)
out_meteo_driven_df = PlantSimEngine.convert_outputs(out_meteo_driven, DataFrame)
out_meteo_driven_df[:Leaf][end, :count]
```

The last value is `3.0`, showing the model ran on all three 30-minute meteo rows, even though `preferred=Hour(1)`.

### Explicit coarse `TimeStepModel` triggers integration/aggregation

```@example multirate_timestep_flow
PlantSimEngine.@process "tutorialhalfhoursource" verbose=false
struct TutorialHalfHourSourceModel <: AbstractTutorialhalfhoursourceModel
    n::Base.RefValue{Int}
end
PlantSimEngine.inputs_(::TutorialHalfHourSourceModel) = NamedTuple()
PlantSimEngine.outputs_(::TutorialHalfHourSourceModel) = (A=-Inf,)
function PlantSimEngine.run!(m::TutorialHalfHourSourceModel, models, status, meteo, constants=nothing, extra=nothing)
    m.n[] += 1
    status.A = 1.0 # umol m-2 s-1
end

PlantSimEngine.@process "tutorialhourlyintegrator" verbose=false
struct TutorialHourlyIntegratorModel <: AbstractTutorialhourlyintegratorModel end
PlantSimEngine.inputs_(::TutorialHourlyIntegratorModel) = (A=-Inf,)
PlantSimEngine.outputs_(::TutorialHourlyIntegratorModel) = (A_hourly=-Inf, T_hourly=-Inf,)
function PlantSimEngine.run!(::TutorialHourlyIntegratorModel, models, status, meteo, constants=nothing, extra=nothing)
    status.A_hourly = status.A
    status.T_hourly = meteo.T
end

mapping_coarse = ModelMapping(
    :Leaf => (
        ModelSpec(TutorialHalfHourSourceModel(Ref(0))),
        ModelSpec(TutorialHourlyIntegratorModel()) |>
        TimeStepModel(Hour(1)) |>
        InputBindings(; A=(process=:tutorialhalfhoursource, var=:A, policy=Integrate(DurationSumReducer()))) |>
        MeteoBindings(; T=MeanWeighted()),
    ),
)

meteo_30min_4 = Weather([
    Atmosphere(date=DateTime(2025, 6, 12, 12, 0, 0), duration=Minute(30), T=20.0, Wind=1.0, Rh=0.6),
    Atmosphere(date=DateTime(2025, 6, 12, 12, 30, 0), duration=Minute(30), T=22.0, Wind=1.0, Rh=0.6),
    Atmosphere(date=DateTime(2025, 6, 12, 13, 0, 0), duration=Minute(30), T=24.0, Wind=1.0, Rh=0.6),
    Atmosphere(date=DateTime(2025, 6, 12, 13, 30, 0), duration=Minute(30), T=26.0, Wind=1.0, Rh=0.6),
])

out_coarse = run!(
    mtg,
    mapping_coarse,
    meteo_30min_4;
    executor=SequentialEx(),
    tracked_outputs=Dict(:Leaf => (:A_hourly, :T_hourly)),
)
out_coarse_df = PlantSimEngine.convert_outputs(out_coarse, DataFrame)
(out_coarse_df[:Leaf][end, :A_hourly], out_coarse_df[:Leaf][end, :T_hourly])
```

The final tuple is `(3600.0, 23.0)`: hourly integrated assimilation
(`sum(A .* duration_seconds)` over two 30-minute rows) and hourly mean temperature over the coarse window.

## 1. Setup and example data

We reuse package example assets:
- `examples/meteo_day.csv` for weather,
- `examples/leaf_with_petiole.ply` as an available mesh asset.

```@example multirate_tutorial
using PlantSimEngine
using PlantMeteo
using MultiScaleTreeGraph
using DataFrames
using CSV
using Dates
using Statistics

# Minimal plant: Scene -> Plant -> Internode -> Leaf
mtg = Node(NodeMTG("/", :Scene, 1, 0))
plant = Node(mtg, NodeMTG("+", :Plant, 1, 1))
internode = Node(plant, NodeMTG("/", :Internode, 1, 2))
Node(internode, NodeMTG("+", :Leaf, 1, 2))

meteo_path = joinpath(pkgdir(PlantSimEngine), "examples", "meteo_day.csv")
leaf_mesh_path = joinpath(pkgdir(PlantSimEngine), "examples", "leaf_with_petiole.ply")

@assert isfile(meteo_path)
@assert isfile(leaf_mesh_path)
```

If you want to visualize the mesh file, see [Visualizing our toy plant with PlantGeom](../multiscale/multiscale_example_4.md).

`meteo_day.csv` is daily. We convert one week to an hourly weather table:

```@example multirate_tutorial
daily_df = CSV.read(meteo_path, DataFrame, header=18)
week_df = first(daily_df, 7)

hourly_rows = Atmosphere[]
for row in eachrow(week_df)
    for h in 0:23
        push!(hourly_rows,
            Atmosphere(
                date=DateTime(row.date) + Hour(h),
                duration=Hour(1),
                T=row.T,
                Wind=row.Wind,
                P=row.P,
                Rh=row.Rh,
                Ri_PAR_f=row.Ri_PAR_f,
                Ri_SW_f=row.Ri_SW_f,
            )
        )
    end
end

meteo_hourly = Weather(hourly_rows)
meteo_hourly[1:3] # show the first 3 rows of the hourly weather table
```

## 2. Define simple tutorial models

```@example multirate_tutorial
PlantSimEngine.@process "tutorialleafhourly" verbose=false
struct TutorialLeafHourlyModel <: AbstractTutorialleafhourlyModel end
PlantSimEngine.inputs_(::TutorialLeafHourlyModel) = NamedTuple()
PlantSimEngine.outputs_(::TutorialLeafHourlyModel) = (leaf_assim_h=0.0,)
function PlantSimEngine.run!(::TutorialLeafHourlyModel, models, status, meteo, constants=nothing, extra=nothing)
    status.leaf_assim_h = 0.004 * meteo.Ri_PAR_f
end

PlantSimEngine.@process "tutorialplantdaily" verbose=false
struct TutorialPlantDailyModel <: AbstractTutorialplantdailyModel end
PlantSimEngine.inputs_(::TutorialPlantDailyModel) = (leaf_assim_h=[0.0],)
PlantSimEngine.outputs_(::TutorialPlantDailyModel) = (plant_assim_d=0.0, rad_sw_day=0.0, T=0.0)
function PlantSimEngine.run!(::TutorialPlantDailyModel, models, status, meteo, constants=nothing, extra=nothing)
    status.plant_assim_d = sum(status.leaf_assim_h)
    status.rad_sw_day = meteo.Ri_SW_q
    status.T = meteo.T
end

PlantSimEngine.@process "tutorialplantweekly" verbose=false
struct TutorialPlantWeeklyModel <: AbstractTutorialplantweeklyModel end
PlantSimEngine.inputs_(::TutorialPlantWeeklyModel) = (plant_assim_d=[0.0],)
PlantSimEngine.outputs_(::TutorialPlantWeeklyModel) = (plant_assim_w=0.0,)
function PlantSimEngine.run!(::TutorialPlantWeeklyModel, models, status, meteo, constants=nothing, extra=nothing)
    status.plant_assim_w = sum(status.plant_assim_d)
end
```

## 3. Configure multi-rate mapping

```@example multirate_tutorial
hourly = 1.0
daily = ClockSpec(24.0, 0.0)
weekly = ClockSpec(168.0, 0.0)

leaf_proc = process(TutorialLeafHourlyModel())
plant_daily_proc = process(TutorialPlantDailyModel())
plant_weekly_proc = process(TutorialPlantWeeklyModel())

mapping = ModelMapping(
    :Leaf => (
        ModelSpec(TutorialLeafHourlyModel()) |>
        TimeStepModel(hourly) |>
        ScopeModel(:plant),
    ),
    :Plant => (
        ModelSpec(TutorialPlantDailyModel()) |>
        ScopeModel(:plant) |>
        MultiScaleModel([:leaf_assim_h => :Leaf]) |>
        TimeStepModel(daily) |>
        MeteoBindings(
            ;
            T=MeanWeighted(),
            Rh=MeanWeighted(),
            Ri_SW_q=(source=:Ri_SW_f, reducer=RadiationEnergy()),
        ) |>
        InputBindings(; leaf_assim_h=(process=leaf_proc, var=:leaf_assim_h, scale=:Leaf, policy=Integrate())),
        ModelSpec(TutorialPlantWeeklyModel()) |>
        ScopeModel(:plant) |>
        TimeStepModel(weekly) |>
        InputBindings(; plant_assim_d=(process=plant_daily_proc, var=:plant_assim_d, policy=Integrate())),
    ),
)
```

## 4. Run and export hourly/daily/weekly series

Run directly from `mtg + mapping` and request exported series.

```@example multirate_tutorial
req_leaf_hourly = OutputRequest(:Leaf, :leaf_assim_h;
    name=:leaf_assim_hourly,
    process=leaf_proc,
    policy=HoldLast(),
)

req_plant_daily = OutputRequest(:Plant, :plant_assim_d;
    name=:plant_assim_daily,
    process=plant_daily_proc,
    policy=HoldLast(),
    clock=daily,
)

req_plant_daily_T = OutputRequest(:Plant, :T;
    name=:T_daily,
    process=plant_daily_proc,
    policy=HoldLast(),
    clock=daily,
)

req_plant_weekly = OutputRequest(:Plant, :plant_assim_w;
    name=:plant_assim_weekly,
    process=plant_weekly_proc,
    policy=HoldLast(),
    clock=weekly,
)

out_status, exported = run!(
    mtg,
    mapping,
    meteo_hourly;
    executor=SequentialEx(),
    tracked_outputs=[req_leaf_hourly, req_plant_daily, req_plant_daily_T, req_plant_weekly],
    return_requested_outputs=true,
)

leaf_hourly_df = exported[:leaf_assim_hourly]
plant_daily_df = exported[:plant_assim_daily]
plant_daily_df_T = exported[:T_daily]
plant_weekly_df = exported[:plant_assim_weekly]
```

Quick checks:

```@example multirate_tutorial
@show nrow(leaf_hourly_df)    # 168 (1 leaf x 168 hours)
@show nrow(plant_daily_df)    # 7   (1 plant x 7 days)
@show nrow(plant_weekly_df)   # 1   (1 plant x 1 week)

leaf_hourly_df.day = repeat(1:7, inner=24)
leaf_hourly_sum = combine(groupby(leaf_hourly_df, :day), :value => sum => :leaf_assim_h_sum)
```

Manually computing daily sums from the hourly series confirms the daily assimilation matches the sum of hourly assimilation:

```@example multirate_tutorial
plant_daily_df
```

Of course the outputs of the models are still available in the `status_outputs` returned by `run!`, and can be converted to DataFrames as well:

```@example multirate_tutorial
outs = convert_outputs(out_status, DataFrame)
outs[:Plant][1:3,:]
```

## 5. Deeper notes

### Calendar-aligned windows

If your daily model must use the current civil day (instead of trailing 24h), use:

```@example multirate_tutorial
ModelSpec(TutorialPlantDailyModel()) |>
TimeStepModel(daily) |>
MeteoWindow(CalendarWindow(:day; anchor=:current_period, week_start=1, completeness=:strict))
```

Likewise, use `:week` or `:month` for weekly/monthly calendar windows.

### Shared reducers

Reducer objects work for model inputs and meteo bindings:

- `InputBindings(..., policy=Integrate(...)/Aggregate(...))`,
- `MeteoBindings(..., reducer=...)`.
- For duration-aware accumulation (for example flux to amount), use
  `Integrate(DurationSumReducer())` or an equivalent two-argument callable
  `Integrate((values, durations_seconds) -> sum(values .* durations_seconds))`.

### Inspect resolved specs

```@example multirate_tutorial
explain_model_specs(mapping)
```

This prints resolved timestep, input bindings, meteo bindings, and meteo window per model process.

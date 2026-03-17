# Multi-rate tutorial (hourly + daily + weekly)

This tutorial builds one MTG simulation that mixes three model rates:
- hourly at `Leaf`,
- daily at `Plant`,
- weekly at `Plant`.

It runs for one week and exports clean series at each rate.

The goal here is not to build a realistic plant model. Instead, the objective is
to make the mechanics of multi-rate execution easy to see:

- how PlantSimEngine decides when a model runs;
- how values are transferred from a faster model to a slower one;
- how meteorological inputs are reduced over a coarse time window;
- how to export clean hourly, daily, and weekly series from the same run.

We begin with two very small examples that isolate the scheduling rules, then we
assemble a complete hourly/daily/weekly MTG simulation.

## Decision flow quick examples

Before building the full example, it helps to establish two important rules:

1. if a model does not declare an explicit timestep, it follows the meteo cadence;
2. if a model is forced to run more coarsely than its inputs, then explicit input
   and meteo binding policies determine how information is aggregated.

### Simple example with implicit meteo cadence

Model may define a trait calles `timestep_hint` that describes the acceptable and preferred cadences for that model. However, that trait is purely descriptive: it does not force the model to run at any particular rate. If you want to force a model to run at a specific cadence, you must declare an explicit `TimeStepModel(...)` in the mapping. Otherwise, the model will simply run whenever the meteo cadence allows it to, and the `timestep_hint` can be used for validation or explanation but does not silently reschedule the model.

Let's define a tiny model that simply counts how many times it ran, then feed it
three 30-minute weather rows:

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
```

This model is designed to run between every 30 minutes and every 2 hours, with a preferred cadence of 1 hour. Let's make a mapping with the model but without an explicit `TimeStepModel(...)`:

```@example multirate_timestep_flow
mapping = ModelMapping(:Leaf => (TutorialMeteoDrivenModel(Ref(0)),))
```

Let's define a 30-minute weather table with three rows:

```@example multirate_timestep_flow
meteo_30min = Weather([
    Atmosphere(date=DateTime(2025, 6, 12, 12, 0, 0), duration=Minute(30), T=20.0, Wind=1.0, Rh=0.6),
    Atmosphere(date=DateTime(2025, 6, 12, 12, 30, 0), duration=Minute(30), T=21.0, Wind=1.0, Rh=0.6),
    Atmosphere(date=DateTime(2025, 6, 12, 13, 0, 0), duration=Minute(30), T=22.0, Wind=1.0, Rh=0.6),
])
```

Now we run the model and check how many times it ran over those three 30-minute rows:

```@example multirate_timestep_flow
out_meteo_driven = run!(
    mtg,
    mapping,
    meteo_30min;
    executor=SequentialEx(),
    tracked_outputs=Dict(:Leaf => (:count,)),
)
out_meteo_driven[:Leaf][end]
```

The last value for `:count` is `3.0`, showing the model ran on all three 30-minute meteo rows,
even though `preferred=Hour(1)`.

That is the key point: without `TimeStepModel`, the model still follows the
incoming meteo table. The preferred timestep can be used for validation or for
explanation, but it does not silently reschedule the model.

### Using `TimeStepModel` to manage multi-rate coupling

The second example shows the complementary case. Here we explicitly ask one model
to run hourly, even though its source data arrives every 30 minutes. Once we do
that, PlantSimEngine needs instructions for two distinct questions:

- how to combine the 30-minute source output into an hourly model input;
- how to combine 30-minute meteorological rows into the hourly meteo seen by the
  coarse model.

That is what `InputBindings(...)` and `MeteoBindings(...)` are for.
In this tiny example, we keep the mapping simple by declaring the default
reduction policy on the source model itself with `output_policy(...)`. Since `A`
has a unique producer on the same scale, PlantSimEngine can infer the source
automatically and reuse that policy.

Let's define a simple 30-minute source model that produces a constant value `A=1.0` every time it runs, and declare that its output should be integrated when consumed by a slower model:

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
PlantSimEngine.output_policy(::Type{<:TutorialHalfHourSourceModel}) = (; A=Integrate(DurationSumReducer()))
```

Note that `output_policy(...)` says that when a slower model consumes `A`, the default is to integrate it over the coarser time window, using the duration of each source row as weights.

Now we define a simple hourly model that consumes `A` and also reads hourly mean temperature from the meteo:

```@example multirate_timestep_flow
PlantSimEngine.@process "tutorialhourlyintegrator" verbose=false
struct TutorialHourlyIntegratorModel <: AbstractTutorialhourlyintegratorModel end
PlantSimEngine.inputs_(::TutorialHourlyIntegratorModel) = (A=-Inf,)
PlantSimEngine.outputs_(::TutorialHourlyIntegratorModel) = (A_hourly=-Inf, T_hourly=-Inf,)
function PlantSimEngine.run!(::TutorialHourlyIntegratorModel, models, status, meteo, constants=nothing, extra=nothing)
    status.A_hourly = status.A
    status.T_hourly = meteo.T
end
```

!!! note
    We make two deliberate simplifications here to keep the example compact:
    1. The hourly model simply copies the integrated `A` value into a new variable called `A_hourly`. This is bad design in a real model because it creates unnecessary variables and makes the data flow less transparent. In a real model, you would typically consume `A` directly and let the integrated value be called `A` as well. However, here we create a separate variable to make it obvious that the hourly model is receiving an aggregated version of the original `A`.
    2. We don't define an `output_policy(...)` for the hourly model, because it is not consumed by any slower model. Usually, developers are encouraged to define `output_policy(...)` for all models, but here we omit it for the hourly model to keep the example compact.

Now we can declare a mapping that says the hourly model runs every hour, even though its source data arrives every 30 minutes. We also declare how to reduce the meteorological inputs to match the hourly cadence:

```@example multirate_timestep_flow
mapping_coarse = ModelMapping(
    :Leaf => (
        ModelSpec(TutorialHalfHourSourceModel(Ref(0))),
        ModelSpec(TutorialHourlyIntegratorModel()) |>
        TimeStepModel(Hour(1)) |>
        MeteoBindings(; T=MeanWeighted()),
    ),
)
```

Setting the `TimeStepModel(Hour(1))` forces the second model to run hourly. Since it consumes `A` from the first model, PlantSimEngine looks at the source model's `output_policy(...)` and sees that it should integrate `A` over the hour using the duration of each 30-minute row as weights.

!!! note
    If we had omitted `TimeStepModel(Hour(1))`, the hourly model would have simply run on each 30-minute row, and the `output_policy(...)` on the source model would not have been triggered. The hourly model would have received the original 30-minute `A` values instead of an hourly aggregate. This illustrates the key point: `TimeStepModel(...)` is what triggers the multi-rate coupling and the use of reduction policies.

In our example, the hourly model does not declare a `timestep_hint`, so it can run at any cadence. By declaring `TimeStepModel(Hour(1))`, we explicitly force it to run hourly, which means it will receive aggregated inputs and meteo.

!!! note
    Because our hourly model does not declare a `timestep_hint`, it is flexible and can run at any cadence. However, if we had declared a `timestep_hint` that did not include hourly as an acceptable cadence, then PlantSimEngine would have raised an error when we tried to force it to run hourly. Consequently, it is usually a good practice to declare a `timestep_hint` when writing a model, because it helps to ensure that the model is used in a way that is consistent with its design and intended use.

Let's now run the simulation:

```@example multirate_timestep_flow
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
out_coarse_df[:Leaf][end]
```

The final timestep outputs are `3600.0` for `A_hourly` and `23.0` for `T_hourly`: hourly integrated assimilation
(`sum(A .* duration_seconds)` over two 30-minute rows) and hourly mean temperature over the coarse window.

So this example already captures the core multi-rate idea: the fast model still
runs at the fine cadence, while the coarse model sees explicitly reduced inputs
and meteorology at its own cadence.

## 1. Setup and example data

We now move to a slightly more complete tutorial example. To keep the mechanics
readable, we work with a minimal MTG containing only one plant and one leaf. That
way the exported tables stay small enough to inspect directly.

We also reuse package example assets instead of inventing new input files.

We reuse one package example asset:
- `examples/meteo_day.csv` for weather.

We start by importing the packages we need and by creating a very small MTG with
only four nodes: a `Scene`, a `Plant`, one `Internode`, and one `Leaf`.

```@example multirate_tutorial
using PlantSimEngine
using PlantMeteo
using MultiScaleTreeGraph
using DataFrames
using CSV
using Dates

# Minimal plant: Scene -> Plant -> Internode -> Leaf
mtg = Node(NodeMTG("/", :Scene, 1, 0))
plant = Node(mtg, NodeMTG("+", :Plant, 1, 1))
internode = Node(plant, NodeMTG("/", :Internode, 1, 2))
Node(internode, NodeMTG("+", :Leaf, 1, 2))
```

Next, we point to the bundled weather file and confirm that it exists:

```@example multirate_tutorial
meteo_path = joinpath(pkgdir(PlantSimEngine), "examples", "meteo_day.csv")
@assert isfile(meteo_path)
```

The weather file bundled with the package is daily. Since this tutorial is about
mixing several cadences, we first convert one week of daily weather into an
hourly weather table. The values are simply repeated within each day, which is
perfectly fine here because the purpose is to illustrate scheduling and data flow
rather than to create a realistic forcing dataset.

The first step is to read the file and keep only one week of rows:

```@example multirate_tutorial
daily_df = CSV.read(meteo_path, DataFrame, header=18)
week_df = first(daily_df, 7)
```

We then expand each day into 24 hourly `Atmosphere` rows:

```@example multirate_tutorial
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
```

Finally, we wrap those rows into a `Weather` object, which is what `run!` expects:

```@example multirate_tutorial
meteo_hourly = Weather(hourly_rows)
meteo_hourly[1:3] # show the first 3 rows of the hourly weather table
```

## 2. Define simple tutorial models

Next we define three deliberately simple models:

- an hourly `Leaf` model that turns incoming radiation into an hourly
  assimilation value;
- a daily `Plant` model that sums hourly leaf assimilation over a day and also
  consumes daily meteorological aggregates;
- a weekly `Plant` model that sums daily plant assimilation into one weekly
  value.

These models are intentionally minimal. Their role is to make the rate changes
and aggregation policies obvious.

We begin with the hourly leaf model. It reads hourly meteorological radiation and
produces an hourly assimilation value:

```@example multirate_tutorial
PlantSimEngine.@process "tutorialleafhourly" verbose=false
struct TutorialLeafHourlyModel <: AbstractTutorialleafhourlyModel end
PlantSimEngine.inputs_(::TutorialLeafHourlyModel) = NamedTuple()
PlantSimEngine.outputs_(::TutorialLeafHourlyModel) = (leaf_assim_h=0.0,)
function PlantSimEngine.run!(::TutorialLeafHourlyModel, models, status, meteo, constants=nothing, extra=nothing)
    status.leaf_assim_h = 0.004 * meteo.Ri_PAR_f
end
PlantSimEngine.output_policy(::Type{<:TutorialLeafHourlyModel}) = (; leaf_assim_h=Integrate())
```

The `output_policy(...)` declaration matters for multi-rate use: it says that
when a slower model consumes `leaf_assim_h`, the natural default is to integrate
it over the coarser time window.

Now we define the daily plant model. It receives leaf assimilation values,
aggregates them over a day, and also reads daily reduced meteo variables:

```@example multirate_tutorial
PlantSimEngine.@process "tutorialplantdaily" verbose=false
struct TutorialPlantDailyModel <: AbstractTutorialplantdailyModel end
PlantSimEngine.inputs_(::TutorialPlantDailyModel) = (leaf_assim_h=[0.0],)
PlantSimEngine.outputs_(::TutorialPlantDailyModel) = (plant_assim_d=0.0, rad_sw_day=0.0, T=0.0)
function PlantSimEngine.run!(::TutorialPlantDailyModel, models, status, meteo, constants=nothing, extra=nothing)
    status.plant_assim_d = sum(status.leaf_assim_h)
    status.rad_sw_day = meteo.Ri_SW_q
    status.T = meteo.T
end
PlantSimEngine.output_policy(::Type{<:TutorialPlantDailyModel}) = (; plant_assim_d=Integrate())
```

Again, `output_policy(...)` is used so that a coarser consumer can infer the
appropriate default behavior for `plant_assim_d`.

Finally, we define the weekly plant model. It simply sums the daily plant
assimilation values over one week:

```@example multirate_tutorial
PlantSimEngine.@process "tutorialplantweekly" verbose=false
struct TutorialPlantWeeklyModel <: AbstractTutorialplantweeklyModel end
PlantSimEngine.inputs_(::TutorialPlantWeeklyModel) = (plant_assim_d=[0.0],)
PlantSimEngine.outputs_(::TutorialPlantWeeklyModel) = (plant_assim_w=0.0,)
function PlantSimEngine.run!(::TutorialPlantWeeklyModel, models, status, meteo, constants=nothing, extra=nothing)
    status.plant_assim_w = sum(status.plant_assim_d)
end
```

At this point nothing is multi-rate yet. We have simply defined three processes
whose intended cadences are hourly, daily, and weekly. The multi-rate behavior is
declared in the mapping.

## 3. Configure multi-rate mapping

This is the heart of the tutorial. The mapping below does three things at once:

1. it assigns each model to a scale;
2. it declares the timestep at which each model should run;
3. it defines how values move between rates and between scales.

Two pieces are especially important here:

- `TimeStepModel(...)` states the model cadence;
- `MeteoBindings(...)` explains how to reduce meteorological inputs to match a
  coarser model.

For model-to-model bindings, this tutorial relies on automatic source inference
plus `output_policy(...)` on the source models. That keeps the main example
compact while still exercising multi-rate input aggregation.

We start by defining the three clocks used in the simulation:

```@example multirate_tutorial
hourly = 1.0
daily = ClockSpec(24.0, 0.0)
weekly = ClockSpec(168.0, 0.0)
```

The leaf model is straightforward: it runs hourly and is scoped to the current
plant:

```@example multirate_tutorial
leaf_spec = ModelSpec(TutorialLeafHourlyModel()) |>
    TimeStepModel(hourly) |>
    ScopeModel(:plant)
```

The daily plant model is where multi-rate coupling becomes visible. It:

- receives `leaf_assim_h` from the `:Leaf` scale through `MultiScaleModel(...)`;
- runs daily;
- receives reduced meteorological variables through `MeteoBindings(...)`.

```@example multirate_tutorial
plant_daily_spec = ModelSpec(TutorialPlantDailyModel()) |>
    ScopeModel(:plant) |>
    MultiScaleModel([:leaf_assim_h => :Leaf]) |>
    TimeStepModel(daily) |>
    MeteoBindings(
        ;
        T=MeanWeighted(),
        Rh=MeanWeighted(),
        Ri_SW_q=(source=:Ri_SW_f, reducer=RadiationEnergy()),
    )
```

The weekly plant model is simpler again: it only needs to run weekly and receive
the daily plant output automatically:

```@example multirate_tutorial
plant_weekly_spec = ModelSpec(TutorialPlantWeeklyModel()) |>
    ScopeModel(:plant) |>
    TimeStepModel(weekly)
```

We can now assemble the full mapping:

```@example multirate_tutorial
mapping = ModelMapping(
    :Leaf => (leaf_spec,),
    :Plant => (plant_daily_spec, plant_weekly_spec),
)
```

Reading this mapping from top to bottom:

- the `Leaf` model runs hourly and produces `leaf_assim_h`;
- the daily `Plant` model receives leaf values from the `Leaf` scale through
  `MultiScaleModel([:leaf_assim_h => :Leaf])`, then integrates them over a day;
- that same daily model also receives daily meteorological summaries via
  `MeteoBindings(...)`;
- the weekly `Plant` model integrates the daily plant output into one weekly
  value.

`ScopeModel(:plant)` is included so these models belong to the same scoped plant
instance. In a larger scene with several plants, scopes let you keep multi-rate
model instances separated in a controlled way.

!!! note
    In this tutorial, explicit `InputBindings(...)` are omitted because each
    input has a unique, inferable producer and the default reduction policy is
    declared on the source model with `output_policy(...)`.

    In more complex mappings, you should use explicit
    `InputBindings(process=..., scale=..., var=..., policy=...)` when:
    - several models can produce the same input variable;
    - the same process exists at several reachable scales;
    - the source variable has a different name than the consumer input;
    - you want to override the producer's default policy for a specific mapping.

## 4. Run and export hourly/daily/weekly series

Now we run the simulation and request three exported series. This is a good place
to distinguish two related outputs returned by `run!`:

- the regular simulation outputs (`out_status` below), which still contain the
  model outputs tracked during the run;
- the explicitly requested exported series (`exported` below), which are the
  clean hourly/daily/weekly tables we asked PlantSimEngine to materialize.

We use `OutputRequest(...)` to say which variable we want and on which clock.
Here again we keep the example minimal: `process=` is omitted because each
requested output has a unique canonical publisher.

We first declare the export requests. One request keeps the hourly leaf series,
another exports the daily plant series, and the last one exports the weekly plant
series:

```@example multirate_tutorial
req_leaf_hourly = OutputRequest(:Leaf, :leaf_assim_h;
    name=:leaf_assim_hourly,
)

req_plant_daily = OutputRequest(:Plant, :plant_assim_d;
    name=:plant_assim_daily,
    clock=daily,
)

req_plant_weekly = OutputRequest(:Plant, :plant_assim_w;
    name=:plant_assim_weekly,
    clock=weekly,
)
```

Then we run the simulation and ask PlantSimEngine to return both the regular
simulation outputs and the explicitly requested exported series:

```@example multirate_tutorial
out_status, exported = run!(
    mtg,
    mapping,
    meteo_hourly;
    executor=SequentialEx(),
    tracked_outputs=[req_leaf_hourly, req_plant_daily, req_plant_weekly],
    return_requested_outputs=true,
)
```

Finally, we extract the exported tables we want to inspect:

```@example multirate_tutorial
leaf_hourly_df = exported[:leaf_assim_hourly]
plant_daily_df = exported[:plant_assim_daily]
plant_weekly_df = exported[:plant_assim_weekly]
```

The exported tables already have the cadence we asked for, so they are much
easier to inspect than a single mixed output table.

We can start with a few basic checks on the number of rows:

```@example multirate_tutorial
@show nrow(leaf_hourly_df)    # 168 (1 leaf x 168 hours)
@show nrow(plant_daily_df)    # 7   (1 plant x 7 days)
@show nrow(plant_weekly_df)   # 1   (1 plant x 1 week)
```

To compare the hourly and daily outputs directly, we group the hourly series by
day and sum it manually:

```@example multirate_tutorial
leaf_hourly_df.day = repeat(1:7, inner=24)
leaf_hourly_sum = combine(groupby(leaf_hourly_df, :day), :value => sum => :leaf_assim_h_sum)
```

Those row counts match the intended design of the example: one hourly series for
seven days, one daily series for seven days, and one weekly aggregate for the
whole run.

We can also manually recompute the daily sums from the hourly exported series and
compare them with the daily model output:

```@example multirate_tutorial
plant_daily_df
```

This confirms that the daily assimilation really is the sum of the hourly leaf
assimilation collected over each day.

The regular outputs returned by `run!` are still available as well, and can be
converted to `DataFrame`s in the usual way:

```@example multirate_tutorial
outs = convert_outputs(out_status, DataFrame)
outs[:Plant][1:3,:]
```

## 5. Deeper notes

The example above is enough to run a complete multi-rate simulation. The notes
below highlight a few practical extensions that become important in more serious
models.

### Calendar-aligned windows

So far, the tutorial used fixed-duration windows. Sometimes you want the daily or
weekly model to align to the civil calendar instead, for example "the current
day" rather than "the trailing last 24 hours". In that case, use a
`MeteoWindow(...)`:

If your daily model must use the current civil day (instead of trailing 24h), use:

```@example multirate_tutorial
ModelSpec(TutorialPlantDailyModel()) |>
TimeStepModel(daily) |>
MeteoWindow(CalendarWindow(:day; anchor=:current_period, week_start=1, completeness=:strict))
```

Likewise, use `:week` or `:month` for weekly/monthly calendar windows.

### Shared reducers

The same reducer concepts appear in two places:

- `InputBindings(...)` for model-to-model transfers across different cadences;
- `MeteoBindings(...)` for meteorological aggregation.

That symmetry is deliberate. Once you understand how a reducer summarizes a fast
series into a slower one, the same reasoning applies whether the source is a
model output or a meteorological variable.

Reducer objects work for model inputs and meteo bindings:

- `InputBindings(..., policy=Integrate(...)/Aggregate(...))`,
- `MeteoBindings(..., reducer=...)`.
- For duration-aware accumulation (for example flux to amount), use
  `Integrate(DurationSumReducer())` or an equivalent two-argument callable
  `Integrate((values, durations_seconds) -> sum(values .* durations_seconds))`.

### Inspect resolved specs

When a mapping becomes more complex, it is useful to inspect the fully resolved
multi-rate configuration rather than relying on memory. `explain_model_specs(...)`
prints the effective timestep, input bindings, meteo bindings, and meteo window
for each model process:

```@example multirate_tutorial
explain_model_specs(mapping)
```

This is often the fastest way to debug a mapping when a model seems to run at the
wrong cadence or receives the wrong aggregation policy.

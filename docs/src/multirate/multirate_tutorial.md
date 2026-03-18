# Step-by-step multi-rate tutorial (hourly + daily + weekly)

This page builds a more complete MTG simulation that mixes three model rates:
- hourly at `Leaf`,
- daily at `Plant`,
- weekly at `Plant`.

It runs for one week and exports clean series at each rate.

If you want the conceptual overview first, start with
[Introduction to multi-rate execution](introduction.md). This page assumes you
already understand the two basic ideas introduced there:

1. without `TimeStepModel(...)`, a model follows the meteo cadence;
2. once a model is forced to run more coarsely than its inputs, PlantSimEngine
   must reduce both model outputs and meteorological inputs to match that slower
   cadence.

The goal of this second page is to put those ideas into a more contextualized
MTG example, where we mix hourly, daily, and weekly models in the same
simulation and export clean time series at each rate.

## 1. Setup and example data

This tutorial is more contextualized than the previous one. To keep the mechanics
readable, we work with a minimal MTG containing only one plant and one leaf. That
way the exported tables stay small enough to inspect directly.

We also reuse package example assets instead of inventing new input files. In particular, we use a weather file available from the package examples:

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
mixing several rates, we first convert one week of daily weather into an
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

## 2. Defining simple models

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
- PlantMeteo reduces meteorological inputs automatically when a model runs more
  coarsely than the weather data.

For model-to-model bindings, this tutorial relies on automatic source inference
plus `output_policy(...)` on the source models. That keeps the main example
compact while still exercising multi-rate input aggregation.

We start by defining the three clocks used in the simulation. These are the
cadences that will later be assigned to the three models:

```@example multirate_tutorial
hourly = 1.0
daily = ClockSpec(24.0, 0.0)
weekly = ClockSpec(168.0, 0.0)
```

The leaf model is straightforward: it runs hourly and is scoped to the current
plant. There is no multiscale mapping or meteo reduction to declare here, because
the leaf model is the fastest model in this example and directly consumes the
hourly weather rows:

```@example multirate_tutorial
leaf_spec = TutorialLeafHourlyModel() |> ModelSpec |> TimeStepModel(hourly)
```

So at this point we have simply said: "run the leaf model every hour"

The daily plant model is where multi-rate coupling becomes visible. It:

- receives `leaf_assim_h` from the `:Leaf` scale through `MultiScaleModel(...)`;
- runs daily;
- receives daily meteorological aggregates from the hourly weather automatically.

The important idea is that this model does not read the raw hourly values
directly. Instead, it sees a daily view of those data:

- `leaf_assim_h` is integrated over the daily window because of the source
  model's `output_policy(...)`;
- `T` is turned into a daily mean by the default PlantMeteo sampling rules;
- `Ri_SW_q` is computed by integrating `Ri_SW_f` over the day.

```@example multirate_tutorial
plant_daily_spec = 
    TutorialPlantDailyModel() |> 
    ModelSpec |>
    MultiScaleModel([:leaf_assim_h => :Leaf]) |>
    TimeStepModel(daily)
```

This block is the first place where the "multi-rate" behavior is really visible:
one model consumes fine-grained biological outputs and fine-grained meteorology,
but only after both have been reduced to the model's own daily cadence.

The weekly plant model is simpler again: it only needs to run weekly and receive
the daily plant output automatically. Since `plant_assim_d` has a unique producer
and already declares its own `output_policy(...)`, we do not need to add any
explicit binding here:

```@example multirate_tutorial
plant_weekly_spec = 
    TutorialPlantWeeklyModel() |>
    ModelSpec |>
    TimeStepModel(weekly)
```

So this weekly model effectively says: "take the daily plant assimilation stream,
reduce it again to my weekly cadence, and run once per week."

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
- that same daily model also receives daily meteorological summaries through the
  default PlantMeteo sampling rules;
- the weekly `Plant` model integrates the daily plant output into one weekly
  value.

!!! note
    In this tutorial, explicit `InputBindings(...)` are omitted because each
    input has a unique, inferable producer and the default reduction policy is
    declared on the source model with `output_policy(...)`.

    In more complex mappings, you should use explicit `InputBindings(process=..., scale=..., var=..., policy=...)` when:
    - several models can produce the same input variable;
    - the same process exists at several reachable scales;
    - the source variable has a different name than the consumer input;
    - you want to override the producer's default policy for a specific mapping.

!!! note
    `MeteoBindings(...)` is also omitted on purpose in the main example.
    PlantSimEngine delegates weather sampling to PlantMeteo, which already
    defines default transformations for common `Atmosphere` variables such as
    `T`, `Rh`, and radiation aliases like `Ri_SW_q`.

    Add explicit `MeteoBindings(...)` when:
    - you want a non-default reducer;
    - the model expects a target variable with a different source name;
    - the variable is not covered by PlantMeteo default transforms;
    - you want the mapping to state the weather aggregation rule explicitly.

    ```@example multirate_tutorial
    # The same daily model, with weather aggregation rules written explicitly.
    plant_daily_spec_explicit_meteo = ModelSpec(TutorialPlantDailyModel()) |>
        MultiScaleModel([:leaf_assim_h => :Leaf]) |>
        TimeStepModel(daily) |>
        MeteoBindings(
            ;
            T=MeanWeighted(),
            Ri_SW_q=(source=:Ri_SW_f, reducer=RadiationEnergy()),
        )
    ```

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
series.

The point of these requests is to obtain three clean tables that each live at a
single rate, instead of having to reconstruct those time series manually from
the full simulation outputs:

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

- `out_status` contains the regular tracked outputs of the simulation;
- `exported` contains the resampled, per-request tables defined above.

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

Finally, we extract the exported tables we want to inspect. At this point we are
no longer dealing with abstract stream definitions: we now have actual `DataFrame`
objects containing hourly, daily, and weekly series.

```@example multirate_tutorial
leaf_hourly_df = exported[:leaf_assim_hourly]
plant_daily_df = exported[:plant_assim_daily]
plant_weekly_df = exported[:plant_assim_weekly]
```

The exported tables already have the cadence we asked for, so they are much
easier to inspect than a single mixed output table.

We can start with a few basic checks on the number of rows. These checks are a
simple way to confirm that the export clocks did what we expected:

```@example multirate_tutorial
@show nrow(leaf_hourly_df)    # 168 (1 leaf x 168 hours)
@show nrow(plant_daily_df)    # 7   (1 plant x 7 days)
@show nrow(plant_weekly_df)   # 1   (1 plant x 1 week)
```

The hourly table has one row per hour, the daily table one row per day, and the
weekly table one row for the whole run.

To compare the hourly and daily outputs directly, we group the hourly series by
day and sum it manually. This lets us check that the daily plant model really did
receive the integrated hourly leaf assimilation:

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

This confirms that the daily assimilation values correspond to the sum of the
hourly leaf assimilation collected over each day.

The regular outputs returned by `run!` are still available as well, and can be
converted to `DataFrame`s in the usual way. This is useful when you want both:

- clean resampled exports for analysis;
- the usual simulation outputs for debugging or broader inspection.

```@example multirate_tutorial
outs = convert_outputs(out_status, DataFrame)
outs[:Plant][1:3,:]
```

## 5. Where to go next

This page keeps the main walkthrough focused on a complete but still compact
example. Once that example is clear, the next step is usually to learn the
explicit configuration tools that become useful in larger mappings:

- `InputBindings(...)` when inference is ambiguous or too implicit;
- `MeteoBindings(...)` when PlantMeteo defaults are not enough;
- `MeteoWindow(...)` for calendar-aligned aggregation;
- `OutputRequest(...)` when you want explicit export-time clocks and policies;
- `ScopeModel(...)`, `explain_model_specs(...)`, and `resolved_model_specs(...)`
  for larger and harder-to-debug MTGs.

Those topics are grouped in
[Advanced multi-rate configuration](advanced_configuration.md).

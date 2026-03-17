# Introduction to multi-rate execution

This page introduces the basic ideas behind multi-rate execution in
PlantSimEngine.

The goal here is not to build a realistic plant model. Instead, the objective is
to make the mechanics of multi-rate execution easy to see:

- how PlantSimEngine decides when a model runs;
- how values are transferred from a faster model to a slower one;
- how meteorological inputs are reduced over a coarse time window.

Once those ideas are clear, the
[step-by-step multi-rate tutorial](multirate_tutorial.md) shows how to assemble
a more complete hourly/daily/weekly MTG simulation.

## Decision flow quick examples

Before building a larger example, it helps to establish two important rules:

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
out_coarse[:Leaf][end]
```

The final timestep outputs are `3600.0` for `A_hourly` and `23.0` for `T_hourly`: hourly integrated assimilation
(`sum(A .* duration_seconds)` over two 30-minute rows) and hourly mean temperature over the coarse window.

So this example already captures the core multi-rate idea: the fast model still
runs at the fine cadence, while the coarse model sees explicitly reduced inputs
and meteorology at its own cadence.

From here, there are two natural next steps:

- [Step-by-step multi-rate tutorial](multirate_tutorial.md) for a more complete
  MTG example;
- [Advanced multi-rate configuration](advanced_configuration.md) for explicit
  bindings, meteo windows, export requests, scopes, and debugging helpers.

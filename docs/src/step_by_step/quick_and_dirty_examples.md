# Quick Examples

This page is for copy-paste experimentation with the native composite-model/object API.
If you want a slower explanation of the same ideas, see
[Detailed Walkthrough Of A Simple Simulation](@ref detailed-walkthrough-of-a-simple-simulation).

The examples use one model object, but the same pattern scales to plants,
organs, soil objects, and microclimate grids by adding more `Object`s and
selecting them with `ModelSpec(...; on=...)` and `ModelSpec(...; inputs=...)`.

```@setup quick_model_examples
using PlantSimEngine, PlantMeteo, Dates, DataFrames
using PlantSimEngine.Examples

meteo_day = read_weather(
    joinpath(pkgdir(PlantSimEngine), "examples/meteo_day.csv");
    duration=Dates.Day,
)
```

```@contents
Pages = ["quick_and_dirty_examples.md"]
Depth = 2
```

## One Light Interception Model

```@example quick_model_examples
model = CompositeModel(
    Beer(0.5);
    status=(LAI=2.0,),
    environment=meteo_day,
)

sim = run!(model; steps=3, outputs=:all)
first(collect_outputs(sim), 3)
```

## LAI And Light Interception

Here, `ToyDegreeDaysCumulModel` computes cumulative thermal time, `ToyLAIModel`
computes `LAI`, and `Beer` consumes `LAI`. The compiler infers the same-object
value bindings from model inputs and outputs.

```@example quick_model_examples
lai_scene = CompositeModel(
    ToyDegreeDaysCumulModel(),
    ToyLAIModel(),
    Beer(0.5);
    environment=meteo_day,
)

lai_sim = run!(lai_scene; steps=5, outputs=:all)
first(collect_outputs(lai_sim), 8)
```

Inspect the inferred coupling:

```@example quick_model_examples
select(
    DataFrame(Diagnostics.explain_bindings(lai_scene)),
    :application_id,
    :input,
    :source_application_ids,
    :carrier_kind,
)
```

## Add Biomass Growth

`ToyRUEGrowthModel` consumes absorbed light and accumulates biomass. No extra
input binding is needed because `Beer` is the unique producer of `aPPFD` on the
same object.

```@example quick_model_examples
growth_scene = CompositeModel(
    ToyDegreeDaysCumulModel(),
    ToyLAIModel(),
    Beer(0.5),
    ToyRUEGrowthModel(0.2);
    environment=meteo_day,
)

growth_sim = run!(growth_scene; steps=5)
growth_status = final_state(growth_sim)
(LAI=growth_status.LAI, aPPFD=growth_status.aPPFD, biomass=growth_status.biomass)
```

## Keep Only One Requested Output

For larger simulations, request only the streams you want to keep:

```@example quick_model_examples
request = OutputRequest(
    :Scene,
    :biomass;
    name=:biomass_daily,
    application=:growth,
    policy=HoldLast(),
    clock=Day(1),
)

requested_sim = run!(
    growth_scene;
    steps=5,
    outputs=request,
)

first(collect_outputs(requested_sim, :biomass_daily), 5)
```

## PlantBiophysics

The same composite-model/object API can host models from companion packages such as
PlantBiophysics. A typical PlantBiophysics energy-balance setup uses
`ModelSpec(...; calls=...)` so an iterative parent model can manually run photosynthesis and
stomatal-conductance models, then call `run_call!(target; publish=true)` once
for the accepted solution.

See [MAESPA-style model example handoff](../dev/maespa_model_handoff.md) for
the current multi-plant energy-balance acceptance example.

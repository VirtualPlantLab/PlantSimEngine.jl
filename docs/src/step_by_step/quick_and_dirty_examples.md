# Quick Examples

This page is for copy-paste experimentation with the native scene/object API.
If you want a slower explanation of the same ideas, see
[Detailed Walkthrough Of A Simple Simulation](@ref detailed-walkthrough-of-a-simple-simulation).

The examples use one scene object, but the same pattern scales to plants,
organs, soil objects, and microclimate grids by adding more `Object`s and
selecting them with `AppliesTo(...)` and `Inputs(...)`.

```@setup quick_scene_examples
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

```@example quick_scene_examples
scene = Scene(
    Object(
        :scene;
        scale=:Scene,
        kind=:scene,
        status=Status(LAI=2.0),
    );
    applications=(
        ModelSpec(Beer(0.5); name=:light_interception) |>
            AppliesTo(One(scale=:Scene)) |>
            TimeStep(Day(1)),
    ),
    environment=meteo_day,
)

sim = run!(scene; steps=3, constants=Constants())
first(collect_outputs(sim), 3)
```

## LAI And Light Interception

Here, `ToyDegreeDaysCumulModel` computes cumulative thermal time, `ToyLAIModel`
computes `LAI`, and `Beer` consumes `LAI`. The compiler infers the same-object
value bindings from model inputs and outputs.

```@example quick_scene_examples
lai_scene = Scene(
    Object(:scene; scale=:Scene, kind=:scene, status=Status(TT_cu=0.0));
    applications=(
        ModelSpec(ToyDegreeDaysCumulModel(); name=:degree_days) |>
            AppliesTo(One(scale=:Scene)) |>
            TimeStep(Day(1)),
        ModelSpec(ToyLAIModel(); name=:lai) |>
            AppliesTo(One(scale=:Scene)) |>
            TimeStep(Day(1)),
        ModelSpec(Beer(0.5); name=:light_interception) |>
            AppliesTo(One(scale=:Scene)) |>
            TimeStep(Day(1)),
    ),
    environment=meteo_day,
)

lai_sim = run!(lai_scene; steps=5, constants=Constants())
first(collect_outputs(lai_sim), 8)
```

Inspect the inferred coupling:

```@example quick_scene_examples
select(
    DataFrame(explain_bindings(refresh_bindings!(lai_scene))),
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

```@example quick_scene_examples
growth_scene = Scene(
    Object(:scene; scale=:Scene, kind=:scene, status=Status(TT_cu=0.0));
    applications=(
        ModelSpec(ToyDegreeDaysCumulModel(); name=:degree_days) |>
            AppliesTo(One(scale=:Scene)) |>
            TimeStep(Day(1)),
        ModelSpec(ToyLAIModel(); name=:lai) |>
            AppliesTo(One(scale=:Scene)) |>
            TimeStep(Day(1)),
        ModelSpec(Beer(0.5); name=:light_interception) |>
            AppliesTo(One(scale=:Scene)) |>
            TimeStep(Day(1)),
        ModelSpec(ToyRUEGrowthModel(0.2); name=:growth) |>
            AppliesTo(One(scale=:Scene)) |>
            TimeStep(Day(1)),
    ),
    environment=meteo_day,
)

growth_sim = run!(growth_scene; steps=5, constants=Constants())
growth_status = only(scene_objects(growth_scene; scale=:Scene)).status
(LAI=growth_status.LAI, aPPFD=growth_status.aPPFD, biomass=growth_status.biomass)
```

## Keep Only One Requested Output

For larger simulations, request only the streams you want to keep:

```@example quick_scene_examples
request = OutputRequest(
    :Scene,
    :biomass;
    name=:biomass_daily,
    process=:growth,
    policy=HoldLast(),
    clock=Day(1),
)

requested_sim = run!(
    growth_scene;
    steps=5,
    constants=Constants(),
    tracked_outputs=request,
)

first(collect_outputs(requested_sim, :biomass_daily), 5)
```

## PlantBiophysics

The same scene/object API can host models from companion packages such as
PlantBiophysics. A typical PlantBiophysics energy-balance setup uses
`Calls(...)` so an iterative parent model can manually run photosynthesis and
stomatal-conductance models, then call `run_call!(target; publish=true)` once
for the accepted solution.

See [MAESPA-style scene example handoff](../dev/maespa_scene_handoff.md) for
the current multi-plant energy-balance acceptance example.

## Migration Note

The previous mapping runtime has been removed. Simulations start from `Scene`,
`Object`, `ModelSpec`, `AppliesTo`, `Inputs`, `Calls`, `Updates`, `TimeStep`,
and `Environment`.

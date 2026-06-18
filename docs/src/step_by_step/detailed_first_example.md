# [Detailed Walkthrough Of A Simple Simulation](@id detailed-walkthrough-of-a-simple-simulation)

This page walks through a small scene/object simulation. It is written for
readers who are still getting comfortable with Julia and PlantSimEngine.

If you only want examples to copy and modify, see [Quick examples](quick_and_dirty_examples.md). For
multi-object and multi-plant simulations, the same API scales up: add objects,
select them with `AppliesTo(...)`, connect values with `Inputs(...)`, and use
`Calls(...)` when a parent model must manually run child models.

```@setup detailed_scene
using PlantSimEngine, PlantMeteo, Dates, DataFrames
using PlantSimEngine.Examples

meteo_day = read_weather(
    joinpath(pkgdir(PlantSimEngine), "examples/meteo_day.csv");
    duration=Dates.Day,
)
```

```@contents
Pages = ["detailed_first_example.md"]
Depth = 3
```

## Setting Up Your Environment

Every script needs a Julia environment with PlantSimEngine installed. Most
examples also use companion packages such as PlantMeteo for weather data and
DataFrames for tabular outputs. Installation details are in
[Installing PlantSimEngine](../prerequisites/installing_plantsimengine.md).

## The Simulation Pieces

### Processes And Models

A process is something you want to simulate, such as light interception,
photosynthesis, water flux, growth, yield, or energy balance.

A model is one implementation of a process. In this page we use the example
`Beer` model, which implements a Beer-Lambert light-interception equation.
Its only parameter is the extinction coefficient `k`.

```@example detailed_scene
fieldnames(Beer)
```

The model implementation declares the status variables it reads and writes:

```@example detailed_scene
inputs(Beer(0.5))
```

```@example detailed_scene
outputs(Beer(0.5))
```

These declarations are the modeler's contract. The scene/object layer decides
where the model runs and where those values come from.

### Scene Objects

A `Scene` contains simulated `Object`s. An object can represent a scene, plant,
axis, leaf, soil layer, sensor, voxel, or any other simulated entity.

For a first example, we use one object representing the whole scene. The `Beer`
model reads `LAI`, so we initialize that variable on the object status.

```@example detailed_scene
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
```

`ModelSpec(...)` wraps a reusable model kernel with scenario-level decisions:

- `name=:light_interception` gives the application a stable name;
- `AppliesTo(One(scale=:Scene))` says it runs on the scene object;
- `TimeStep(Day(1))` says it runs daily;
- `environment=meteo_day` supplies weather values such as radiation.

## Inspecting The Compiled Scene

Before runtime, PlantSimEngine resolves selectors and builds a compiled scene.
This avoids resolving object selections inside the timestep loop.

```@example detailed_scene
compiled = refresh_bindings!(scene)
select(
    DataFrame(explain_scene_applications(compiled)),
    :application_id,
    :process,
    :target_ids,
)
```

`Beer` has no model-to-model value input in this first scene because `LAI` was
initialized directly on the object status:

```@example detailed_scene
explain_bindings(compiled)
```

The schedule tells us when each application runs:

```@example detailed_scene
select(
    DataFrame(explain_schedule(compiled)),
    :application_id,
    :dt_seconds,
    :root_scheduled,
    :manual_call_only,
)
```

## Running The Simulation

Run the scene with [`run!`](@ref):

```@example detailed_scene
sim = run!(scene; steps=3, constants=Constants())
```

The object status stores the latest value:

```@example detailed_scene
scene_status = only(scene_objects(scene; scale=:Scene)).status
(LAI=scene_status.LAI, aPPFD=scene_status.aPPFD)
```

The returned `SceneSimulation` stores retained output streams:

```@example detailed_scene
first(collect_outputs(sim; sink=nothing), 3)
```

For a table, use the default `DataFrame` sink:

```@example detailed_scene
first(collect_outputs(sim), 3)
```

## Adding A Model Coupling

Now let a daily LAI model compute `LAI` before the light-interception model
runs. `ToyLAIModel` reads cumulative thermal time `TT_cu` and writes `LAI`.
Because `Beer` reads `LAI`, the compiler can infer the same-object binding.

```@example detailed_scene
coupled_scene = Scene(
    Object(
        :scene;
        scale=:Scene,
        kind=:scene,
        status=Status(TT_cu=0.0),
    );
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

select(
    DataFrame(explain_bindings(refresh_bindings!(coupled_scene))),
    :application_id,
    :input,
    :source_application_ids,
    :carrier_kind,
    :copy_semantics,
)
```

The `LAI` binding uses a live reference carrier, so the light-interception
model sees the value written by the LAI model without copying it.

Run the coupled scene:

```@example detailed_scene
coupled_sim = run!(coupled_scene; steps=5, constants=Constants())
first(collect_outputs(coupled_sim), 8)
```

The final object status contains the latest values from the coupled models:

```@example detailed_scene
coupled_status = only(scene_objects(coupled_scene; scale=:Scene)).status
(TT_cu=coupled_status.TT_cu, LAI=coupled_status.LAI, aPPFD=coupled_status.aPPFD)
```

## What Needs Initialization?

Model `inputs_(...)` lists every variable a model may need, but not all of
those variables need user initialization. In a coupled scene, some inputs are
computed by upstream models.

Use the compiler explanations to distinguish the two cases:

- a variable already present on object `Status` is user-provided state;
- a row in `explain_bindings(...)` is compiler-owned coupling;
- a compile error means a required input is neither initialized nor bound.

For example, if we remove `TT_cu` from the scene status, compilation fails
because no model in this scene computes it before `ToyLAIModel` reads it:

```@example detailed_scene
bad_scene = Scene(
    Object(:scene; scale=:Scene, kind=:scene);
    applications=(
        ModelSpec(ToyLAIModel(); name=:lai) |>
            AppliesTo(One(scale=:Scene)),
    ),
    environment=meteo_day,
)

try
    refresh_bindings!(bad_scene)
catch err
    first(sprint(showerror, err), 300)
end
```

## Migration Note

The previous mapping runtime has been removed. Simulations use `Scene`,
`Object`, `ModelSpec`, `AppliesTo`, `Inputs`, `Calls`, `Updates`, `TimeStep`,
and `Environment`.

See [Migrating To The Scene/Object API](../migration_scene_object.md) for the
translation from the historical mapping API.

## Next Steps

- [Standard model coupling](@ref) shows more coupling patterns.
- [Scene/Object Quickstart](../scene_object/quickstart.md) is the shortest
  copy-pasteable path for the new API.
- [Model execution](../model_execution.md) explains scheduling, temporal inputs, hard calls,
  output retention, and lifecycle refreshes.

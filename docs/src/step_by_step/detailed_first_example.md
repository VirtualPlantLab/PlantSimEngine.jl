# [Detailed Walkthrough Of A Simple Simulation](@id detailed-walkthrough-of-a-simple-simulation)

This page walks through a small composite-model/object simulation. It is written for
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

These declarations are the modeler's contract. The composite-model/object layer decides
where the model runs and where those values come from.

### CompositeModel Objects

A `CompositeModel` contains simulated `Object`s. An object can represent a model, plant,
axis, leaf, soil layer, sensor, voxel, or any other simulated entity.

For a first example, we use one object representing the whole model. The `Beer`
model reads `LAI`, so we initialize that variable on the object status.

```@example detailed_scene
model = CompositeModel(
    Beer(0.5);
    status=(LAI=2.0,),
    environment=meteo_day,
    timestep=Day(1),
)
```

The concise constructor creates one ordinary model object and one application
for each supplied model. `status` initializes that object, `timestep` applies a
common daily cadence, and `environment` supplies weather values such as
radiation. Use explicit `ModelSpec` and selectors when applications need
different policies or targets.

## Inspecting The Compiled CompositeModel

Before runtime, PlantSimEngine resolves selectors and builds a compiled model.
This avoids resolving object selections inside the timestep loop.

```@example detailed_scene
select(
    DataFrame(explain_applications(model)),
    :application_id,
    :process,
    :target_ids,
)
```

`Beer` has no model-to-model value input in this first model because `LAI` was
initialized directly on the object status:

```@example detailed_scene
explain_bindings(model)
```

The schedule tells us when each application runs:

```@example detailed_scene
select(
    DataFrame(explain_schedule(model)),
    :application_id,
    :dt_seconds,
    :root_scheduled,
    :manual_call_only,
)
```

## Running The Simulation

Run the model with [`run!`](@ref):

```@example detailed_scene
sim = run!(model; steps=3)
```

The object status stores the latest value:

```@example detailed_scene
scene_status = only(model_objects(model; scale=:Scene)).status
(LAI=scene_status.LAI, aPPFD=scene_status.aPPFD)
```

The returned `Simulation` stores retained output streams:

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
coupled_scene = CompositeModel(
    ToyDegreeDaysCumulModel(),
    ToyLAIModel(),
    Beer(0.5);
    status=(TT_cu=0.0,),
    environment=meteo_day,
    timestep=Day(1),
)

select(
    DataFrame(explain_bindings(coupled_scene)),
    :application_id,
    :input,
    :source_application_ids,
    :carrier_kind,
    :copy_semantics,
)
```

The `LAI` binding uses a live reference carrier, so the light-interception
model sees the value written by the LAI model without copying it.

Run the coupled model:

```@example detailed_scene
coupled_sim = run!(coupled_scene; steps=5, outputs=:all)
first(collect_outputs(coupled_sim), 8)
```

The final object status contains the latest values from the coupled models:

```@example detailed_scene
coupled_status = only(model_objects(coupled_scene; scale=:Scene)).status
(TT_cu=coupled_status.TT_cu, LAI=coupled_status.LAI, aPPFD=coupled_status.aPPFD)
```

## What Needs Initialization?

Model `inputs_(...)` lists every variable a model may need, but not all of
those variables need user initialization. In a coupled model, some inputs are
computed by upstream models.

Use the compiler explanations to distinguish the two cases:

- a variable already present on object `Status` is user-provided state;
- a row in `explain_bindings(...)` is compiler-owned coupling;
- a compile error means a required input is neither initialized nor bound.

For example, if we remove `TT_cu` from the model status, compilation fails
because no model in this model computes it before `ToyLAIModel` reads it:

```@example detailed_scene
bad_scene = CompositeModel(
    ToyLAIModel();
    environment=meteo_day,
)

try
    explain_bindings(bad_scene)
catch err
    first(sprint(showerror, err), 300)
end
```

## Migration Note

The previous mapping runtime has been removed. Simulations use `CompositeModel`,
`Object`, `ModelSpec`, `AppliesTo`, `Inputs`, `Calls`, `Updates`, `TimeStep`,
and `Environment`.

See [Migrating To The CompositeModel/Object API](../migration_composite_model.md) for the
translation from the historical mapping API.

## Next Steps

- [Standard model coupling](@ref) shows more coupling patterns.
- [CompositeModel/Object Quickstart](../composite_model/quickstart.md) is the shortest
  copy-pasteable path for the new API.
- [Model execution](../model_execution.md) explains scheduling, temporal inputs, hard calls,
  output retention, and lifecycle refreshes.

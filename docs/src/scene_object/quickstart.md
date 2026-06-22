# Scene/Object Quickstart

This page is the shortest path to a native scene/object simulation.

Use this API for new multiscale, multi-plant, soil, microclimate, and
scene-scale simulations:

```julia
Scene
Object
ModelSpec
AppliesTo
Inputs
Calls
Updates
TimeStep
Environment
```

Scenarios are defined with `Scene` and model applications. A model is a
reusable process implementation; an application is one configured use of that
model, including its name, target objects, inputs, cadence, and environment.
One application may run on many objects, and the same model may appear in
several applications with different parameters or targets.

```@setup scene_object_quickstart
using PlantSimEngine, PlantMeteo, Dates, DataFrames
using PlantSimEngine.Examples
```

## One Object, Several Models

For models that all run on one object, the concise constructor lowers directly
to the ordinary Scene/Object representation:

```julia
scene = Scene(ModelA(), ModelB(); status=(initial_value=1.0,))
```

Use the explicit form later in this guide when applications need names,
selectors, or other scenario policies.

The first scene has one object, `:scene`, and three model applications:

- `ToyDegreeDaysCumulModel` computes daily thermal time;
- `ToyLAIModel` consumes cumulative thermal time and computes LAI;
- `Beer` consumes LAI and meteorology to compute absorbed PAR.

The model implementations are ordinary PlantSimEngine kernels. The scene
application layer decides where they run. With no explicit `TimeStep`, these
applications use the environment cadence.

```@example scene_object_quickstart
meteo_day = read_weather(
    joinpath(pkgdir(PlantSimEngine), "examples/meteo_day.csv");
    duration=Dates.Day,
)

scene = Scene(
    ToyDegreeDaysCumulModel(),
    ToyLAIModel(),
    Beer(0.6);
    environment=meteo_day,
)

sim = run!(scene; steps=30, outputs=:all)
out = collect_outputs(sim; sink=DataFrame)
first(out, 6)
```

The scene object now holds the latest status values:

```@example scene_object_quickstart
scene_status = only(scene_objects(scene; scale=:Scene)).status
(TT_cu=scene_status.TT_cu, LAI=scene_status.LAI, aPPFD=scene_status.aPPFD)
```

## Inspect The Compiled Bindings

Before running, `explain_initialization(scene)` classifies each variable as
`:supplied`, `:generated`, `:producer_bound`, `:environment_bound`, or
`:unresolved`. The report remains available when ordinary required values are
missing, so it can be used to finish configuring a scene.

The compiler infers unambiguous same-object dependencies from declared model
inputs and outputs:

- `:LAI_Dynamic` reads `TT_cu` from `:Degreedays`;
- `:light_interception` reads `LAI` from `:LAI_Dynamic`.

```@example scene_object_quickstart
select(
    DataFrame(explain_bindings(scene)),
    :application_id,
    :input,
    :source_application_ids,
    :carrier_kind,
    :copy_semantics,
)
```

`carrier_kind = :ref` and `copy_semantics = :live_references` mean the
consumer sees a shared reference rather than a copied value.

For runtime performance diagnostics, inspect the execution plan:

```@example scene_object_quickstart
select(
    DataFrame(explain_execution_plan(scene)),
    :application_id,
    :object_ids,
    :batch_size,
    :inner_loop_dispatch,
)
```

## Request Outputs

By default, scene runs retain no user output streams. Pass `outputs=:all` to
retain every publisher, or pass `OutputRequest` values to retain and
materialize selected streams plus those required by temporal inputs.

```@example scene_object_quickstart
request = OutputRequest(
    Many(scale=:Scene),
    :LAI;
    name=:lai_every_two_days,
    application=:LAI_Dynamic,
    policy=HoldLast(),
    clock=Day(2),
)

requested_sim = run!(
    scene;
    steps=30,
    outputs=request,
)

collect_outputs(requested_sim, :lai_every_two_days; sink=nothing)[1:4]
```

The retention explanation reports why a stream was kept:

```@example scene_object_quickstart
explain_output_retention(requested_sim)
```

## Many Objects As Inputs

Use `Inputs(...)` when a model needs values from selected objects. This
scene-scale LAI model reads live references to the surface of every plant:

```@example scene_object_quickstart
plant_scene = Scene(
    Object(:scene; scale=:Scene, kind=:scene),
    Object(
        :plant_1;
        scale=:Plant,
        kind=:plant,
        parent=:scene,
        status=Status(surface=12.0),
    ),
    Object(
        :plant_2;
        scale=:Plant,
        kind=:plant,
        parent=:scene,
        status=Status(surface=8.0),
    );
    applications=(
        ModelSpec(ToyLAIfromLeafAreaModel(100.0); name=:scene_lai) |>
            AppliesTo(One(scale=:Scene)) |>
            Inputs(
                :plant_surfaces => Many(
                    scale=:Plant,
                    within=SceneScope(),
                    var=:surface,
                ),
            ),
    ),
)

run!(plant_scene)
plant_scene_status = only(scene_objects(plant_scene; scale=:Scene)).status
(total_surface=plant_scene_status.total_surface, LAI=plant_scene_status.LAI)
```

The compiled binding shows a `RefVector` carrier:

```@example scene_object_quickstart
select(
    DataFrame(explain_bindings(plant_scene)),
    :application_id,
    :input,
    :source_ids,
    :carrier_kind,
    :copy_semantics,
)
```

If the consumer model runs on each plant, use `within=Subtree()` to read only
objects inside the current plant. Use `within=SceneScope()` when a scene model
must aggregate all matching objects.

## Manual Calls

Use `Calls(...)` when a parent model must directly run selected child models.
This is the mechanism for iterative solvers such as scene energy balance:

```julia
ModelSpec(SceneEnergyBalance(); name=:scene_energy) |>
    AppliesTo(One(scale=:Scene)) |>
    Calls(
        :leaf_energy => Many(
            kind=:plant,
            scale=:Leaf,
            within=SceneScope(),
            application=:energy_balance,
        ),
        :soil => One(
            kind=:soil,
            scale=:Soil,
            within=SceneScope(),
            application=:soil_water,
        ),
    ) |>
    TimeStep(Hour(1))
```

Inside the parent model:

```julia
function PlantSimEngine.run!(model::SceneEnergyBalance, models, status, meteo,
                             constants, extra)
    for target in call_targets(extra, :leaf_energy)
        run_call!(target; meteo=trial_meteo(model, status))
    end

    for target in call_targets(extra, :leaf_energy)
        run_call!(target; meteo=accepted_meteo(model, status), publish=true)
    end

    return nothing
end
```

`run_call!` defaults to `publish=false`, so trial calls mutate target statuses
without publishing temporal streams or mutable environment outputs. The
accepted state should use `publish=true`.

## Next Steps

- [Migrating To The Scene/Object API](../migration_scene_object.md) translates
  scenarios written with removed APIs.
- [Public API](../API/API_public.md) lists constructors, selectors, lifecycle
  helpers, environment helpers, and explanation helpers.
- [Model traits](../model_traits.md) documents `inputs_`, `outputs_`, `dep`,
  `timespec`, `output_policy`, `meteo_inputs_`, and `meteo_outputs_`.
- [MAESPA-style scene example handoff](../dev/maespa_scene_handoff.md)
  records the current multi-plant scene energy-balance acceptance example.

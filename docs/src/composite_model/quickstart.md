# CompositeModel/Object Quickstart

This page is the shortest path to a native composite-model/object simulation.

Use this API for new multiscale, multi-plant, soil, microclimate, and
model-scale simulations:

```julia
CompositeModel
Object
ModelSpec
AppliesTo
Inputs
Calls
Updates
TimeStep
Environment
```

Scenarios are defined with `CompositeModel` and model applications. A model is a
reusable process implementation; an application is one configured use of that
model, including its name, target objects, inputs, cadence, and environment.
One application may run on many objects, and the same model may appear in
several applications with different parameters or targets.

```@setup model_object_quickstart
using PlantSimEngine, PlantMeteo, Dates, DataFrames
using PlantSimEngine.Examples
```

## One Object, Several Models

For models that all run on one object, the concise constructor lowers directly
to the ordinary CompositeModel/Object representation:

```julia
model = CompositeModel(ModelA(), ModelB(); status=(initial_value=1.0,))
```

Use the explicit form later in this guide when applications need names,
selectors, or other scenario policies.

The first model has one object, `:scene`, and three model applications:

- `ToyDegreeDaysCumulModel` computes daily thermal time;
- `ToyLAIModel` consumes cumulative thermal time and computes LAI;
- `Beer` consumes LAI and meteorology to compute absorbed PAR.

The model implementations are ordinary PlantSimEngine kernels. The model
application layer decides where they run. With no explicit `TimeStep`, these
applications use the environment cadence.

```@example model_object_quickstart
meteo_day = read_weather(
    joinpath(pkgdir(PlantSimEngine), "examples/meteo_day.csv");
    duration=Dates.Day,
)

model = CompositeModel(
    ToyDegreeDaysCumulModel(),
    ToyLAIModel(),
    Beer(0.6);
    environment=meteo_day,
)

sim = run!(model; steps=30, outputs=:all)
out = collect_outputs(sim; sink=DataFrame)
first(out, 6)
```

The model object now holds the latest status values:

```@example model_object_quickstart
scene_status = only(model_objects(model; scale=:Scene)).status
(TT_cu=scene_status.TT_cu, LAI=scene_status.LAI, aPPFD=scene_status.aPPFD)
```

## Inspect The Compiled Bindings

Before running, `explain_initialization(model)` classifies each variable as
`:supplied`, `:generated`, `:producer_bound`, `:environment_bound`, or
`:unresolved`. The report remains available when ordinary required values are
missing, so it can be used to finish configuring a model.

The compiler infers unambiguous same-object dependencies from declared model
inputs and outputs:

- `:LAI_Dynamic` reads `TT_cu` from `:Degreedays`;
- `:light_interception` reads `LAI` from `:LAI_Dynamic`.

```@example model_object_quickstart
select(
    DataFrame(explain_bindings(model)),
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

```@example model_object_quickstart
select(
    DataFrame(explain_execution_plan(model)),
    :application_id,
    :object_ids,
    :batch_size,
    :inner_loop_dispatch,
)
```

## Request Outputs

By default, model runs retain no user output streams. Pass `outputs=:all` to
retain every publisher, or pass `OutputRequest` values to retain and
materialize selected streams plus those required by temporal inputs.

```@example model_object_quickstart
request = OutputRequest(
    Many(scale=:Scene),
    :LAI;
    name=:lai_every_two_days,
    application=:LAI_Dynamic,
    policy=HoldLast(),
    clock=Day(2),
)

requested_sim = run!(
    model;
    steps=30,
    outputs=request,
)

collect_outputs(requested_sim, :lai_every_two_days; sink=nothing)[1:4]
```

The retention explanation reports why a stream was kept:

```@example model_object_quickstart
explain_output_retention(requested_sim)
```

## Many Objects As Inputs

Use `Inputs(...)` when a model needs values from selected objects. This
model-scale LAI model reads live references to the surface of every plant:

```@example model_object_quickstart
plant_scene = CompositeModel(
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
plant_model_status = only(model_objects(plant_scene; scale=:Scene)).status
(total_surface=plant_model_status.total_surface, LAI=plant_model_status.LAI)
```

The compiled binding shows a `RefVector` carrier:

```@example model_object_quickstart
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
objects inside the current plant. Use `within=SceneScope()` when a model model
must aggregate all matching objects.

## Manual Calls

Use `Calls(...)` when a parent model must directly run selected child models.
This is the mechanism for iterative solvers such as model energy balance:

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

For a one-shot call, execute all targets directly:

```julia
targets = run_call!(extra, :leaf_energy; meteo=meteo, publish=true)
```

`targets` is always vector-like regardless of whether the declaration uses
`One`, `OptionalOne`, or `Many`. For iterative control, retrieve the same
compiled targets without executing them:

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

- [Migrating To The CompositeModel/Object API](../migration_composite_model.md) translates
  scenarios written with removed APIs.
- [Public API](../API/API_public.md) lists constructors, selectors, lifecycle
  helpers, environment helpers, and explanation helpers.
- [Model traits](../model_traits.md) documents `inputs_`, `outputs_`, `dep`,
  `timespec`, `output_policy`, `meteo_inputs_`, and `meteo_outputs_`.
- [MAESPA-style model example handoff](../dev/maespa_model_handoff.md)
  records the current multi-plant model energy-balance acceptance example.

# Standard model coupling

```@setup scene_coupling
using PlantSimEngine
using PlantSimEngine.Examples
using PlantMeteo, Dates, DataFrames

meteo_day = read_weather(
    joinpath(pkgdir(PlantSimEngine), "examples/meteo_day.csv");
    duration=Dates.Day,
)
```

This page shows the standard coupling case: one model computes a variable that
another model reads. In the composite-model/object API, the user describes model
applications on objects, and the compiler wires the value dependencies.

## Setting up your environment

Make sure you have a working Julia environment with PlantSimEngine and the
recommended companion packages. Details are provided on the
[Installing PlantSimEngine](../prerequisites/installing_plantsimengine.md)
page.

## One object and one model

A model contains objects. A model application says where a model runs. Here a
light interception model runs on the model object, uses the environment's
daily cadence, and reads `LAI` from that object's status:

```@example scene_coupling
light_scene = CompositeModel(
    Beer(0.5);
    status=(LAI=2.0,),
    environment=meteo_day,
)

light_sim = run!(light_scene; steps=3, outputs=:all)
first(collect_outputs(light_sim; sink=DataFrame), 3)
```

## Coupling two models

Suppose we want `ToyLAIModel` to compute `LAI` for `Beer`. Both models can run
on the same object. `ToyLAIModel` produces `LAI`, and `Beer` declares `LAI` as
an input, so the model compiler infers the binding:

```@example scene_coupling
coupled_scene = CompositeModel(
    ToyDegreeDaysCumulModel(),
    ToyLAIModel(),
    Beer(0.5);
    environment=meteo_day,
)

select(
    DataFrame(Diagnostics.explain_bindings(coupled_scene)),
    :application_id,
    :input,
    :source_application_ids,
    :origin,
    :carrier_kind,
    :copy_semantics,
)
```

The `:inferred_same_object` rows are soft dependencies: the consumer input is
provided by another model output. Same-rate local links use live references, so
the timestep loop does not copy values between models.

Run the coupled model:

```@example scene_coupling
coupled_sim = run!(coupled_scene; steps=5)
coupled_status = only(model_objects(coupled_scene; scale=:Scene)).status
(TT_cu=coupled_status.TT_cu, LAI=coupled_status.LAI, aPPFD=coupled_status.aPPFD)
```

## Adding another model

Additional models are just additional applications. `ToyRUEGrowthModel`
consumes `aPPFD`, which is produced by `Beer`, so the compiler infers another
same-object binding:

```@example scene_coupling
growth_scene = CompositeModel(
    ToyDegreeDaysCumulModel(),
    ToyLAIModel(),
    Beer(0.5),
    ToyRUEGrowthModel(0.2);
    environment=meteo_day,
)

growth_sim = run!(growth_scene; steps=5)
growth_status = only(model_objects(growth_scene; scale=:Scene)).status
(LAI=growth_status.LAI, aPPFD=growth_status.aPPFD, biomass=growth_status.biomass)
```

Older examples used the removed mapping runtime for this workflow. New
scenarios start from `CompositeModel`, `Object`, `ModelSpec`, `on`, `inputs`,
`calls`, and `every`.

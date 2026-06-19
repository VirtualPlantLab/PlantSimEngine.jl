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
another model reads. In the scene/object API, the user describes model
applications on objects, and the compiler wires the value dependencies.

## Setting up your environment

Make sure you have a working Julia environment with PlantSimEngine and the
recommended companion packages. Details are provided on the
[Installing PlantSimEngine](../prerequisites/installing_plantsimengine.md)
page.

## One object and one model

A scene contains objects. A model application says where a model runs and at
which timestep. Here a light interception model runs on the scene object and
reads `LAI` from that object's status:

```@example scene_coupling
light_scene = Scene(
    Object(:scene; scale=:Scene, kind=:scene, status=Status(LAI=2.0));
    applications=(
        ModelSpec(Beer(0.5); name=:light_interception) |>
            AppliesTo(One(scale=:Scene)) |>
            TimeStep(Day(1)),
    ),
    environment=meteo_day,
)

light_sim = run!(light_scene; steps=3, constants=Constants())
first(collect_outputs(light_sim; sink=DataFrame), 3)
```

## Coupling two models

Suppose we want `ToyLAIModel` to compute `LAI` for `Beer`. Both models can run
on the same object. `ToyLAIModel` produces `LAI`, and `Beer` declares `LAI` as
an input, so the scene compiler infers the binding:

```@example scene_coupling
coupled_scene = Scene(
    Object(:scene; scale=:Scene, kind=:scene);
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
    DataFrame(explain_bindings(coupled_scene)),
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

Run the coupled scene:

```@example scene_coupling
coupled_sim = run!(coupled_scene; steps=5, constants=Constants())
coupled_status = only(scene_objects(coupled_scene; scale=:Scene)).status
(TT_cu=coupled_status.TT_cu, LAI=coupled_status.LAI, aPPFD=coupled_status.aPPFD)
```

## Adding another model

Additional models are just additional applications. `ToyRUEGrowthModel`
consumes `aPPFD`, which is produced by `Beer`, so the compiler infers another
same-object binding:

```@example scene_coupling
growth_scene = Scene(
    Object(:scene; scale=:Scene, kind=:scene);
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

Older examples used the removed mapping runtime for this workflow. New
scenarios start from `Scene`, `Object`, `ModelSpec`, `AppliesTo`, `Inputs`,
`Calls`, and `TimeStep`.

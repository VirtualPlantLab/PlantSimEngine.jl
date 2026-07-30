# Model switching

```@setup scene_model_switching
using PlantSimEngine, PlantMeteo, Dates, DataFrames
using PlantSimEngine.Examples

meteo_day = read_weather(
    joinpath(pkgdir(PlantSimEngine), "examples/meteo_day.csv");
    duration=Dates.Day,
)
```

One main objective of PlantSimEngine is to let users switch between model
implementations for a process without changing the engine or the other model
kernels.

In the composite-model/object API, the switch happens at the model-application layer:
replace the model inside a `ModelSpec`, keep the same `ModelSpec(...; on=...)`
selector, and keep the same input contract when the replacement model needs the
same variables.

## A first simulation

This model computes degree-days, LAI, absorbed PAR, and growth on one model
object:

```@example scene_model_switching
function plant_model_with_growth(growth_model; growth_name=:growth)
    CompositeModel(
        Object(:scene; scale=:Scene, kind=:scene);
        applications=(
            ModelSpec(ToyDegreeDaysCumulModel(); name=:degree_days, on=One(scale=:Scene), every=Day(1)),

            ModelSpec(ToyLAIModel(); name=:lai, on=One(scale=:Scene), every=Day(1)),

            ModelSpec(Beer(0.5); name=:light_interception, on=One(scale=:Scene), every=Day(1)),

            ModelSpec(growth_model; name=growth_name, on=One(scale=:Scene), every=Day(1)),
        ),
        environment=meteo_day,
    )
end

rue_scene = plant_model_with_growth(ToyRUEGrowthModel(0.2))
rue_sim = run!(rue_scene; steps=10)
rue_status = final_state(rue_sim)
(growth_model=:ToyRUEGrowthModel, biomass=rue_status.biomass)
```

The compiler infers the same-object bindings from the model declarations. The
growth model reads `aPPFD`, which is produced by the light interception model:

```@example scene_model_switching
select(
    DataFrame(Diagnostics.explain_bindings(rue_scene)),
    :application_id,
    :input,
    :source_application_ids,
    :origin,
    :carrier_kind,
)
```

## Switching the growth model

`ToyAssimGrowthModel` implements the same `:growth` process, reads the same
`aPPFD` input, and computes additional outputs such as carbon assimilation and
respiration. The rest of the model does not need to change:

```@example scene_model_switching
assim_scene = plant_model_with_growth(ToyAssimGrowthModel())
assim_sim = run!(assim_scene; steps=10)
assim_status = final_state(assim_sim)
(
    growth_model=:ToyAssimGrowthModel,
    carbon_assimilation=assim_status.carbon_assimilation,
    Rm=assim_status.Rm,
    biomass=assim_status.biomass,
)
```

The dependency graph and execution plan are rebuilt from the new application
set:

```@example scene_model_switching
select(
    DataFrame(Diagnostics.explain_execution_plan(assim_sim)),
    :application_id,
    :object_ids,
    :batch_size,
    :inner_loop_dispatch,
)
```

This is the same principle used in larger composite models: switch one process
implementation by replacing one `ModelSpec` or by using an
`ObjectInstance(...; overrides=...)` when the change applies to one plant
instance or one organ.

The removed mapping runtime expressed the same idea differently. New scenario
code expresses model switching through model model applications.

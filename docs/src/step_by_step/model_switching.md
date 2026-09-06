# Model compatibility and replacement

```@setup scene_model_switching
using PlantSimEngine, PlantMeteo, Dates, DataFrames
using PlantSimEngine.Examples

meteo_day = read_weather(
    joinpath(pkgdir(PlantSimEngine), "examples/meteo_day.csv");
    duration=Dates.Day,
)
```

One main objective of PlantSimEngine is to compare and switch model
implementations for a process without changing the engine or unrelated model
kernels. Process identity and substitutability are nevertheless different
claims:

1. **Same process:** two models answer the same scientific question.
2. **Scenario-compatible replacement:** the new model supplies every value
   required by the current consumers and its own inputs can be bound.
3. **Drop-in replacement:** process, status and environment ports, scientific
   contracts, dependencies, and relevant traits are compatible without
   changing scenario wiring.

Only the third level is suitable for an `Override`, whose applications share
one logical interface. Models may belong to the same process while using
different inputs or producing additional outputs; this is useful scientific
variation, not an error.

At the model-application layer, replace the model inside a `ModelSpec`, keep
the same `ModelSpec(...; on=...)` selector, then revalidate every binding and
consumer affected by the changed interface.

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

`ToyAssimGrowthModel` implements the same `:growth` process and reads the same
`aPPFD` input, but computes additional outputs such as carbon assimilation and
respiration. It is compatible with this small scenario because no downstream
model requires an output that disappeared. Its larger output interface means
that same process alone did not prove a strict drop-in replacement:

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

## Check before replacing

Use the public authoring report on the concrete instances:

```@example scene_model_switching
alternative_asset = joinpath(
    pkgdir(PlantSimEngine),
    "skills",
    "plantsimengine",
    "assets",
    "alternative-model.jl",
)
include(alternative_asset)
using .AlternativeModelExample

drop_in = Authoring.compare_models(
    LinearCarbonGain(0.2),
    SaturatingCarbonGain(10.0, 5.0),
)
needs_binding = Authoring.compare_models(
    LinearCarbonGain(0.2),
    WaterLimitedCarbonGain(0.2),
)
(
    drop_in=(
        same_process=drop_in.same_process,
        override_compatible=drop_in.override_compatible,
        requires_reconfiguration=drop_in.requires_reconfiguration,
        compatibility=drop_in.compatibility,
    ),
    water_limited=(
        same_process=needs_binding.same_process,
        override_compatible=needs_binding.override_compatible,
        requires_binding_changes=needs_binding.requires_binding_changes,
        requires_reconfiguration=needs_binding.requires_reconfiguration,
        compatibility=needs_binding.compatibility,
    ),
)
```

`requires_binding_changes` is specific to ports, contracts, dependencies,
output policies, or model-level environment hints. `requires_reconfiguration`
is broader: it is true for any interface difference that prevents a direct
override, including a schedule-only trait change.

The report compares:

- `process(model)`;
- required and defaulted status inputs, including declared types;
- local `outputs_` schemas, including initial values;
- environment inputs and outputs;
- complete `VariableContract`s;
- model-authored `Input`, `Call`, and `Initializer` dependencies;
- cadence and temporal output policies.

A variable with the same name but a different unit, basis, temporal meaning,
aggregation, or extent is incompatible. Add an explicit adapter rather than
weakening or omitting the contract.

After replacement, compile the candidate scenario and inspect:

```@example scene_model_switching
candidate_validation = Authoring.validate_scenario(assim_scene)
(
    scenario_valid=candidate_validation.valid,
    initialization=Diagnostics.explain_initialization(assim_scene),
    bindings=Diagnostics.explain_bindings(assim_scene),
    schedule=Diagnostics.explain_schedule(assim_scene),
)
```

The compiler diagnostics prove that this concrete scenario can initialize and
route the replacement. They do not prove that two equations are scientifically
equivalent or valid over the same domain; that remains model documentation and
validation evidence. Distributed `outputs_to` destinations belong to the
`ModelSpec`, not `ModelInterface`, so revalidate them at this scenario level.

Use `ObjectInstance(...; overrides=...)` only for a model that satisfies the
logical application's exact replacement contract. Otherwise create or replace
a complete `ModelSpec` and update the affected bindings explicitly.

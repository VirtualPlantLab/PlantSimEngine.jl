# Implement Environment And Cadence Traits

**New concept:** model-authored runtime traits. Environment declarations name
the fields a kernel samples, while cadence and output-policy traits state when
the same kernel runs and how its values cross clocks.

Simulation users configure providers in [Understand Environments](@ref) and
application clocks in [Give Models Different Cadences](@ref).

## Model 6: declare sampled environment inputs

`ToyMaintenanceRespirationModel` reads object state and sampled temperature.
The tested contract names that environment field explicitly:

```@example modeler_environment_time
using Dates, PlantMeteo, PlantSimEngine, DataFrames
using PlantSimEngine.Examples

respiration = ToyMaintenanceRespirationModel(
    2.0,
    0.06,
    25.0,
    0.5,
    0.02,
)
(
    inputs=PlantSimEngine.inputs_(respiration),
    environment_inputs=PlantSimEngine.environment_inputs_(respiration),
    environment_outputs=PlantSimEngine.environment_outputs_(respiration),
    outputs=PlantSimEngine.outputs_(respiration),
)
```

The kernel reads model parameters from `model`, object state from `status`, and
forcing from `environment`:

```@example modeler_environment_time
direct_status = Status(carbon_biomass=10.0, Rm=-Inf)
PlantSimEngine.run!(
    respiration,
    direct_status,
    (T=25.0,),
    nothing,
    nothing,
)
direct_status
```

```@example modeler_environment_time
model = CompositeModel(
    Object(
        :leaf;
        scale=:Leaf,
        status=Status(carbon_biomass=10.0),
    );
    applications=(
        ModelSpec(
            respiration;
            name=:maintenance,
            on=One(scale=:Leaf),
        ),
    ),
    environment=Atmosphere(
        T=25.0,
        Wind=1.0,
        Rh=0.7,
        duration=Hour(1),
    ),
)

(
    declared=PlantSimEngine.environment_inputs_(respiration),
    final=final_state(run!(model)),
)
```

The model does not name a provider or inspect raw weather storage.
`Environment(...)` remains scenario configuration.

## Model 7: declare cadence and output semantics

`ToyDailyDevelopmentModel` accumulates one increment whenever it runs. Its
model-level traits say “every 24 simulation steps, starting at step 1” and
“consumers may hold the last daily value between publications”:

```@example modeler_environment_time
daily = ToyDailyDevelopmentModel(2.0)
(
    clock=PlantSimEngine.timespec(daily),
    outputs=PlantSimEngine.output_policy(daily),
)
```

`ClockSpec` is expressed in simulation steps. Use
`ModelSpec(...; every=Day(1))` when a scenario should express a
duration-relative cadence or override the model default.

```@example modeler_environment_time
daily_model = CompositeModel(
    Object(:plant; scale=:Plant);
    applications=(
        ModelSpec(
            daily;
            name=:daily_development,
            on=One(scale=:Plant),
        ),
    ),
    environment=[
        (duration=Hour(1),)
        for _ in 1:25
    ],
)

daily_simulation =
    run!(daily_model; steps=25, outputs=:all)
(
    traits=(
        clock=PlantSimEngine.timespec(daily),
        outputs=PlantSimEngine.output_policy(daily),
    ),
    schedule=DataFrame(Diagnostics.explain_schedule(daily_model)),
    final=final_state(daily_simulation),
    retained=DataFrame(
        Diagnostics.explain_outputs(daily_simulation),
    ),
)
```

The model runs at steps 1 and 25. A downstream application can override
`HoldLast` with an explicit selector policy when its scientific interpretation
requires `Integrate`, `Aggregate`, or `Interpolate`.

## Model-author recap

- **You implemented:** declared environment reads, a model default clock, and
  per-output temporal meaning.
- **PlantSimEngine inferred:** environment validation/sampling, execution
  steps, and the default cross-clock policy.
- **The scenario author keeps explicit:** concrete environment provider,
  simulation base step, cadence overrides, and input-policy overrides.
- **New API names:** `environment_inputs_`, `timespec`, `ClockSpec`,
  `output_policy`, and `HoldLast`.

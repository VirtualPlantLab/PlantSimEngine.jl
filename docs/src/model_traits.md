# Model Traits

Model traits describe intrinsic model behavior. Scenario-specific coupling
belongs in `ModelSpec` through `AppliesTo`, `Inputs`, `Calls`, `TimeStep`,
`Environment`, `OutputRouting`, and `Updates`.

## Variables

Implement `inputs_(model)` and `outputs_(model)` with default values:

```julia
PlantSimEngine.inputs_(::MyModel) = (leaf_area=0.0,)
PlantSimEngine.outputs_(::MyModel) = (assimilation=0.0,)
```

The declarations are used for status initialization, dependency inference,
validation, and type construction.

## Manual Dependencies

Implement `dep(model)` only when the model directly calls another process from
inside its own `run!` method:

```julia
PlantSimEngine.dep(::EnergyBalance) = (
    photosynthesis=AbstractPhotosynthesisModel,
)
```

The scenario binds the dependency with `Calls(...)`. The parent executes all
resolved targets with `run_call!(extra, :photosynthesis)`, which always returns
a vector-like collection. Use `call_targets` plus `run_call!(target)` when the
parent needs selective trials and accepted publication.

## Timing

`timespec(model)` declares the model's default clock. The default is
`ClockSpec(1.0, 0.0)`.

```julia
PlantSimEngine.timespec(::Type{<:DailyGrowth}) = ClockSpec(Dates.Day(1))
```

`output_policy(model)` declares the default temporal policy per output:

```julia
PlantSimEngine.output_policy(::Type{<:MyModel}) = (
    assimilation=Integrate(),
    leaf_temperature=Aggregate(MeanReducer()),
)
```

Unspecified outputs use `HoldLast()`. A scenario can select another clock with
`TimeStep(...)` and another input policy in `Inputs(...)`.

`timestep_hint(model)` can declare required or preferred timestep constraints.
`meteo_hint(model)` can provide default environment sampling configuration.

## Environment Variables

Use `meteo_inputs_(model)` for variables sampled from the active environment
backend:

```julia
PlantSimEngine.meteo_inputs_(::LeafEnergyBalance) = (
    T=0.0,
    Rh=0.0,
    Wind=0.0,
    Ri_PAR_f=0.0,
    CO2=400.0,
)
```

Mutable microclimate updates should be committed explicitly by controller
models:

```julia
update_environment!(extra, accepted_meteo)
```

For trial solves, wrap descendant calls in `with_environment!` so hard-called
models sample a temporary atmosphere without committing it:

```julia
with_environment!(extra, trial_meteo) do
    run_call!(extra, :leaf_energy; publish=false)
end
```

Diagnostic variables such as canopy temperature or vapor-pressure deficit can
still be regular `outputs_`, but status fields are not the transport mechanism
for mutable environment state.

## Precedence

Scenario configuration has precedence over model defaults:

1. `Inputs(...)` policy, then producer `output_policy`, then `HoldLast()`.
2. `TimeStep(...)`, then `timespec(model)`, then the environment base step.
3. `Environment(...)`, then `meteo_hint(model)`, then backend defaults.

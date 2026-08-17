# Model Traits

Model traits describe intrinsic model behavior. Scenario-specific coupling
belongs in `ModelSpec` through `on`, `inputs`, `calls`, `every`,
`Environment`, `output_routing`, and `Updates`.

## Variables

Implement `inputs_(model)` with an explicit declaration for every status input:

```julia
PlantSimEngine.inputs_(::MyModel) = (
    leaf_area=Required(Float64),
    efficiency=Default(0.8),
)
PlantSimEngine.outputs_(::MyModel) = (assimilation=0.0,)
```

`Required(T)` means the value must be present on the target object's `Status`
or bound from another application. `T` is an expected type, not a placeholder
value. It may be abstract or parametric, so use the scientific type contract
instead of forcing `Float64`.

`Default(value)` means the model can run without user initialization or a
producer for that input. PlantSimEngine installs a private copy of `value` on
each target object when the value is absent. Mutable defaults are therefore
not shared between objects.

Output literals remain initial output-state values. In the example,
`assimilation` starts at `0.0` before the first accepted model call.

These declarations are used for status initialization, dependency inference,
validation, and type construction. Plain input literals are rejected because
they do not say whether the value is required or genuinely optional.

Use `init_variables(model)` to inspect only values PlantSimEngine can
initialize by itself: `Default` input values and output initial values.
Required inputs are intentionally omitted.

Before running a scenario, `Diagnostics.explain_initialization(model)` classifies inputs as
`:required`, `:defaulted`, `:supplied`, or `:producer_bound`. A
`:required` row must be resolved before compilation can succeed.

## Manual Dependencies

Implement `dep(model)` only when the model directly calls another process from
inside its own `run!` method:

```julia
PlantSimEngine.dep(::EnergyBalance) = (
    photosynthesis=AbstractPhotosynthesisModel,
)
```

The scenario binds the dependency with `ModelSpec(...; calls=...)`. The parent executes all
resolved targets with `run_call!(context, :photosynthesis)`, which always returns
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
`ModelSpec(...; every=...)` and another input policy in `ModelSpec(...; inputs=...)`.

`timestep_hint(model)` can declare required or preferred timestep constraints.
`environment_hint(model)` can provide default environment sampling configuration.

## Environment Variables

Use `environment_inputs_(model)` for variables sampled from the active environment
backend:

```julia
PlantSimEngine.environment_inputs_(::LeafEnergyBalance) = (
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
commit_environment!(context, accepted_environment)
```

For trial solves, pass a backend-specific state with `environment` so each
hard-called model keeps its compiled provider or spatial handle:

```julia
run_call!(context, :leaf_energy; environment=trial_environment, publish=false)
```

Diagnostic variables such as canopy temperature or vapor-pressure deficit can
still be regular `outputs_`, but status fields are not the transport mechanism
for mutable environment state.

## Precedence

Scenario configuration has precedence over model defaults:

1. `ModelSpec(...; inputs=...)` policy, then producer `output_policy`, then `HoldLast()`.
2. `ModelSpec(...; every=...)`, then `timespec(model)`, then the environment base step.
3. `Environment(...)`, then `environment_hint(model)`, then backend defaults.

# Model traits

This page centralizes the model-level traits that can be defined in `PlantSimEngine`.
It complements:

- [Model execution](model_execution.md) for runtime behavior,
- [Parallelization](step_by_step/parallelization.md) for execution over objects/time-steps.

## Trait inventory for models

### `timespec(::Type{<:MyModel})`

Defines the default execution clock of a model.

Default:

```julia
PlantSimEngine.timespec(::Type{<:AbstractModel}) = ClockSpec(1.0, 0.0)
```

Use it when your model has a natural native clock (for example daily by default).

### `output_policy(::Type{<:MyModel})`

Defines per-output default schedule policy for produced streams.

Default:

```julia
PlantSimEngine.output_policy(::Type{<:AbstractModel}) = NamedTuple()
```

Behavior:

- unspecified outputs fall back to `HoldLast()`;
- used by runtime when resolving cross-clock reads;
- used as default policy for inferred `PlantSimEngine.InputBindings(...)` when users do not provide explicit bindings;
- hint-only and lazy: policy is applied only for outputs that are actually consumed/exported.
  Declaring a policy for an unused output does not trigger integration work.

Example:

```julia
PlantSimEngine.output_policy(::Type{<:MyModel}) = (
    carbon_assimilation=Integrate(),
    leaf_temperature=Aggregate(MeanReducer()),
)
```

Users can always override or complement this trait at mapping level:

```julia
ModelSpec(MyConsumerModel()) |>
PlantSimEngine.InputBindings(
    ;
    carbon_assimilation=(process=:myproducer, var=:carbon_assimilation, policy=HoldLast()), # override trait default
    carbon_assimilation_max=(process=:myproducer, var=:carbon_assimilation, policy=Aggregate(MaxReducer())), # complement with extra derived input
)
```

### `timestep_hint(::Type{<:MyModel})`

Optional compatibility hint when `PlantSimEngine.TimeStepModel(...)` is not provided.

Default:

```julia
PlantSimEngine.timestep_hint(::Type{<:AbstractModel}) = nothing
```

Supported forms include:

- fixed period: `Dates.Hour(1)`;
- range: `(Dates.Minute(30), Dates.Hour(2))`;
- named tuple: `(; required=..., preferred=...)`.

`required` is enforced when runtime uses meteo-derived timestep.
`preferred` is informational only.

### `meteo_hint(::Type{<:MyModel})`

Optional inference trait for weather sampling configuration.

Default:

```julia
PlantSimEngine.meteo_hint(::Type{<:AbstractModel}) = nothing
```

Expected value:

```julia
(; bindings=..., window=...)
```

Where:

- `bindings` is compatible with `PlantSimEngine.MeteoBindings(...)`,
- `window` is compatible with `PlantSimEngine.MeteoWindow(...)`.

### `meteo_inputs_(::MyModel)`
### `meteo_outputs_(::MyModel)`

Declare meteorology or microclimate variables separately from object status
variables.

Default:

```julia
PlantSimEngine.meteo_inputs_(::AbstractModel) = NamedTuple()
PlantSimEngine.meteo_outputs_(::AbstractModel) = NamedTuple()
```

Use `meteo_inputs_` for variables read from the weather or environment backend:

```julia
PlantSimEngine.meteo_inputs_(::LeafEnergyBalanceModel) = (
    T=0.0,
    Rh=0.0,
    Wind=0.0,
    Ri_PAR_f=0.0,
    CO2=400.0,
)
```

Use `meteo_outputs_` when a model updates a mutable environment backend, for
example a microclimate model updating local air temperature:

```julia
PlantSimEngine.outputs_(::MicroclimateUpdateModel) = (T=0.0,)
PlantSimEngine.meteo_outputs_(::MicroclimateUpdateModel) = (T=0.0,)
```

The current runtime scatters `meteo_outputs_` from status variables, so the
same variable should usually be declared in `outputs_` as well.

### `TimeStepDependencyTrait(::Type{<:MyModel})`
### `ObjectDependencyTrait(::Type{<:MyModel})`

Parallelization traits (single-scale runtime):

- `TimeStepDependencyTrait`: depends or not on other timesteps;
- `ObjectDependencyTrait`: depends or not on other objects.

Defaults are conservative (`dependent`) and can be overridden when safe.

## Precedence rules

Runtime precedence is intentionally explicit:

1. Input policy:
   explicit `PlantSimEngine.InputBindings(..., policy=...)` > inferred from producer `output_policy` > `HoldLast()`.
1. Timestep:
   `PlantSimEngine.TimeStepModel(...)` > `timespec(model)` when non-default > meteo base step.
1. Meteo sampling:
   explicit `PlantSimEngine.MeteoBindings(...)`/`PlantSimEngine.MeteoWindow(...)` > `meteo_hint(...)` > runtime defaults.

## Is everything documented?

For model-level traits, the documented set is now:

- `timespec`,
- `output_policy`,
- `timestep_hint`,
- `meteo_hint`,
- `meteo_inputs_`,
- `meteo_outputs_`,
- `TimeStepDependencyTrait`,
- `ObjectDependencyTrait`.

Outside model traits, `PlantSimEngine` also exposes data-format traits such as `DataFormat` for input containers (see [Input types](working_with_data/inputs.md)).

## Naming conventions and API consistency

Current API uses two naming styles on purpose:

- snake_case for trait/query functions (`timespec`, `output_policy`, `timestep_hint`, `meteo_hint`);
- CamelCase for `ModelSpec` pipeline transforms (`TimeStepModel`, `InputBindings`, `MeteoBindings`, `MeteoWindow`, `OutputRouting`, `ScopeModel`).

This distinction reflects role:

- snake_case: "what the model declares";
- CamelCase: "what the mapping config applies".

For future unification, a non-breaking path would be:

1. keep existing names as stable API,
1. avoid plain snake_case aliases that would collide with existing getter names
   (`input_bindings`, `meteo_bindings`, `output_routing`, `model_scope`),
1. if needed, add explicit config-oriented aliases with distinct names
   (for example `*_config` forms) and keep current constructors,
1. evaluate deprecations only after one full release cycle and user feedback.

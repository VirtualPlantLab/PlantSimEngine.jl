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
- used as default policy for inferred `InputBindings(...)` when users do not provide explicit bindings.

Example:

```julia
PlantSimEngine.output_policy(::Type{<:MyModel}) = (
    carbon_assimilation=Integrate(),
    leaf_temperature=Aggregate(MeanReducer()),
)
```

### `timestep_hint(::Type{<:MyModel})`

Optional compatibility hint when `TimeStepModel(...)` is not provided.

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

- `bindings` is compatible with `MeteoBindings(...)`,
- `window` is compatible with `MeteoWindow(...)`.

### `TimeStepDependencyTrait(::Type{<:MyModel})`
### `ObjectDependencyTrait(::Type{<:MyModel})`

Parallelization traits (single-scale runtime):

- `TimeStepDependencyTrait`: depends or not on other timesteps;
- `ObjectDependencyTrait`: depends or not on other objects.

Defaults are conservative (`dependent`) and can be overridden when safe.

## Precedence rules

Runtime precedence is intentionally explicit:

1. Input policy:
   explicit `InputBindings(..., policy=...)` > inferred from producer `output_policy` > `HoldLast()`.
1. Timestep:
   `TimeStepModel(...)` > `timespec(model)` when non-default > meteo base step.
1. Meteo sampling:
   explicit `MeteoBindings(...)`/`MeteoWindow(...)` > `meteo_hint(...)` > runtime defaults.

## Is everything documented?

For model-level traits, the documented set is now:

- `timespec`,
- `output_policy`,
- `timestep_hint`,
- `meteo_hint`,
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

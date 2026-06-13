# Public API

## Unified Scene/Object API

New multiscale and multi-object scenarios should start with the following
groups.

### Scenario and model applications

- `Scene` stores the runtime object graph, model applications, instances, and
  environment.
- `Object` represents one runtime entity with stable identity, labels,
  topology, optional geometry, and status.
- `ObjectTemplate` and `ObjectInstance` reuse one plant or object model across
  several concrete instances.
- `ModelSpec(model; name=...)` identifies one model application.
- `AppliesTo(...)` selects the objects where that application runs.

### Value coupling and manual calls

- `Inputs(...)` declares consumer-side value dependencies.
- `Calls(...)` gives a parent model manually executable child targets.
- `Updates(:variable; after=...)` orders intentional duplicate writers.
- `Input(...)` and `Call(...)` express model-author defaults through
  `dep(model)`.
- `run_call!(target; publish=false)` executes a trial hard call.

### Selectors and scopes

- Multiplicity: `One(...)`, `OptionalOne(...)`, and `Many(...)`.
- Scope: `SceneScope()`, `Self()`, `SelfPlant()`, `Ancestor(...)`, and
  `Scope(name)`.
- Labels and topology: `Kind(...)`, `Species(...)`, `Scale(...)`, and
  `Relation(...)`.
- `ObjectAddress` is the normalized compiled selector representation.

### Time and environment

- `TimeStep(period::Dates.Period)` sets an application cadence and overrides a
  model `timespec(...)` trait when both are present.
- `timespec(::Type{<:AbstractModel})` can provide a model-author default
  cadence for scene/object applications.
- `timestep_hint(::Type{<:AbstractModel})` can validate base-step-derived
  scene cadences when `TimeStep(...)` and non-default `timespec(...)` are
  absent.
- `HoldLast`, `Interpolate`, `Integrate`, and `Aggregate` define temporal input
  behavior.
- `output_policy(::Type{<:AbstractModel})` can provide a producer-side default
  temporal policy when an `Inputs(...)` selector omits `policy=...`; explicit
  selector policies take precedence.
- `Environment(...)` optionally overrides automatic environment provider,
  resolver selection, or source remapping such as
  `Environment(; sources=(CO2=:Ca,))`.
- Models declare environment variables with `meteo_inputs_` and
  `meteo_outputs_`.
- `meteo_hint(::Type{<:AbstractModel})` can provide model-author default
  environment source remaps through its `bindings` field; scenario
  `Environment(; sources=...)` overrides those defaults.
- `OutputRequest(...)` can be passed to `run!(scene; tracked_outputs=...)` to
  collect resampled scene output streams after the run. Use `process=...`
  when the process identifies one publisher, or `application=...` when the
  same process is applied more than once. An explicit application may select a
  `:stream_only` publisher.

### Lifecycle and compilation

- `objects_from_mtg` and `Scene(mtg; ...)` adapt an existing MTG subtree to the
  unified object registry.
- `register_object!`, `remove_object!`, and `reparent_object!` change
  topology.
- `move_object!` and `update_geometry!` change spatial state.
- `refresh_bindings!` compiles selectors, carriers, calls, writer order, and
  schedules.
- `refresh_environment_bindings!` compiles cached object-to-environment
  bindings.
- `run!(scene; steps=...)` returns a `SceneSimulation`.
- `scene_outputs(sim)` returns retained typed output streams.
- `collect_outputs(sim)` returns all retained streams, or requested outputs
  when `tracked_outputs` was provided.

```julia
request = OutputRequest(
    :Leaf,
    :transpiration;
    name=:leaf_transpiration_2h,
    application=:sunlit_leaf_energy,
    policy=Integrate(),
    clock=Dates.Hour(2),
)

sim = run!(scene; steps=24, tracked_outputs=request)
out = collect_outputs(sim, :leaf_transpiration_2h; sink=DataFrames.DataFrame)
```

For scene/object runs, `tracked_outputs` is materialized from retained
scene-local output streams. With explicit output requests, the runtime retains
only requested application/variable streams plus streams required by temporal
`Inputs(...)`; `tracked_outputs=OutputRequest[]` retains no output streams
unless temporal dependencies require one. Dynamic objects are exported only
over their own published sample interval. Use `explain_output_retention(sim)`
to inspect why a stream was retained. Dependency-only streams are bounded to
the history required by their temporal policy; requested streams retain their
complete history. Retention explanations report the compiled
`retention_steps`, or `nothing` for full-history streams.

### Structured explanations

Use these instead of inspecting internal dictionaries:

- `explain_objects`
- `explain_instances`
- `explain_scopes`
- `explain_scene_applications`
- `explain_bindings`
- `explain_calls`
- `explain_environment_bindings`
- `explain_schedule`
- `explain_writers`
- `explain_model_bundles`
- `explain_execution_plan`
- `explain_output_retention`
- `explain_outputs`

See [Migrating To The Scene/Object API](../migration_scene_object.md) for
complete old-to-new translations.

## Index

```@index
Pages = ["API_public.md"]
```

## API documentation

```@autodocs
Modules = [PlantSimEngine]
Private = false
```

## Legacy Mapping Multi-Rate Examples

!!! warning "Legacy configuration surface"
    The examples below document the mapping/MTG runtime retained during the
    breaking migration. For new scene/object scenarios, use `TimeStep(...)`
    and put source, policy, and window information directly on `Inputs(...)`.
    `ModelMapping` is no longer exported; retained compatibility code must use
    `PlantSimEngine.ModelMapping(...)`.

For mapping-level multi-rate configuration, combine:

- `PlantSimEngine.ModelMapping(...)`
- `ModelSpec(...)`
- `PlantSimEngine.TimeStepModel(...)`
- `PlantSimEngine.InputBindings(...)`
- `PlantSimEngine.MeteoBindings(...)`
- `PlantSimEngine.MeteoWindow(...)`
- `OutputRouting(...)`
- `PlantSimEngine.ScopeModel(...)`
- `timespec(::Type{<:AbstractModel})` (optional trait)
- `output_policy(::Type{<:AbstractModel})` (optional trait)
- `timestep_hint(::Type{<:AbstractModel})` (optional trait)
- `meteo_hint(::Type{<:AbstractModel})` (optional trait)
- `resolved_model_specs(mapping)` (utility)
- `explain_model_specs(mapping_or_sim)` (utility)
- `OutputRequest(...)` in `tracked_outputs` for resampled exports

`PlantSimEngine.TimeStepModel(...)` accepts:
- `Real` step counts
- `ClockSpec`
- fixed `Dates` periods (`Dates.Second`, `Dates.Minute`, `Dates.Hour`, `Dates.Day`, ...)

Period conversion detail:
- Period-based timesteps are converted using the meteo base step `duration`.
- Example: `PlantSimEngine.TimeStepModel(Dates.Day(1))` with hourly meteo (`Dates.Hour(1)`) maps to `ClockSpec(24.0, 1.0)`,
  so execution times are `t = 1, 25, 49, ...`.

Trait-based inference detail:
- If `PlantSimEngine.TimeStepModel(...)` is omitted, runtime resolves timestep from:
: `timespec(model)` when non-default, otherwise meteo `duration`.
- `timestep_hint(::Type{<:Model})` is then interpreted as:
: `required` = hard compatibility constraint, `preferred` = informational only.
- If `PlantSimEngine.InputBindings(...)` is omitted, same-name sources are inferred automatically from
: unique producers (same scale first, then cross-scale). Ambiguous cases require explicit bindings.
- For inferred bindings, policy defaults to producer `output_policy` when defined, otherwise `HoldLast()`.
- Explicit `PlantSimEngine.InputBindings(..., policy=...)` always overrides trait defaults.
- `output_policy` is hint-only: it is applied only when an output is actually consumed/exported.
- If `PlantSimEngine.MeteoBindings(...)` / `PlantSimEngine.MeteoWindow(...)` are omitted, `meteo_hint(::Type{<:Model})`
: may provide `(; bindings=..., window=...)`.
- Explicit mapping-level configuration always overrides hints.

Compatibility checks:
- Meteo `duration` is mandatory when meteo is provided.
- For models with meteo-derived timestep, runtime enforces `timestep_hint.required`.
- `timestep_hint.preferred` never sets runtime timestep by itself.

Scope selection detail:
- `PlantSimEngine.ScopeModel(:global)` is the default and shares streams across the whole simulation.
- `PlantSimEngine.ScopeModel(:plant)` isolates streams within each plant subtree.
- `PlantSimEngine.ScopeModel(:scene)` isolates by scene ancestor.
- `PlantSimEngine.ScopeModel(:self)` isolates by node id.

### Exporting variables at requested rates

```julia
req_hold = OutputRequest(:Leaf, :A; name=:A_hourly, process=:assim, policy=HoldLast())
req_day = OutputRequest(:Leaf, :A; name=:A_daily_sum, process=:assim, policy=Integrate(), clock=ClockSpec(24.0, 1.0))
run!(sim, meteo; tracked_outputs=[req_hold, req_day], executor=SequentialEx())
out = collect_outputs(sim; sink=DataFrame)

# or directly:
out_status, out = run!(
    sim,
    meteo;
    tracked_outputs=[req_hold, req_day],
    return_requested_outputs=true,
)
```

- `process` is optional when the source is canonical and unique.
- `policy` defines how source streams are resampled at export time.
- `clock` defines the export schedule; omit it to export every simulation step.

### Default hold-last

```julia
ModelSpec(ConsumerModel()) |>
PlantSimEngine.TimeStepModel(ClockSpec(2.0, 1.0)) |>
PlantSimEngine.InputBindings(; x=(process=:producer, var=:x))
```

### Meteo aggregation bindings

```julia
ModelSpec(DailyModel()) |>
PlantSimEngine.TimeStepModel(ClockSpec(24.0, 1.0)) |>
PlantSimEngine.MeteoWindow(CalendarWindow(:day; anchor=:current_period, week_start=1, completeness=:strict)) |>
PlantSimEngine.MeteoBindings(
    T=MeanWeighted(),                     # default source is :T
    Ri_SW_f=RadiationEnergy(),            # integrate W m-2 to MJ m-2 over the model window
    custom_peak=(source=:custom_var, reducer=MaxReducer()),
)
```

`PlantSimEngine.MeteoWindow(...)` options:
- `RollingWindow()` (default): trailing rolling window driven by `dt`.
- `CalendarWindow(period; anchor, week_start, completeness)` with:
: `period` in `:day`, `:week`, `:month`
: `anchor` in `:current_period`, `:previous_complete_period`
: `week_start` in `1:7` (1 = Monday)
: `completeness` in `:allow_partial`, `:strict`

### Parameterized window reducers

`Integrate()` defaults to `SumReducer()`; `Aggregate()` defaults to `MeanReducer()`.
With the same reducer, they are runtime-equivalent.
Use `Integrate` for accumulation semantics and `Aggregate` for summary-statistics semantics.

```julia
ModelSpec(DailyModel()) |>
PlantSimEngine.TimeStepModel(ClockSpec(24.0, 1.0)) |>
PlantSimEngine.InputBindings(; a=(process=:hourly_assim, var=:A, scale=:Leaf, policy=Integrate(SumReducer())))

ModelSpec(DailyModel()) |>
PlantSimEngine.TimeStepModel(ClockSpec(24.0, 1.0)) |>
PlantSimEngine.InputBindings(; a=(process=:hourly_assim, var=:A, scale=:Leaf, policy=Aggregate(MaxReducer())))

ModelSpec(DailyModel()) |>
PlantSimEngine.TimeStepModel(ClockSpec(24.0, 1.0)) |>
PlantSimEngine.InputBindings(; a=(process=:hourly_assim, var=:A, scale=:Leaf, policy=Integrate(vals -> maximum(vals) - minimum(vals))))

ModelSpec(DailyModel()) |>
PlantSimEngine.TimeStepModel(ClockSpec(24.0, 1.0)) |>
PlantSimEngine.InputBindings(; a=(process=:hourly_assim, var=:A, scale=:Leaf, policy=Integrate((vals, durations) -> sum(vals .* durations))))

ModelSpec(DailyModel()) |>
PlantSimEngine.TimeStepModel(ClockSpec(24.0, 1.0)) |>
PlantSimEngine.InputBindings(; a=(process=:hourly_assim, var=:A, scale=:Leaf, policy=Integrate(PlantMeteo.DurationSumReducer())))
```

Built-in reducer types are:
`SumReducer()`, `MeanReducer()`, `MaxReducer()`, `MinReducer()`, `FirstReducer()`, `LastReducer()`.
The same reducer objects are also used by `PlantSimEngine.MeteoBindings(...)`.
Custom reducers/callables can accept either `(values)` or `(values, durations_seconds)`.

### Parameterized interpolation mode

`Interpolate()` defaults to `mode=:linear, extrapolation=:linear`.

```julia
ModelSpec(FastModel()) |>
PlantSimEngine.TimeStepModel(1.0) |>
PlantSimEngine.InputBindings(; x=(process=:slow_source, var=:x, policy=Interpolate()))

ModelSpec(FastModel()) |>
PlantSimEngine.TimeStepModel(1.0) |>
PlantSimEngine.InputBindings(; x=(process=:slow_source, var=:x, policy=Interpolate(; mode=:hold, extrapolation=:hold)))
```

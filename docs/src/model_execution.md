# Model execution

## Simulation order

`PlantSimEngine.jl` uses the [`ModelMapping`](@ref) to automatically compute a dependency graph between the models and run the simulation in the correct order. When running a simulation with [`run!`](@ref), the models are then executed following this simple set of rules:

1. Independent models are run first. A model is independent if it can be run independently from other models, only using initializations (or nothing).
2. Then, models that have a dependency on other models are run. The first ones are the ones that depend on an independent model. Then the ones that are children of the second ones, and then their children ... until no children are found anymore. There are two types of children models (*i.e.* dependencies): hard and soft dependencies:
   1. Hard dependencies are always run before soft dependencies. A hard dependency is a model that is directly called by another model. It is declared as such by its parent that lists its hard-dependencies as `dep`. See [this example](https://github.com/VirtualPlantLab/PlantSimEngine.jl/blob/3d91bb053ddbd087d38dcffcedd33a9db35a0fcc/examples/dummy.jl#L39) that shows `Process2Model` defining a hard dependency on any model that simulates `process1`.
   2. Soft dependencies are then run sequentially. A model has a soft dependency on another model if one or more of its inputs is computed by another model. If a soft dependency has several parent nodes (*e.g.* two different models compute two inputs of the model), it is run only if all its parent nodes have been run already. In practice, when we visit a node that has one of its parent that did not run already, we stop the visit of this branch. The node will eventually be visited from the branch of the last parent that was run.

## Multi-rate model configuration (experimental)

For multiscale simulations, model usage is configured in the mapping through `ModelSpec` transforms:

- `TimeStepModel(...)`: sets model execution clock.
- `InputBindings(...)`: sets producer, source variable, optional source scale, and policy for each consumer input.
- `MeteoBindings(...)`: sets weather aggregation rules at the model clock for meteo variables.
- `MeteoWindow(...)`: sets weather row selection strategy (`RollingWindow()` or `CalendarWindow(...)`).
- `OutputRouting(...)`: sets whether an output is canonical (`:canonical`) or stream-only (`:stream_only`).
- `ScopeModel(...)`: partitions producer streams by scope (`:global`, `:plant`, `:scene`, `:self`) for multi-entity simulations.

If users do not provide `TimeStepModel(...)`, `MeteoBindings(...)`, or `MeteoWindow(...)`,
the runtime can infer defaults from model traits:
- `timestep_hint(::Type{<:MyModel})`
- `meteo_hint(::Type{<:MyModel})`

If users do not provide `InputBindings(...)`, runtime infers same-name bindings:
- first from a unique producer at the same scale;
- otherwise from a unique producer at another scale;
- if no producer exists, input stays unresolved (so initialization/forced values can be used);
- if multiple producers are possible, runtime errors and asks for explicit `InputBindings(...)`.

For timestep hints:
- `Dates.FixedPeriod` sets a fixed inferred timestep, e.g. `Dates.Day(1)`.
- `(min_period, max_period)` sets a required range. For models with only range hints,
  runtime computes a consensus (default: finest feasible period in the intersection).
- Explicit `TimeStepModel(...)` always takes precedence.

For meteo hints:
- return `(; bindings=..., window=...)` where `bindings` matches `MeteoBindings(...)`
  and `window` matches `MeteoWindow(...)`.
- Explicit `MeteoBindings(...)` / `MeteoWindow(...)` always take precedence.

Inspection helpers:
- `resolved_model_specs(mapping)` returns resolved specs after inference/validation.
- `explain_model_specs(mapping_or_sim)` prints a compact summary (`timestep`,
  `input_bindings`, `meteo_bindings`, `meteo_window`) for each model process.

Policy parameterization:
- `Integrate()` defaults to `SumReducer()`; you can pass another reducer, e.g. `Integrate(MeanReducer())` or `Integrate(vals -> maximum(vals) - minimum(vals))`.
- `Aggregate()` defaults to `MeanReducer()`; you can pass reducers such as `Aggregate(MaxReducer())`.
- `Interpolate()` defaults to `mode=:linear, extrapolation=:linear`; use `Interpolate(; mode=:hold, extrapolation=:hold)` for hold behavior.
- The same reducer objects are reused by meteo sampling (`MeteoBindings`) and by windowed policies (`Integrate`, `Aggregate`).

`TimeStepModel(...)` accepts either step counts (`Real`), `ClockSpec`, or fixed `Dates` periods
(for example `Dates.Hour(1)`, `Dates.Day(1)`). Fixed periods are converted internally using
the meteo base timestep duration.

Developer note on period conversion:
- Runtime time is indexed on a 1-based timeline (`t = 1, 2, 3, ...`).
- `TimeStepModel(Dates.Day(1))` is converted to a clock step count using:
  `dt = day_seconds / meteo_step_seconds`.
- For hourly meteo (`duration = Dates.Hour(1)`), this gives `dt = 24` and the default phase is `1`,
  so the model runs at `t = 1, 25, 49, ...`.
- This is equivalent to `ClockSpec(24.0, 1.0)`.
- If you need runs at `t = 24, 48, 72, ...`, set an explicit phase with `ClockSpec(24.0, 0.0)`.

Typical pipeline form:

```julia
ModelSpec(MyModel()) |>
TimeStepModel(ClockSpec(24.0, 1.0)) |>
MeteoWindow(CalendarWindow(:day; anchor=:current_period, week_start=1, completeness=:strict)) |>
MeteoBindings(; T=MeanWeighted()) |>
InputBindings(; x=(process=:producer, var=:y, policy=HoldLast())) |>
OutputRouting(; z=:stream_only)
```

### Calendar-aligned meteo windows

`MeteoWindow(...)` controls how rows are selected before reducers are applied:
- `RollingWindow()` (default): trailing window based on `dt` (for example "last 24 steps").
- `CalendarWindow(period; anchor, week_start, completeness)`:
: `period` in `:day`, `:week`, `:month`
: `anchor` in `:current_period`, `:previous_complete_period`
: `week_start` in `1:7` (1 = Monday)
: `completeness` in `:allow_partial`, `:strict`

`CalendarWindow(:day; anchor=:current_period, ...)` guarantees that a model running inside a day sees
aggregates over that civil day (including later timesteps from that day when available).

### Hold-last coupling (default policy)

```julia
mapping = ModelMapping(
    "Leaf" => (
        ModelSpec(LeafSourceModel()) |> TimeStepModel(1.0),
        ModelSpec(LeafConsumerModel()) |>
        TimeStepModel(ClockSpec(2.0, 1.0)) |>
        InputBindings(; C=(process=:leafsource, var=:S)),
    ),
)
```

### Daily integration from hourly stream

```julia
mapping = ModelMapping(
    "Leaf" => (
        ModelSpec(HourlyAssimModel()) |> TimeStepModel(1.0),
    ),
    "Plant" => (
        ModelSpec(DailyCarbonOfferModel()) |>
        TimeStepModel(ClockSpec(24.0, 1.0)) |>
        InputBindings(; A=(process=:hourlyassim, var=:A, scale="Leaf", policy=Integrate())),
    ),
)
```

### Interpolate slow producer to fast consumer

```julia
mapping = ModelMapping(
    "Leaf" => (
        ModelSpec(SlowSourceModel()) |> TimeStepModel(ClockSpec(2.0, 1.0)),
        ModelSpec(FastConsumerModel()) |>
        TimeStepModel(1.0) |>
        InputBindings(; X=(process=:slowsource, var=:X, policy=Interpolate())),
    ),
)
```

When `multirate=true` is passed to `run!`, the runtime resolves inputs from producer temporal streams according to these policies.
Meteo rows are also sampled at each model clock. By default, meteo variables are aggregated from
the finest weather step (for example `T` and `Rh` as weighted means, `Tmin/Tmax`, and radiation
quantity aliases such as `Ri_SW_q` in MJ m-2). You can override these rules with `MeteoBindings(...)`
on each `ModelSpec`.

### Current limitations

- Multi-rate MTG runs currently execute sequentially. Passing `executor=ThreadedEx()` or `executor=DistributedEx()` falls back to sequential execution with a warning.
- Sub-step execution is currently unsupported: model timesteps shorter than the meteo base step (for example `TimeStepModel(Dates.Minute(30))` with hourly meteo) raise an error.

## Multi-rate output export (experimental)

You can export selected variables at a requested rate from temporal streams:

```julia
req = OutputRequest("Leaf", :carbon_assimilation;
    name=:A_daily,
    process=:toyassim,
    policy=Integrate(),
    clock=ClockSpec(24.0, 1.0)
)

run!(sim, meteo; multirate=true, tracked_outputs=[req], executor=SequentialEx())
exported = collect_outputs(sim; sink=DataFrame)
```

`tracked_outputs` accepts `OutputRequest` values for these resampled exports.
You can also return them directly from `run!`:

```julia
out_status, exported = run!(
    sim,
    meteo;
    multirate=true,
    tracked_outputs=[req],
    return_requested_outputs=true,
)
```

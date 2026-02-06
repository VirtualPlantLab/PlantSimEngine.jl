# Model execution

## Simulation order

`PlantSimEngine.jl` uses the [`ModelList`](@ref) to automatically compute a dependency graph between the models and run the simulation in the correct order. When running a simulation with [`run!`](@ref), the models are then executed following this simple set of rules:

1. Independent models are run first. A model is independent if it can be run independently from other models, only using initializations (or nothing).
2. Then, models that have a dependency on other models are run. The first ones are the ones that depend on an independent model. Then the ones that are children of the second ones, and then their children ... until no children are found anymore. There are two types of children models (*i.e.* dependencies): hard and soft dependencies:
   1. Hard dependencies are always run before soft dependencies. A hard dependency is a model that is directly called by another model. It is declared as such by its parent that lists its hard-dependencies as `dep`. See [this example](https://github.com/VirtualPlantLab/PlantSimEngine.jl/blob/3d91bb053ddbd087d38dcffcedd33a9db35a0fcc/examples/dummy.jl#L39) that shows `Process2Model` defining a hard dependency on any model that simulates `process1`.
   2. Soft dependencies are then run sequentially. A model has a soft dependency on another model if one or more of its inputs is computed by another model. If a soft dependency has several parent nodes (*e.g.* two different models compute two inputs of the model), it is run only if all its parent nodes have been run already. In practice, when we visit a node that has one of its parent that did not run already, we stop the visit of this branch. The node will eventually be visited from the branch of the last parent that was run.

## Multi-rate model configuration (experimental)

For multiscale simulations, model usage is configured in the mapping through `ModelSpec` transforms:

- `TimeStepModel(...)`: sets model execution clock.
- `InputBindings(...)`: sets producer, source variable, optional source scale, and policy for each consumer input.
- `OutputRouting(...)`: sets whether an output is canonical (`:canonical`) or stream-only (`:stream_only`).

Policy parameterization:
- `Integrate()` defaults to `:sum`; you can pass another reducer, e.g. `Integrate(:mean)` or `Integrate(vals -> maximum(vals) - minimum(vals))`.
- `Aggregate()` defaults to `:mean`; you can pass reducers such as `Aggregate(:max)`.
- `Interpolate()` defaults to `mode=:linear, extrapolation=:linear`; use `Interpolate(; mode=:hold, extrapolation=:hold)` for hold behavior.

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
InputBindings(; x=(process=:producer, var=:y, policy=HoldLast())) |>
OutputRouting(; z=:stream_only)
```

### Hold-last coupling (default policy)

```julia
mapping = Dict(
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
mapping = Dict(
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
mapping = Dict(
    "Leaf" => (
        ModelSpec(SlowSourceModel()) |> TimeStepModel(ClockSpec(2.0, 1.0)),
        ModelSpec(FastConsumerModel()) |>
        TimeStepModel(1.0) |>
        InputBindings(; X=(process=:slowsource, var=:X, policy=Interpolate())),
    ),
)
```

When `multirate=true` is passed to `run!`, the runtime resolves inputs from producer temporal streams according to these policies.

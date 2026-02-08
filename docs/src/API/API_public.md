# Public API

## Index

```@index
Pages = ["API_public.md"]
```

## API documentation

```@autodocs
Modules = [PlantSimEngine]
Private = false
```

## Multi-rate policy examples

For mapping-level multi-rate configuration, combine:

- `ModelSpec(...)`
- `TimeStepModel(...)`
- `InputBindings(...)`
- `MeteoBindings(...)`
- `OutputRouting(...)`
- `ScopeModel(...)`
- `OutputRequest(...)` in `tracked_outputs` for resampled exports

`TimeStepModel(...)` accepts:
- `Real` step counts
- `ClockSpec`
- fixed `Dates` periods (`Dates.Second`, `Dates.Minute`, `Dates.Hour`, `Dates.Day`, ...)

Period conversion detail:
- Period-based timesteps are converted using the meteo base step `duration`.
- Example: `TimeStepModel(Dates.Day(1))` with hourly meteo (`Dates.Hour(1)`) maps to `ClockSpec(24.0, 1.0)`,
  so execution times are `t = 1, 25, 49, ...`.

Scope selection detail:
- `ScopeModel(:global)` is the default and shares streams across the whole simulation.
- `ScopeModel(:plant)` isolates streams within each plant subtree.
- `ScopeModel(:scene)` isolates by scene ancestor.
- `ScopeModel(:self)` isolates by node id.

### Exporting variables at requested rates

```julia
req_hold = OutputRequest("Leaf", :A; name=:A_hourly, process=:assim, policy=HoldLast())
req_day = OutputRequest("Leaf", :A; name=:A_daily_sum, process=:assim, policy=Integrate(), clock=ClockSpec(24.0, 1.0))
run!(sim, meteo; multirate=true, tracked_outputs=[req_hold, req_day], executor=SequentialEx())
out = collect_outputs(sim; sink=DataFrame)

# or directly:
out_status, out = run!(
    sim,
    meteo;
    multirate=true,
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
TimeStepModel(ClockSpec(2.0, 1.0)) |>
InputBindings(; x=(process=:producer, var=:x))
```

### Meteo aggregation bindings

```julia
ModelSpec(DailyModel()) |>
TimeStepModel(ClockSpec(24.0, 1.0)) |>
MeteoBindings(
    T=MeanWeighted(),                     # default source is :T
    Ri_SW_f=RadiationEnergy(),            # integrate W m-2 to MJ m-2 over the model window
    custom_peak=(source=:custom_var, reducer=MaxReducer()),
)
```

### Parameterized window reducers

`Integrate()` defaults to `SumReducer()`; `Aggregate()` defaults to `MeanReducer()`.

```julia
ModelSpec(DailyModel()) |>
TimeStepModel(ClockSpec(24.0, 1.0)) |>
InputBindings(; a=(process=:hourly_assim, var=:A, scale="Leaf", policy=Integrate(SumReducer())))

ModelSpec(DailyModel()) |>
TimeStepModel(ClockSpec(24.0, 1.0)) |>
InputBindings(; a=(process=:hourly_assim, var=:A, scale="Leaf", policy=Aggregate(MaxReducer())))

ModelSpec(DailyModel()) |>
TimeStepModel(ClockSpec(24.0, 1.0)) |>
InputBindings(; a=(process=:hourly_assim, var=:A, scale="Leaf", policy=Integrate(vals -> maximum(vals) - minimum(vals))))
```

Built-in reducer types are:
`SumReducer()`, `MeanReducer()`, `MaxReducer()`, `MinReducer()`, `FirstReducer()`, `LastReducer()`.
The same reducer objects are also used by `MeteoBindings(...)`.

### Parameterized interpolation mode

`Interpolate()` defaults to `mode=:linear, extrapolation=:linear`.

```julia
ModelSpec(FastModel()) |>
TimeStepModel(1.0) |>
InputBindings(; x=(process=:slow_source, var=:x, policy=Interpolate()))

ModelSpec(FastModel()) |>
TimeStepModel(1.0) |>
InputBindings(; x=(process=:slow_source, var=:x, policy=Interpolate(; mode=:hold, extrapolation=:hold)))
```

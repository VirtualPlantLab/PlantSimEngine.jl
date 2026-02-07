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
- `OutputRouting(...)`
- `ScopeModel(...)`
- `OutputRequest(...)` with `collect_outputs(...)` for resampled exports

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
out = collect_outputs(sim, [req_hold, req_day]; sink=DataFrame)
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

### Parameterized window reducers

`Integrate()` defaults to `:sum`; `Aggregate()` defaults to `:mean`.

```julia
ModelSpec(DailyModel()) |>
TimeStepModel(ClockSpec(24.0, 1.0)) |>
InputBindings(; a=(process=:hourly_assim, var=:A, scale="Leaf", policy=Integrate(:sum)))

ModelSpec(DailyModel()) |>
TimeStepModel(ClockSpec(24.0, 1.0)) |>
InputBindings(; a=(process=:hourly_assim, var=:A, scale="Leaf", policy=Aggregate(:max)))

ModelSpec(DailyModel()) |>
TimeStepModel(ClockSpec(24.0, 1.0)) |>
InputBindings(; a=(process=:hourly_assim, var=:A, scale="Leaf", policy=Integrate(vals -> maximum(vals) - minimum(vals))))
```

Supported reducer symbols are:
`:sum`, `:mean`, `:max`, `:min`, `:first`, `:last`.

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

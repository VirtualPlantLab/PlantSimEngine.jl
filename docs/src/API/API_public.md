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

`TimeStepModel(...)` accepts:
- `Real` step counts
- `ClockSpec`
- fixed `Dates` periods (`Dates.Second`, `Dates.Minute`, `Dates.Hour`, `Dates.Day`, ...)

Period conversion detail:
- Period-based timesteps are converted using the meteo base step `duration`.
- Example: `TimeStepModel(Dates.Day(1))` with hourly meteo (`Dates.Hour(1)`) maps to `ClockSpec(24.0, 1.0)`,
  so execution times are `t = 1, 25, 49, ...`.

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

# Changelog

## v0.14.0

Changes in this section are based on the git history since [`v0.13.2`](https://github.com/VirtualPlantLab/PlantSimEngine.jl/releases/tag/v0.13.2), corresponding to the GitHub compare view for [`v0.14.0`](https://github.com/VirtualPlantLab/PlantSimEngine.jl/compare/v0.13.2...v0.14.0).

### Summary

This release introduces first-class multi-rate execution for MTG simulations.
The main addition is a new configuration layer around `ModelMapping` and
`ModelSpec`, making it possible to run models at different cadences in the same
simulation, define how inputs and weather are resampled across rates, and export
derived time series at requested clocks.

The release also consolidates mapping APIs, improves validation and
introspection, updates the package to the newer MultiScaleTreeGraph release,
and substantially expands the documentation.

### Breaking changes

The main user-facing breaking change in this release is the move toward
`Symbol`-based scale names in mappings and multi-scale configuration. Code that
still uses string scales such as `"Leaf"` or `"Plant"` should be updated to use
symbols such as `:Leaf` and `:Plant`, especially in `ModelMapping(...)`,
`MultiScaleModel(...)`, and explicit multi-rate bindings. `ModelList` is also on
the deprecation path in favor of `ModelMapping`, so this release is a good time
to migrate mapping code to the newer API.

### Added

- First-class multi-rate MTG execution support, including runtime clocks,
  temporal input resolution, weather sampling, stream publishing, scoping, and
  requested-output export.
- New multi-rate configuration building blocks:
  `ModelMapping`, `ModelSpec`, `ClockSpec`, `TimeStepModel`,
  `InputBindings`, `MeteoBindings`, `MeteoWindow`, `OutputRouting`, and
  `ScopeModel`.
- New model traits for multi-rate inference and defaults:
  `output_policy`, `timestep_hint`, and `meteo_hint`.
- New export API for resampled output streams with `OutputRequest(...)` and
  `collect_outputs(...)`.
- New debugging/introspection helpers:
  `resolved_model_specs(mapping)` and `explain_model_specs(mapping_or_sim)`.
- Support for calendar-aligned weather windows through PlantMeteo windows such
  as `CalendarWindow(:day, ...)`.
- Support for `Dates` periods in model timesteps
  (`Dates.Minute`, `Dates.Hour`, `Dates.Day`, ...), in addition to numeric steps
  and `ClockSpec`.
- `Interpolate()` as a policy for slow-to-fast couplings, alongside clarified
  `Integrate()` and `Aggregate()` behavior.
- A dedicated benchmark suite for the multi-rate implementation.
- A new multi-rate documentation track:
  [introduction](/Users/rvezy/Documents/dev/PlantSimEngine/docs/src/multirate/introduction.md),
  [step-by-step tutorial](/Users/rvezy/Documents/dev/PlantSimEngine/docs/src/multirate/multirate_tutorial.md),
  and [advanced configuration](/Users/rvezy/Documents/dev/PlantSimEngine/docs/src/multirate/advanced_configuration.md).

### Changed

- `ModelMapping` is now the canonical mapping type for both single-scale and
  multiscale usage. It replaces the old "plain `Dict` for multiscale,
  `ModelList` for single-scale" split.
- Multi-rate execution is now inferred from the mapping/runtime configuration.
  The old explicit `multirate=true` flag has been removed.
- Runtime timestep resolution is now explicit and consistent:
  `ModelSpec.timestep` > non-default `timespec(model)` > meteo base timestep.
- Input-source inference is more capable and more predictable:
  same-scale unique producers are preferred, mapped variables participate in
  inference, and the runtime gives better errors when ambiguity remains.
- Multi-rate weather aggregation now relies on PlantMeteo’s sampling APIs and
  default transforms for common `Atmosphere` variables.
- Same-rate hard dependencies no longer require the explicit multi-rate
  machinery that slower/faster couplings need.
- Scale names are moving toward `Symbol` consistently across the API and docs.
- Package compatibility was updated to newer core dependencies:
  Julia `1.10`, `MultiScaleTreeGraph = 0.15.1`, `PlantMeteo = 0.8.2`,
  `Term = 2`.

### Deprecated

- `run!(::ModelList, ...)` is deprecated. Use `run!(ModelMapping(...), ...)`
  instead.
- `run!` with collections of `ModelList` is deprecated. Use collections of
  `ModelMapping` instead.
- `run!(mtg, mapping::AbstractDict, ...)` is deprecated. Construct a
  `ModelMapping(...)` first, or call `run!(mtg, ModelMapping(mapping), ...)`.
- String scale names are deprecated in multi-scale mapping APIs. Use `Symbol`
  scales such as `:Leaf` instead of `"Leaf"`.
- `ModelList` remains available for now but is being phased out in favor of
  `ModelMapping`.

### Migration guide

#### 1. Replace ad hoc mappings with `ModelMapping`

If you previously used `ModelList(...)` directly for single-scale runs, or a
plain `Dict` for MTG runs, migrate to `ModelMapping(...)`.

Before:

```julia
leaf = ModelList(
    process1 = Process1Model(),
    process2 = Process2Model(),
    status = (x = 1.0,),
)

mapping = Dict(
    :Leaf => (ToyAssimModel(),),
    :Plant => (ToyGrowthModel(),),
)
```

After:

```julia
leaf = ModelMapping(
    process1 = Process1Model(),
    process2 = Process2Model(),
    status = (x = 1.0,),
)

mapping = ModelMapping(
    :Leaf => (ToyAssimModel(),),
    :Plant => (ToyGrowthModel(),),
)
```

#### 2. Use rate-specific behavior in `ModelSpec(...)`

When a model should run at a cadence different from the meteo, wrap it in
`ModelSpec(...)` and add the relevant transforms.

Typical pattern:

```julia
mapping = ModelMapping(
    :Leaf => (
        ModelSpec(HourlyLeafModel()) |> TimeStepModel(1.0),
    ),
    :Plant => (
        ModelSpec(DailyPlantModel()) |>
        TimeStepModel(Dates.Day(1)) |>
        InputBindings(; A=(process=:hourlyleaf, var=:A, scale=:Leaf, policy=Integrate())) |>
        MeteoBindings(; T=MeanWeighted()),
    ),
)
```

You do not always need explicit `InputBindings(...)` or `MeteoBindings(...)`:
the runtime can infer simple cases, and PlantMeteo already defines defaults for
common weather variables. But this is now the place where explicit multi-rate
behavior belongs.

#### 3. Ensure weather rows define `duration`

When meteo is provided, `duration` is now mandatory on every weather row.
Without it, PlantSimEngine cannot determine the meteo base timestep or perform
correct aggregation over coarser model clocks.

Before:

```julia
Weather([
    Atmosphere(T=20.0, Wind=1.0, Rh=0.65),
])
```

After:

```julia
Weather([
    Atmosphere(duration=Dates.Hour(1), T=20.0, Wind=1.0, Rh=0.65),
])
```

#### 4. Use `Symbol` scale names

If your mappings still use string scales, migrate them to symbols.

Before:

```julia
mapping = ModelMapping(
    "Leaf" => (ToyAssimModel(),),
)

ModelSpec(DailyPlantModel()) |>
MultiScaleModel([:A => "Leaf"])
```

After:

```julia
mapping = ModelMapping(
    :Leaf => (ToyAssimModel(),),
)

ModelSpec(DailyPlantModel()) |>
MultiScaleModel([:A => :Leaf])
```

#### 5. Prefer `OutputRequest(...)` for explicit exported clocks

If you want clean hourly/daily/weekly exports from a multi-rate simulation, use
`OutputRequest(...)` in `tracked_outputs` and optionally return them directly
from `run!`.

```julia
req = OutputRequest(:Plant, :plant_assim_d;
    name=:plant_assim_daily,
    clock=ClockSpec(24.0, 0.0),
)

out_status, exported = run!(
    mtg,
    mapping,
    meteo;
    tracked_outputs=[req],
    return_requested_outputs=true,
)
```

This is the recommended way to export resampled streams instead of manually
rebuilding them from mixed-rate internal outputs.

#### 6. Add trait defaults where they improve clarity

For reusable models, it is now often worth defining:

- `output_policy(::Type{<:MyModel})` to describe the natural aggregation rule
  for a produced variable,
- `timestep_hint(::Type{<:MyModel})` to declare valid/preferred cadences,
- `meteo_hint(::Type{<:MyModel})` to declare default weather aggregation rules.

This is optional, but it makes inference more useful and error messages more
actionable.

### Documentation

The documentation was significantly reorganized and expanded around this
release:

- multi-rate now has dedicated introduction, tutorial, and advanced pages;
- the model execution and API pages describe the new scheduling and inference
  rules;
- outdated draft pages were removed from the published docs;
- multiscale docs were refreshed to match the newer mapping APIs.

### Internal and maintenance notes

- CI and benchmark workflows were refreshed around the new multi-rate runtime.
- Downstream/benchmark setup was cleaned up as part of the release prep.
- Several doc and benchmark follow-up commits after the core implementation were
  included in this release range.

### Included pull requests

- Downstream testing CI changes by @Samuel-amap in [#154](https://github.com/VirtualPlantLab/PlantSimEngine.jl/pull/154)
- AirSpeedVelocity.jl benchmarks by @Samuel-amap in [#155](https://github.com/VirtualPlantLab/PlantSimEngine.jl/pull/155)
- Fix #144 and add to tests by @Samuel-amap in [#156](https://github.com/VirtualPlantLab/PlantSimEngine.jl/pull/156)
- Remove windows and mac from the .yml by @Samuel-amap in [#157](https://github.com/VirtualPlantLab/PlantSimEngine.jl/pull/157)
- Filter out empty status vectors by @Samuel-amap in [#160](https://github.com/VirtualPlantLab/PlantSimEngine.jl/pull/160)
- Streamline graphsim initialisation by @Samuel-amap in [#169](https://github.com/VirtualPlantLab/PlantSimEngine.jl/pull/169)
- Small addendum to the list of PlantSimEngine Julia errors, also used by @Samuel-amap in [#172](https://github.com/VirtualPlantLab/PlantSimEngine.jl/pull/172)
- Bump actions/checkout from 4 to 6 by @dependabot[bot] in [#167](https://github.com/VirtualPlantLab/PlantSimEngine.jl/pull/167)
- Use dependabot action and remove compathelper by @VEZY in [#175](https://github.com/VirtualPlantLab/PlantSimEngine.jl/pull/175)
- Unified interface for model mapping by @VEZY in [#177](https://github.com/VirtualPlantLab/PlantSimEngine.jl/pull/177)
- `ModelMapping` validations at construction by @VEZY in [#178](https://github.com/VirtualPlantLab/PlantSimEngine.jl/pull/178)
- Add `PlantSimEngine.output_policy` trait by @VEZY in [#179](https://github.com/VirtualPlantLab/PlantSimEngine.jl/pull/179)
- Upgrade to MultiScaleTreeGraph v0.15.0 by @VEZY in [#180](https://github.com/VirtualPlantLab/PlantSimEngine.jl/pull/180)
- Fix world age issues by @VEZY in [#184](https://github.com/VirtualPlantLab/PlantSimEngine.jl/pull/184)
- Implement multirate simulations - take 3 by @VEZY in [#174](https://github.com/VirtualPlantLab/PlantSimEngine.jl/pull/174)

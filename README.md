# PlantSimEngine

[![Stable](https://img.shields.io/badge/docs-stable-blue.svg)](https://VirtualPlantLab.github.io/PlantSimEngine.jl/stable)
[![Dev](https://img.shields.io/badge/docs-dev-blue.svg)](https://VirtualPlantLab.github.io/PlantSimEngine.jl/dev)
[![Build Status](https://github.com/VirtualPlantLab/PlantSimEngine.jl/actions/workflows/CI.yml/badge.svg?branch=main)](https://github.com/VirtualPlantLab/PlantSimEngine.jl/actions/workflows/CI.yml?query=branch%3Amain)
[![Coverage](https://codecov.io/gh/VirtualPlantLab/PlantSimEngine.jl/branch/main/graph/badge.svg)](https://codecov.io/gh/VirtualPlantLab/PlantSimEngine.jl)
[![ColPrac: Contributor's Guide on Collaborative Practices for Community Packages](https://img.shields.io/badge/ColPrac-Contributor's%20Guide-blueviolet)](https://github.com/SciML/ColPrac)
[![Aqua QA](https://raw.githubusercontent.com/JuliaTesting/Aqua.jl/master/badge.svg)](https://github.com/JuliaTesting/Aqua.jl)
[![DOI](https://zenodo.org/badge/571659510.svg)](https://zenodo.org/badge/latestdoi/571659510)
[![JOSS](https://joss.theoj.org/papers/137e3e6c2ddc349bec39e06bb04e4e09/status.svg)](https://joss.theoj.org/papers/137e3e6c2ddc349bec39e06bb04e4e09)

PlantSimEngine is a Julia framework for composing soil-plant-atmosphere
simulations from reusable process models.

A modeler writes generic kernels with:

- `inputs_`
- `outputs_`
- optional `dep`, `timespec`, `output_policy`, `meteo_inputs_`, and
  `meteo_outputs_` traits
- `run!(model, models, status, meteo, constants, extra)`

A simulation author assembles those kernels on objects in a scene with:

```julia
Scene
Object
ModelSpec
AppliesTo
Inputs
Calls
Updates
TimeStep
Environment
```

This is the package API for multiscale, multi-plant, soil, microclimate, and
scene-scale simulations.

## Installation

In Julia package mode:

```julia
add PlantSimEngine
```

Then:

```julia
using PlantSimEngine
```

## Quickstart

This example runs three existing toy models on one scene object:

1. `ToyDegreeDaysCumulModel` computes daily thermal time.
2. `ToyLAIModel` consumes cumulative thermal time and computes LAI.
3. `Beer` consumes LAI and meteorology to compute absorbed PAR.

```julia
using PlantSimEngine, PlantMeteo, Dates, DataFrames
using PlantSimEngine.Examples

meteo_day = read_weather(
    joinpath(pkgdir(PlantSimEngine), "examples/meteo_day.csv");
    duration=Dates.Day,
)

scene = Scene(
    Object(:scene; scale=:Scene, kind=:scene);
    applications=(
        ModelSpec(ToyDegreeDaysCumulModel(); name=:degree_days) |>
            AppliesTo(One(scale=:Scene)),

        ModelSpec(ToyLAIModel(); name=:lai) |>
            AppliesTo(One(scale=:Scene)),

        ModelSpec(Beer(0.6); name=:light_interception) |>
            AppliesTo(One(scale=:Scene)),
    ),
    environment=meteo_day,
)

sim = run!(scene; steps=30, outputs=:all)
out = collect_outputs(sim; sink=DataFrame)
first(out, 6)
```

The compiler infers the unambiguous same-object bindings from each model's
declared inputs and outputs: `ToyLAIModel` receives `TT_cu` from
`:degree_days`, and `Beer` receives `LAI` from `:lai`.

```julia
select(
    DataFrame(explain_bindings(scene)),
    :application_id,
    :input,
    :source_application_ids,
    :carrier_kind,
    :copy_semantics,
)
```

## Multi-Object Coupling

Use `Inputs(...)` when a model needs values from selected objects. This
scene-scale LAI model reads live references to the surface of every plant in
the scene:

```julia
plant_scene = Scene(
    Object(:scene; scale=:Scene, kind=:scene),
    Object(:plant_1; scale=:Plant, kind=:plant, parent=:scene,
           status=Status(surface=12.0)),
    Object(:plant_2; scale=:Plant, kind=:plant, parent=:scene,
           status=Status(surface=8.0));
    applications=(
        ModelSpec(ToyLAIfromLeafAreaModel(100.0); name=:scene_lai) |>
            AppliesTo(One(scale=:Scene)) |>
            Inputs(
                :plant_surfaces => Many(
                    scale=:Plant,
                    within=SceneScope(),
                    var=:surface,
                ),
            ),
    ),
)

run!(plant_scene)
scene_status = only(scene_objects(plant_scene; scale=:Scene)).status
(total_surface=scene_status.total_surface, LAI=scene_status.LAI)
```

Use `within=Self()` for plant-local aggregations, for example a plant
allocation model summing only the leaves inside the current plant. Use
`within=SceneScope()` for scene-wide aggregation.

## Manual Calls

Use `Calls(...)` when a parent model must directly run selected child models,
for example a scene energy-balance solver that iterates leaf temperatures:

```julia
ModelSpec(SceneEnergyBalance(); name=:scene_energy) |>
    AppliesTo(One(scale=:Scene)) |>
    Calls(
        :leaf_energy => Many(
            kind=:plant,
            scale=:Leaf,
            within=SceneScope(),
            process=:energy_balance,
        ),
        :soil => One(
            kind=:soil,
            scale=:Soil,
            within=SceneScope(),
            process=:soil_water,
        ),
    ) |>
    TimeStep(Hour(1))
```

Inside the parent model, `call_targets(extra, :leaf_energy)` returns executable
targets. `run_call!(target; publish=false)` is the default for trial
iterations, and `run_call!(target; publish=true)` publishes the accepted state.

## What PlantSimEngine Handles

- object graphs with arbitrary plant architecture;
- several plant species and repeated plant instances through templates;
- same-rate reference wiring and typed many-object carriers;
- multirate scheduling with `Dates.Period` values;
- temporal policies such as `HoldLast`, `Interpolate`, `Integrate`, and
  `Aggregate`;
- automatic global or spatial environment binding;
- mutable microclimate outputs through `meteo_outputs_`;
- growth, pruning, reparenting, and movement with binding-cache refresh;
- structured explanations for users and agents.

Useful inspection helpers include:

```julia
explain_objects(scene)
explain_scopes(scene)
explain_bindings(scene)
explain_calls(scene)
explain_environment_bindings(scene)
explain_schedule(scene)
explain_execution_plan(scene)
```

## Documentation

- [Stable documentation](https://VirtualPlantLab.github.io/PlantSimEngine.jl/stable)
- [Development documentation](https://VirtualPlantLab.github.io/PlantSimEngine.jl/dev)
- [Scene/object quickstart](https://VirtualPlantLab.github.io/PlantSimEngine.jl/dev/scene_object/quickstart/)
- [Scene/object migration guide](https://VirtualPlantLab.github.io/PlantSimEngine.jl/dev/migration_scene_object/)
- [Public API reference](https://VirtualPlantLab.github.io/PlantSimEngine.jl/dev/API/API_public/)

## Projects That Use PlantSimEngine

- [PlantBiophysics.jl](https://github.com/VEZY/PlantBiophysics.jl) for
  plant biophysical processes such as photosynthesis, conductance, energy
  fluxes, and temperature.
- [XPalm](https://github.com/PalmStudio/XPalm.jl), an experimental crop model
  for oil palm.

## Performance

PlantSimEngine keeps model kernels close to regular Julia functions while the
runtime handles dependency scheduling, object selection, temporal aggregation,
and environment sampling. On an M1 MacBook Pro, toy daily simulations run in
hundreds of microseconds, and PlantBiophysics.jl models using PlantSimEngine
have been measured much faster than equivalent implementations in typical
scientific scripting languages.

For performance-sensitive scenes, inspect the compiled representation with
`explain_execution_plan(scene)` to see homogeneous batches and concrete carrier
types.

## License And Contributions

PlantSimEngine is distributed under the MIT license. Questions and bug reports
are welcome on [GitHub issues](https://github.com/VirtualPlantLab/PlantSimEngine.jl/issues)
or the [FSPM discourse](https://fspm.discourse.group/c/software/virtual-plant-lab).

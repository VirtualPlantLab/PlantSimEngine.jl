```@meta
CurrentModule = PlantSimEngine
```

# PlantSimEngine

[![Build Status](https://github.com/VirtualPlantLab/PlantSimEngine.jl/actions/workflows/CI.yml/badge.svg?branch=main)](https://github.com/VirtualPlantLab/PlantSimEngine.jl/actions/workflows/CI.yml?query=branch%3Amain)
[![Coverage](https://codecov.io/gh/VirtualPlantLab/PlantSimEngine.jl/branch/main/graph/badge.svg)](https://codecov.io/gh/VirtualPlantLab/PlantSimEngine.jl)
[![ColPrac: Contributor's Guide on Collaborative Practices for Community Packages](https://img.shields.io/badge/ColPrac-Contributor's%20Guide-blueviolet)](https://github.com/SciML/ColPrac)
[![Aqua QA](https://raw.githubusercontent.com/JuliaTesting/Aqua.jl/master/badge.svg)](https://github.com/JuliaTesting/Aqua.jl)
[![DOI](https://zenodo.org/badge/571659510.svg)](https://zenodo.org/badge/latestdoi/571659510)
[![JOSS](https://joss.theoj.org/papers/137e3e6c2ddc349bec39e06bb04e4e09/status.svg)](https://joss.theoj.org/papers/137e3e6c2ddc349bec39e06bb04e4e09)

```@contents
Pages = ["index.md"]
Depth = 4
```

!!! warning "Configuration API migration"
    New multiscale, multi-plant, soil, scene, and microclimate scenarios should
    use the unified `Scene`/`Object` API with `AppliesTo`, `Inputs`, `Calls`,
    `Updates`, `TimeStep`, and `Environment`. See
    [Migrating To The Scene/Object API](migration_scene_object.md). Superseded
    mapping constructors and their implementation have been removed.

## Overview

`PlantSimEngine` is a Julia framework for building soil-plant-atmosphere
simulations from small process models. A modeler writes reusable kernels with
`inputs_`, `outputs_`, optional dependency traits, and `run!`. A simulation
author then assembles those kernels on objects in a `Scene`.

The current public scenario API is organized around:

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

### Models And Applications

A model is a reusable implementation of a process. A model application is one
configured use of that model in a scene: it gives the use a name, selects its
target objects, and configures its inputs, calls, timestep, and environment.

| Concept | Meaning |
|:--|:--|
| Process | The biological or physical operation, such as light interception |
| Model | An implementation of that process, such as `Beer` |
| Application | One configured use of a model in a `Scene` |
| Target | An object on which that application executes |

One application can target many objects. The same model can also be used in
several named applications with different parameters, selectors, or cadence.
During compilation, PlantSimEngine resolves each application into its concrete
`(application, object)` executions.

This means the same model can be reused on one object, many leaves, several
plant species, a shared soil object, or a scene-scale energy-balance solver
without changing the model implementation.

## Why PlantSimEngine?

- **Modular models**: each process model can be developed, tested, calibrated,
  and replaced independently.
- **Explicit coupling**: `Inputs(...)` declares value dependencies, while
  `Calls(...)` gives iterative parent solvers manual control over hard model
  calls.
- **Object-based multiscale scenes**: scales are labels on objects, so a plant
  can be described as plants, axes, internodes, leaves, roots, voxels, or any
  topology the model requires.
- **Multirate execution**: use `TimeStep(Dates.Hour(1))`,
  `TimeStep(Dates.Day(1))`, and temporal policies such as `Integrate()` or
  `HoldLast()` in the same scene.
- **Automatic environment binding**: global weather and spatial microclimate
  backends are bound through `Environment(...)` and model `meteo_inputs_` /
  `meteo_outputs_` traits.
- **Performance-oriented internals**: selectors and bindings are compiled
  before the timestep loop, same-rate inputs use references when possible, and
  homogeneous object batches are specialized.
- **Generic values**: status, model parameters, meteorology, and outputs can
  carry units, automatic-differentiation values, uncertainty wrappers, or other
  compatible Julia types.

## Installation

To install the package, enter Julia package mode by pressing `]` in the REPL,
then run:

```julia
add PlantSimEngine
```

Use it from Julia with:

```julia
using PlantSimEngine
```

## Quickstart: One Scene Object

This example runs three existing toy models on one scene object:

1. `ToyDegreeDaysCumulModel` computes daily thermal time.
2. `ToyLAIModel` consumes cumulative thermal time and computes LAI.
3. `Beer` consumes LAI and meteorology to compute absorbed PAR.

The model kernels are unchanged; the scene application layer says where they
run. Since no `TimeStep` is specified, these applications use the daily
cadence of `meteo_day`.

```@example readme
using PlantSimEngine, PlantMeteo, Dates, DataFrames
using PlantSimEngine.Examples

meteo_day = read_weather(
    joinpath(pkgdir(PlantSimEngine), "examples/meteo_day.csv");
    duration=Dates.Day,
)

scene = Scene(
    ToyDegreeDaysCumulModel(),
    ToyLAIModel(),
    Beer(0.6);
    environment=meteo_day,
)

sim = run!(scene; steps=30, outputs=:all)
out = collect_outputs(sim; sink=DataFrame)
first(out, 6)
```

`ToyLAIModel` does not know where `TT_cu` comes from, and `Beer` does not know
where `LAI` comes from. The compiler infers the unambiguous same-object
bindings from each model's declared inputs and outputs:

```@example readme
select(
    DataFrame(explain_bindings(scene)),
    :application_id,
    :input,
    :source_application_ids,
    :carrier_kind,
    :copy_semantics,
)
```

The outputs can be plotted like any other tabular result:

```@example readme
using CairoMakie

lai = out[out.variable .== :LAI, :value]
appfd = out[out.variable .== :aPPFD, :value]
tt_cu = out[out.variable .== :TT_cu, :value]

fig = Figure(resolution=(800, 600))
ax = Axis(fig[1, 1], ylabel="LAI (m² m⁻²)")
lines!(ax, tt_cu, lai, color=:mediumseagreen)

ax2 = Axis(fig[2, 1], xlabel="Cumulated growing degree days since sowing (°C)", ylabel="aPPFD (mol m⁻² d⁻¹)")
lines!(ax2, tt_cu, appfd, color=:firebrick1)
fig
```

## Multi-Object Inputs

Use `Inputs(...)` when a model needs values from selected objects. Here the
scene-scale LAI model reads live references to all plant surfaces in the scene:

```@example readme
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
scene_status
```

The same `Many(...)` selector would be plant-local if the consumer ran on a
plant and used `within=Subtree()`. This is the same mechanism used for plant
allocation models that sum their own leaves, scene models that aggregate all
plants, and microclimate solvers that select objects inside one environment
cell.

## Manual Calls For Iterative Solvers

Use `Calls(...)` when a parent model must directly run another model, for
example a scene energy-balance solver that iterates leaf temperatures until
convergence:

```julia
ModelSpec(SceneEnergyBalance(); name=:scene_energy) |>
    AppliesTo(One(scale=:Scene)) |>
    Calls(
        :leaf_energy => Many(
            kind=:plant,
            scale=:Leaf,
            within=SceneScope(),
            application=:energy_balance,
        ),
        :soil => One(
            kind=:soil,
            scale=:Soil,
            within=SceneScope(),
            application=:soil_water,
        ),
    ) |>
    TimeStep(Hour(1))
```

Inside `run!`, the parent model uses `call_targets(extra, :leaf_energy)` and
`run_call!(target; publish=false)` for trial iterations. The accepted state
uses `run_call!(target; publish=true)` once, so temporal outputs and mutable
environment writes are published exactly once.

## Where To Go Next

- [Scene/Object Quickstart](scene_object/quickstart.md) gives a compact
  runnable workflow using the new API.
- [Migrating To The Scene/Object API](migration_scene_object.md) translates
  historical `ModelMapping` and `MultiScaleModel` examples.
- [Public API](API/API_public.md) lists the scene/object constructors,
  selectors, lifecycle hooks, and explanation helpers.
- [Model traits](model_traits.md) explains `inputs_`, `outputs_`, `dep`,
  `timespec`, `output_policy`, `meteo_inputs_`, and `meteo_outputs_`.

## Performance

PlantSimEngine keeps model kernels close to regular Julia functions while the
runtime handles dependency scheduling, object selection, temporal aggregation,
and environment sampling. On an M1 MacBook Pro, toy daily simulations run in
hundreds of microseconds, and PlantBiophysics.jl models using PlantSimEngine
have been measured much faster than equivalent implementations in typical
scientific scripting languages.

For performance-sensitive scenes, inspect the supported structured
explanations:

```julia
explain_bindings(scene)
explain_schedule(scene)
explain_execution_plan(scene)
```

These helpers expose resolved objects, carriers, copy/reference semantics,
application clocks, and homogeneous execution batches.

## Ask Questions

If you have questions or feedback, [open an issue](https://github.com/VirtualPlantLab/PlantSimEngine.jl/issues)
or ask on [discourse](https://fspm.discourse.group/c/software/virtual-plant-lab).

## Projects That Use PlantSimEngine

- [PlantBiophysics.jl](https://github.com/VEZY/PlantBiophysics.jl)
- [XPalm](https://github.com/PalmStudio/XPalm.jl)

## Make It Yours

PlantSimEngine is distributed under the MIT license. If you develop a package
or model suite that uses it and want it listed here, please open a pull request
or contact the maintainers.

# PlantSimEngine

[![Stable](https://img.shields.io/badge/docs-stable-blue.svg)](https://VEZY.github.io/PlantSimEngine.jl/stable)
[![Dev](https://img.shields.io/badge/docs-dev-blue.svg)](https://VEZY.github.io/PlantSimEngine.jl/dev)
[![Build Status](https://github.com/VEZY/PlantSimEngine.jl/actions/workflows/CI.yml/badge.svg?branch=main)](https://github.com/VEZY/PlantSimEngine.jl/actions/workflows/CI.yml?query=branch%3Amain)
[![Coverage](https://codecov.io/gh/VEZY/PlantSimEngine.jl/branch/main/graph/badge.svg)](https://codecov.io/gh/VEZY/PlantSimEngine.jl)
[![ColPrac: Contributor's Guide on Collaborative Practices for Community Packages](https://img.shields.io/badge/ColPrac-Contributor's%20Guide-blueviolet)](https://github.com/SciML/ColPrac)
[![Aqua QA](https://raw.githubusercontent.com/JuliaTesting/Aqua.jl/master/badge.svg)](https://github.com/JuliaTesting/Aqua.jl)
[![DOI](https://zenodo.org/badge/571659510.svg)](https://zenodo.org/badge/latestdoi/571659510)
[![JOSS](https://joss.theoj.org/papers/137e3e6c2ddc349bec39e06bb04e4e09/status.svg)](https://joss.theoj.org/papers/137e3e6c2ddc349bec39e06bb04e4e09)


## Overview

`PlantSimEngine` is a package for the simulation and modelling of plants, soil and atmosphere. It is designed to help researchers and practitioners prototype, implement, test plant/crop models at any scale, without the hassle of computer science technicality behind model coupling, running on several time-steps or objects.

The package defines a framework for declaring processes and implementing associated models for their simulation. 

It focuses on key aspects of simulation and modeling such as: 

- easy definition of new processes, such as light interception, photosynthesis, growth, soil water transfer...
- fast, interactive prototyping of models, with constraints to help users avoid errors, but sensible defaults to avoid over-complicating the model writing process
- no hassle, the package manages automatically input and output variables, time-steps, objects, soft and hard coupling of models with a dependency graph
- switch between models without changing any code, with a simple syntax to define the model to use for a given process
- Reduce the degrees of freedom by fixing variables, passing measurements, or using a simpler model for a given process
- 🚀(very) fast computation 🚀, think of 100th of nanoseconds for the full energy balance of a leaf using [PlantBiophysics.jl](https://github.com/VEZY/PlantBiophysics.jl) that uses PlantSimEngine
- Out of the box Sequential, Parallel (Multi-threaded) or Distributed (Multi-Process) computations over objects, time-steps and independent processes (thanks to [Floops.jl](https://juliafolds.github.io/FLoops.jl/stable/))
- easily scalable, with methods for computing over objects, time-steps and even [Multi-Scale Tree Graphs](https://github.com/VEZY/MultiScaleTreeGraph.jl)
- composable, allowing the use of any types as inputs such as [Unitful](https://github.com/PainterQubits/Unitful.jl) to propagate units, or [MonteCarloMeasurements.jl](https://github.com/baggepinnen/MonteCarloMeasurements.jl) to propagate measurement error

## Installation

To install the package, enter the Julia package manager mode by pressing `]` in the REPL, and execute the following command:

```julia
add PlantSimEngine
```

To use the package, execute this command from the Julia REPL:

```julia
using PlantSimEngine
```

## Example usage

The package is designed to be easy to use, and to help users avoid errors when implementing, coupling and simulating models.

### Simple example 

Here's a simple example of a model that simulates the growth of a plant, using a simple exponential growth model:

```julia
# ] add PlantSimEngine
using PlantSimEngine

# Include the model definition from the examples folder:
include(joinpath(pkgdir(PlantSimEngine), "examples/ToyLAIModel.jl"))

# Define the model:
model = ModelList(
    ToyLAIModel(),
    status=(degree_days_cu=1.0:2000.0,), # Pass the cumulated degree-days as input to the model
)

run!(model) # run the model

status(model) # extract the status, i.e. the output of the model
```

Which gives:

```
TimeStepTable{Status{(:degree_days_cu, :LAI...}(1300 x 2):
╭─────┬────────────────┬────────────╮
│ Row │ degree_days_cu │        LAI │
│     │        Float64 │    Float64 │
├─────┼────────────────┼────────────┤
│   1 │            1.0 │ 0.00560052 │
│   2 │            2.0 │ 0.00565163 │
│   3 │            3.0 │ 0.00570321 │
│   4 │            4.0 │ 0.00575526 │
│   5 │            5.0 │ 0.00580778 │
│  ⋮  │       ⋮        │     ⋮      │
╰─────┴────────────────┴────────────╯
                    1295 rows omitted
```

> **Note**  
> The `ToyLAIModel` is available from the [examples folder](./examples/ToyLAIModel.jl), and is a simple exponential growth model. It is used here for the sake of simplicity, but you can use any model you want, as long as it follows `PlantSimEngine` interface.

Of course you can plot the outputs quite easily:

```julia
# ] add CairoMakie
using CairoMakie

lines(model[:degree_days_cu], model[:LAI], color=:green, axis=(ylabel="LAI (m² m⁻²)", xlabel="Cumulated growing degree days since sowing (°C)"))
```

![LAI Growth](examples/LAI_growth.png)

### Model coupling

Model coupling is done automatically by the package, and is based on the dependency graph between the models. To couple models, we just have to add them to the `ModelList`. For example, let's couple the `ToyLAIModel` with a model for light interception based on Beer's law:

```julia
# ] add PlantSimEngine, DataFrames, CSV
using PlantSimEngine, PlantMeteo, DataFrames, CSV

# Include the model definition from the examples folder:
include(joinpath(pkgdir(PlantSimEngine), "examples/ToyLAIModel.jl"))
include(joinpath(pkgdir(PlantSimEngine), "examples/light.jl"))

# Import the example meteorological data:
meteo_day = CSV.read(joinpath(pkgdir(PlantSimEngine), "examples/meteo_day.csv"), DataFrame, header=18)

# Define the list of models for coupling:
model = ModelList(
    ToyLAIModel(),
    Beer(0.6),
    status=(degree_days_cu=cumsum(meteo_day[:, :degree_days]),),  # Pass the cumulated degree-days as input to `ToyLAIModel`, this could also be done using another model
)
```

The `ModelList` couples the models by automatically computing the dependency graph of the models. The resulting dependency graph is:

```
╭──── Dependency graph ──────────────────────────────────────────╮
│  ╭──── LAI_Dynamic ─────────────────────────────────────────╮  │
│  │  ╭──── Main model ────────╮                              │  │
│  │  │  Process: LAI_Dynamic  │                              │  │
│  │  │  Model: ToyLAIModel    │                              │  │
│  │  │  Dep: nothing          │                              │  │
│  │  ╰────────────────────────╯                              │  │
│  │                  │  ╭──── Soft-coupled model ─────────╮  │  │
│  │                  │  │  Process: light_interception    │  │  │
│  │                  └──│  Model: Beer                    │  │  │
│  │                     │  Dep: (LAI_Dynamic = (:LAI,),)  │  │  │
│  │                     ╰─────────────────────────────────╯  │  │
│  ╰──────────────────────────────────────────────────────────╯  │
╰────────────────────────────────────────────────────────────────╯
```

```julia
# Run the simulation:
run!(model, meteo_day)

status(model)
```

Which returns:

```
TimeStepTable{Status{(:degree_days_cu, :LAI...}(365 x 3):
╭─────┬────────────────┬────────────┬───────────╮
│ Row │ degree_days_cu │        LAI │     aPPFD │
│     │        Float64 │    Float64 │   Float64 │
├─────┼────────────────┼────────────┼───────────┤
│   1 │            0.0 │ 0.00554988 │ 0.0476221 │
│   2 │            0.0 │ 0.00554988 │ 0.0260688 │
│   3 │            0.0 │ 0.00554988 │ 0.0377774 │
│   4 │            0.0 │ 0.00554988 │ 0.0468871 │
│   5 │            0.0 │ 0.00554988 │ 0.0545266 │
│  ⋮  │       ⋮        │     ⋮      │     ⋮     │
╰─────┴────────────────┴────────────┴───────────╯
                                 360 rows omitted
```

```julia
# Plot the results:
using CairoMakie

fig = Figure(resolution=(800, 600))
ax = Axis(fig[1, 1], ylabel="LAI (m² m⁻²)")
lines!(ax, model[:degree_days_cu], model[:LAI], color=:mediumseagreen)

ax2 = Axis(fig[2, 1], xlabel="Cumulated growing degree days since sowing (°C)", ylabel="aPPFD (mol m⁻² d⁻¹)")
lines!(ax2, model[:degree_days_cu], model[:aPPFD], color=:firebrick1)

fig
```

![LAI Growth and light interception](examples/LAI_growth2.png)

## Projects that use PlantSimEngine

Take a look at these projects that use PlantSimEngine:

- [PlantBiophysics.jl](https://github.com/VEZY/PlantBiophysics.jl)
- [XPalm](https://github.com/PalmStudio/XPalm.jl)

## Make it yours 

The package is developed so anyone can easily implement plant/crop models, use it freely and as you want thanks to its MIT license. 

If you develop such tools and it is not on the list yet, please make a PR or contact me so we can add it! 😃


## TO DO

- [ ] Look into locks for parallel computations over "independent" processes that can maybe call a model when both parents are being computed, so both are set to 0 and the model is never called
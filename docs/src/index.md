```@meta
CurrentModule = PlantSimEngine
```

```@setup readme
using PlantSimEngine, PlantMeteo, DataFrames, CSV

# Import the examples defined in the `Examples` sub-module:
using PlantSimEngine.Examples

# Import the example meteorological data:
meteo_day = CSV.read(joinpath(pkgdir(PlantSimEngine), "examples/meteo_day.csv"), DataFrame, header=18)

# Define the model:
model = ModelList(
    ToyLAIModel(),
    status=(TT_cu=1.0:2000.0,), # Pass the cumulated degree-days as input to the model
)

out = run!(model)

# Define the list of models for coupling:
model2 = ModelList(
    ToyLAIModel(),
    Beer(0.6),
    status=(TT_cu=cumsum(meteo_day[:, :TT]),),  # Pass the cumulated degree-days as input to `ToyLAIModel`, this could also be done using another model
)
out2 = run!(model2, meteo_day)

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
Depth = 5
```

## Overview

`PlantSimEngine` is a comprehensive framework for building models of the soil-plant-atmosphere continuum. It includes everything you need to **prototype, evaluate, test, and deploy** plant/crop models at any scale, with a strong emphasis on performance and efficiency, so you can focus on building and refining your models.

**Why choose PlantSimEngine?**

- Simplicity: Write less code, focus on your model's logic, and let the framework handle the rest.
- Modularity: Each model component can be developed, tested, and improved independently. Assemble complex simulations by reusing pre-built, high-quality modules.
- Standardisation: Clear, enforceable guidelines ensure that all models adhere to best practices. This built-in consistency means that once you implement a model, it works seamlessly with others in the ecosystem.
- Optimised Performance: Don't re-invent the wheel. Delegating low-level tasks to PlantSimEngine guarantees that your model will benefit from every improvement in the framework. Enjoy faster prototyping, robust simulations, and efficient execution using Julia’s high-performance capabilities.

## Batteries included

- Automated management of inputs, outputs, time-steps, objects, and dependency resolution.
- Iterative model development: Fast and interactive prototyping of models with built-in constraints to avoid errors and sensible defaults to streamline the model writing process.
- Control your Degrees of Freedom: Fix variables to constant values or force to observations, use simpler models for specific processes to reduce complexity.
- Flexible Model Switching: Switch between models without changing model's code, using a simple syntax to specify the model for a given process and scale.
- Achieve high-speed computations, with benchmarks showing operations in the 100th of nanoseconds range for complex models (see this [benchmark script](https://github.com/VirtualPlantLab/PlantSimEngine.jl/blob/main/examples/benchmark.jl)).
- Parallelize and Distribute Computing: Out-of-the-box support for sequential, multi-threaded, or distributed computations over objects, time-steps, and independent processes, thanks to [Floops.jl](https://juliafolds.github.io/FLoops.jl/stable/).
- Scale: Scale easily with methods for computing over objects, time-steps, and [Multi-Scale Tree Graphs](https://github.com/VEZY/MultiScaleTreeGraph.jl).
- Compose: Use any types as inputs, including [Unitful](https://github.com/PainterQubits/Unitful.jl) for unit propagation and [MonteCarloMeasurements.jl](https://github.com/baggepinnen/MonteCarloMeasurements.jl) for measurement error propagation.

## Ask Questions

If you have any questions or feedback, [open an issue](https://github.com/VirtualPlantLab/PlantSimEngine.jl/issues) or ask on [discourse](https://fspm.discourse.group/c/software/virtual-plant-lab).

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

```@example readme
# ] add PlantSimEngine
using PlantSimEngine

# Import the examples defined in the `Examples` sub-module
using PlantSimEngine.Examples

# Define the model:
model = ModelList(
    ToyLAIModel(),
    status=(TT_cu=1.0:2000.0,), # Pass the cumulated degree-days as input to the model
)

out = run!(model) # run the model and extract its outputs
```

> **Note**  
> The `ToyLAIModel` is available from the [examples folder](https://github.com/VirtualPlantLab/PlantSimEngine.jl/tree/main/examples), and is a simple exponential growth model. It is used here for the sake of simplicity, but you can use any model you want, as long as it follows `PlantSimEngine` interface.

Of course you can plot the outputs quite easily:

```@example readme
# ] add CairoMakie
using CairoMakie

lines(out[:TT_cu], out[:LAI], color=:green, axis=(ylabel="LAI (m² m⁻²)", xlabel="Cumulated growing degree days since sowing (°C)"))
```

### Model coupling

Model coupling is done automatically by the package, and is based on the dependency graph between the models. To couple models, we just have to add them to the `ModelList`. For example, let's couple the `ToyLAIModel` with a model for light interception based on Beer's law:

```@example readme
# ] add PlantSimEngine, DataFrames, CSV
using PlantSimEngine, PlantMeteo, DataFrames, CSV

# Import the examples defined in the `Examples` sub-module
using PlantSimEngine.Examples

# Import the example meteorological data:
meteo_day = CSV.read(joinpath(pkgdir(PlantSimEngine), "examples/meteo_day.csv"), DataFrame, header=18)

# Define the list of models for coupling:
model2 = ModelList(
    ToyLAIModel(),
    Beer(0.6),
    status=(TT_cu=cumsum(meteo_day[:, :TT]),),  # Pass the cumulated degree-days as input to `ToyLAIModel`, this could also be done using another model
)

# Run the simulation:
out2 = run!(model2, meteo_day)
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

We can plot the results by indexing the outputs with the variable name (e.g. `out2[:LAI]`):

```@example readme
using CairoMakie

fig = Figure(resolution=(800, 600))
ax = Axis(fig[1, 1], ylabel="LAI (m² m⁻²)")
lines!(ax, out2[:TT_cu], out2[:LAI], color=:mediumseagreen)

ax2 = Axis(fig[2, 1], xlabel="Cumulated growing degree days since sowing (°C)", ylabel="aPPFD (mol m⁻² d⁻¹)")
lines!(ax2, out2[:TT_cu], out2[:aPPFD], color=:firebrick1)

fig
```

### Multiscale modelling

> See the [Multi-scale modeling](#multi-scale-modeling) section for more details.

The package is designed to be easily scalable, and can be used to simulate models at different scales. For example, you can simulate a model at the leaf scale, and then couple it with models at any other scale, *e.g.* internode, plant, soil, scene scales. Here's an example of a simple model that simulates plant growth using sub-models operating at different scales:

```@example readme
mapping = Dict(
    "Scene" => ToyDegreeDaysCumulModel(),
    "Plant" => (
        MultiScaleModel(
            model=ToyLAIModel(),
            mapped_variables=[
                :TT_cu => "Scene",
            ],
        ),
        Beer(0.6),
        MultiScaleModel(
            model=ToyAssimModel(),
            mapped_variables=[:soil_water_content => "Soil"],
        ),
        MultiScaleModel(
            model=ToyCAllocationModel(),
            mapped_variables=[
                :carbon_demand => ["Leaf", "Internode"],
                :carbon_allocation => ["Leaf", "Internode"]
            ],
        ),
        MultiScaleModel(
            model=ToyPlantRmModel(),
            mapped_variables=[:Rm_organs => ["Leaf" => :Rm, "Internode" => :Rm],],
        ),
    ),
    "Internode" => (
        MultiScaleModel(
            model=ToyCDemandModel(optimal_biomass=10.0, development_duration=200.0),
            mapped_variables=[:TT => "Scene",],
        ),
        MultiScaleModel(
            model=ToyInternodeEmergence(TT_emergence=20.0),
            mapped_variables=[:TT_cu => "Scene"],
        ),
        ToyMaintenanceRespirationModel(1.5, 0.06, 25.0, 0.6, 0.004),
        Status(carbon_biomass=1.0)
    ),
    "Leaf" => (
        MultiScaleModel(
            model=ToyCDemandModel(optimal_biomass=10.0, development_duration=200.0),
            mapped_variables=[:TT => "Scene",],
        ),
        ToyMaintenanceRespirationModel(2.1, 0.06, 25.0, 1.0, 0.025),
        Status(carbon_biomass=1.0)
    ),
    "Soil" => (
        ToySoilWaterModel(),
    ),
);
nothing # hide
```

We can import an example plant from the package:

```@example readme
mtg = import_mtg_example()
```

Make a fake meteorological data:

```@example readme
meteo = Weather(
    [
    Atmosphere(T=20.0, Wind=1.0, Rh=0.65, Ri_PAR_f=300.0),
    Atmosphere(T=25.0, Wind=0.5, Rh=0.8, Ri_PAR_f=500.0)
]
);
nothing # hide
```

And run the simulation:

```@example readme
out_vars = Dict(
    "Scene" => (:TT_cu,),
    "Plant" => (:carbon_allocation, :carbon_assimilation, :soil_water_content, :aPPFD, :TT_cu, :LAI),
    "Leaf" => (:carbon_demand, :carbon_allocation),
    "Internode" => (:carbon_demand, :carbon_allocation),
    "Soil" => (:soil_water_content,),
)

out = run!(mtg, mapping, meteo, tracked_outputs=out_vars, executor=SequentialEx());
nothing # hide
```

We can then extract the outputs in a `DataFrame` and sort them:

```@example readme
using DataFrames
df_out = convert_outputs(out, DataFrame)
sort!(df_out, [:timestep, :node])
```

An example output of a multiscale simulation is shown in the documentation of PlantBiophysics.jl:

![Plant growth simulation](www/image.png)

## Projects that use PlantSimEngine

Take a look at these projects that use PlantSimEngine:

- [PlantBiophysics.jl](https://github.com/VEZY/PlantBiophysics.jl)
- [XPalm](https://github.com/PalmStudio/XPalm.jl)

## Make it yours

The package is developed so anyone can easily implement plant/crop models, use it freely and as you want thanks to its MIT license.

If you develop such tools and it is not on the list yet, please make a PR or contact me so we can add it! 😃

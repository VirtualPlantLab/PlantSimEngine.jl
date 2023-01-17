# PlantSimEngine

[![Stable](https://img.shields.io/badge/docs-stable-blue.svg)](https://VEZY.github.io/PlantSimEngine.jl/stable)
[![Dev](https://img.shields.io/badge/docs-dev-blue.svg)](https://VEZY.github.io/PlantSimEngine.jl/dev)
[![Build Status](https://github.com/VEZY/PlantSimEngine.jl/actions/workflows/CI.yml/badge.svg?branch=main)](https://github.com/VEZY/PlantSimEngine.jl/actions/workflows/CI.yml?query=branch%3Amain)
[![Coverage](https://codecov.io/gh/VEZY/PlantSimEngine.jl/branch/main/graph/badge.svg)](https://codecov.io/gh/VEZY/PlantSimEngine.jl)
[![ColPrac: Contributor's Guide on Collaborative Practices for Community Packages](https://img.shields.io/badge/ColPrac-Contributor's%20Guide-blueviolet)](https://github.com/SciML/ColPrac)
[![Aqua QA](https://raw.githubusercontent.com/JuliaTesting/Aqua.jl/master/badge.svg)](https://github.com/JuliaTesting/Aqua.jl)
[![DOI](https://zenodo.org/badge/571659510.svg)](https://zenodo.org/badge/latestdoi/571659510)

WIP package that enforce a single API for models related to plants, soil and atmosphere. It helps defining and running processes with any implementation (*i.e.* model), at any scale.

## Overview

`PlantSimEngine` defines a framework for declaring processes and implementing associated models for their simulation. The package focuses on key aspects of simulation and modelling:

- easy definition of new processes, which can really be any process such as light interception, photosynthesis, growth, soil water transfer...
- easy, interactive prototyping of models, with constraints to help users avoid errors, but sensible defaults to avoid over-complicating the model writing process
- no hassle, the package manages automatically input and output variables, time-steps, objects, model coupling, and model switching
- (very) fast computing, think of 100th of nanoseconds for the full energy balance of a leaf (see [PlantBiophysics.jl](https://github.com/VEZY/PlantBiophysics.jl) that uses PlantSimEngine)
- easily scalable, with methods for computing over objects, time-steps and even [Multi-Scale Tree Graphs](https://github.com/VEZY/MultiScaleTreeGraph.jl)
- composable: use [Unitful](https://github.com/PainterQubits/Unitful.jl) to propagate units, use [MonteCarloMeasurements.jl](https://github.com/baggepinnen/MonteCarloMeasurements.jl) to propagate measurement error

## Installation

To install the package, enter the Julia package manager mode by pressing `]` in the REPL, and execute the following command:

```julia
add PlantSimEngine
```

To use the package, execute this command from the Julia REPL:

```julia
using PlantSimEngine
```

## Projects that use PlantSimEngine

Take a look at these projects that use PlantSimEngine:

- [PlantBiophysics.jl](https://github.com/VEZY/PlantBiophysics.jl)
- [XPalm](https://github.com/PalmStudio/XPalm.jl)

## Make it yours 

The package is developed so anyone can easily implement plant/crop models, use it freely and as you want thanks to its MIT license. 

If you develop such tools and it is not on the list yet, please make a PR or contact me so we can add it! 😃

## More details

Defining a new processes is done with `@gen_gen_process_methods`, which creates automatically:

- the base function of the process, *e.g.* `energy_balance!_()`
- the user interfaces, *e.g.* `energy_balance!()` and `energy_balance()`
- the abstract process type, used as a supertype of all models implementations, *e.g.* `AbstractEnergy_BalanceModel`
- the documentation for all the above
- a basic tutorial on how to make a model implementation 

Then, modelers are encouraged to implement their models to simulate the process following a set of basic simple rules enforced by the package.  

You'll find more details on the documentation of the package.
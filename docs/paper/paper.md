---
title: "PlantSimEngine: A Simulation Engine For The Soil-Plant-Atmosphere System"
tags:
  - Julia
  - agronomy
  - crops
  - fspm
  - functional-structural plant modeling
  - plants
  - modelling
authors:
  - name: Rémi Vezy
    orcid: 0000-0002-0808-1461
    affiliation: "1, 2" # (Multiple affiliations must be quoted)
affiliations:
 - name: CIRAD, UMR AMAP, F-34398 Montpellier, France.
   index: 1
 - name: AMAP, Univ Montpellier, CIRAD, CNRS, INRAE, IRD, Montpellier, France.
   index: 2
date: 10 February 2023
bibliography: paper.bib
---

# Summary

`PlantSimEngine` is a package for the simulation and modelling of plants, soil and atmosphere, with a focus on ease of use and computational efficiency. It is designed to help researchers and practitioners prototype, implement and evaluate plant or crop models at any scale, without the hassle of technical computer science details. The package defines a framework for declaring processes and implementing associated models for their simulation, with key features including but not limited to:

- easy definition of new processes, such as light interception, photosynthesis, growth, soil water transfer...
- fast, interactive prototyping of models, with constraints to help users avoid errors, but sensible defaults to avoid over-complicating the model writing process
- no hassle, the package manages automatically input and output variables, time-steps, objects, coupling of models with a dependency graph
- switch between models without changing any code, with a simple syntax to define the model to use for a given process
- Reduce the degrees of freedom by fixing variables, passing measurements, or using a simpler model for a given process
- fast computation, with 100th of nanoseconds for the full energy balance of a leaf using [PlantBiophysics.jl](https://github.com/VEZY/PlantBiophysics.jl) [@vezy_vezyplantbiophysicsjl_2023], a package that uses PlantSimEngine
- Out of the box sequential, parallel (multi-threaded) or distributed (multi-process) computations over objects, time-steps and independent processes (thanks to [Floops.jl](https://juliafolds.github.io/FLoops.jl/stable/))
- easily scalable, with methods for computing over objects, time-steps and even [Multi-Scale Tree Graphs](https://github.com/VEZY/MultiScaleTreeGraph.jl) [@vezy_multiscaletreegraphjl_2023]
- composable, allowing the use of any types as inputs such as [Unitful](https://github.com/PainterQubits/Unitful.jl) to propagate units, or [MonteCarloMeasurements.jl](https://github.com/baggepinnen/MonteCarloMeasurements.jl) [@carlson_montecarlomeasurementsjl_2020] to propagate measurement error

# Statement of need

There is a growing demand for robust and efficient tools for simulating and modeling plants, soil and atmosphere in the scientific community. Most often, models are defined by agronomists, plant or soil scientists, who are not necessarily familiar with the intricacies of computer science such as computational performance, parallelization, management of time-steps and objects. 

Models are developed either in interpreted programming languages for easier and faster prototyping, or in compiled languages for faster computation. However, interpreted languages are often slow, and compiled languages are slow to prototype in. Furthermore, the development of models is often an iterative, time-consuming process that requires hypothesis testing and frequent switch between models for comparing their different versions. It also requires unit testing to ensure that the implementation is correct, and integration testing to evaluate the model within its framework. 

This process is often tedious and error-prone, and requires a lot of time and effort. The need for a tool that can help researchers and practitioners prototype, implement and evaluate plant or crop models at any scale, without the hassle of technical computer science details, is therefore clear.

PlantSimEngine addresses this need by providing a flexible and user-friendly framework for declaring processes and implementing models for their simulation. The package focuses on key aspects of simulation and modeling, such as ease of definition of new processes, fast and interactive prototyping of models, streamlined management of input and output variables, and the ability to switch between models without changing any underlying code. It also provides a way to test the models or forcing processes to observations to reduce the number of degrees of freedom. It also offers fast computation, scalability, and composability, making it ideal for developing Functional-Structural Plant Models (FSPMs) and crop models. For example the simulation of a toy model for leaf area over a year at daily time-scale took 309 μs to perform (*i.e.* 851 ns per day) on an M1 MacBook Pro 14, and 358 ns when coupled to a model for light interception based on the Beer-Lambert law of light extinction ([see provided benchmark script](https://github.com/VEZY/PlantSimEngine.jl/blob/main/examples/benchmark.jl)), which shows that PlantSimEngine scales well with several models. These performance are on par with what could be expected if the package was developed using a compiled language such as Fortran or C, and is by far faster than any interpreted language implementation.

The idea behind the innovative features of PlantSimEngine is to enable users to accurately model, predict and analyze the behavior of complex processes to improve decision making and optimize process design.

# State of the field

PlantSimEngine is a state-of-the-art plant simulation platform that offers significant advantages or different pattern designs over existing tools such as OpenAlea [@pradal_openalea_2008], STICS [@brisson_stics_1998], APSIM [@brown_plant_2014; @holzworth_apsim_2014] or DSSAT [@jones_dssat_2003].

The use of Julia programming language in PlantSimEngine allows for quick and easy prototyping of models compared to compiled languages (STICS, APSIM, DSSAT) and can achieve significantly better performance than typical interpreted languages (*e.g.* Python used in OpenAlea), without the need for translation into another compiled language. For example PlantBiophysics.jl, a Julia package that implements ecophysiological models using PlantSimEngine.jl is [38649 times faster](https://vezy.github.io/PlantBiophysics-paper/notebooks_performance_Fig5_PlantBiophysics_performance/) than the same implementation in R in plantecophys [@duursma_plantecophys_2015].

Most of the nice features of the package are provided by the Julia programming language, which is a high-level, high-performance, dynamic programming language used in many scientific fields and particularly well fitted for modelling in biology [@roesch_julia_2023].

The automatic computation of the dependency graph of models and the uniform API enables users to switch models without having to modify any underlying code. This is a significant advantage over existing tools for the development of complex soil-plant-atmosphere models. For example OpenAlea provides a way to build a dependency tree for soft-dependencies, *i.e.* independent models that are coupled via inputs and outputs, but not for hard-dependencies, *i.e.* models that make an explicit, hard-coded call to another model. PlantSimEngine leverages Julia's multiple-dispatch to automatically compute the full dependency graph at compile time, including hard-dependencies. PlantSimEngine also offers a simple and generic API to define methods for model calibration that are used to programmatically calibrate models and sub-models.

Additionally, PlantSimEngine offers the ability to reduce the number of degrees of freedom by fixing variables, passing measurements, or using a simpler model for a given process, making it an easier and more flexible solution for plant simulation.

PlantSimEngine's approach streamlines the process of model development by automatically managing model coupling, time-steps, parallelization, input and output variables, and the type of objects used for simulations (vectors, dictionaries, and multi-scale tree graphs).

# Mention

PlantSimEngine is used in the following packages:

- [PlantBiophysics.jl](https://github.com/VEZY/PlantBiophysics.jl), for the simulation of biophysical processes for plants such as photosynthesis, conductance for heat, water vapor and CO₂, latent, sensible energy fluxes, net radiation and temperature

- [XPalm.jl](https://github.com/PalmStudio/XPalm.jl), an experimental crop model for oil palm

# References

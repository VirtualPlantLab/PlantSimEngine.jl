# Implement a new process

```@setup usepkg
using PlantSimEngine
using PlantMeteo
PlantSimEngine.@process growth
```

## Introduction

`PlantSimEngine.jl` was designed to make the implementation of new processes and models easy and fast. Let's learn about how to implement a new process with a simple example: implementing a growth model.

## Implement a process

To implement a new process, we need to define an abstract structure that will help us associate the models to this process. We also need to generate some boilerplate code, such as a method for the `process` function. Fortunately, PlantSimEngine provides a macro to generate all that at once: [`@process`](@ref). This macro takes only one argument: the name of the process.

For example, the photosynthesis process in [PlantBiophysics.jl](https://github.com/VEZY/PlantBiophysics.jl) is declared using just this tiny line of code:

```julia
@process photosynthesis
```

If we want to simulate the growth of a plant, we could add a new process called `growth`:

```julia
@process "growth"
```

And that's it! Note that the function guides you in the steps you can make after creating a process. Let's break it up here.

So what you just did is to create a new process called `growth`. By doing so, you created a new abstract structure called `AbstractGrowthModel`. It is used as a supertype for the types used for model implementation. This abstract type is always named using the process name in title case (using `titlecase()`), prefixed with `Abstract` and suffixed with `Model`.

!!! note
    If you don't understand what a supertype is, no worries, you'll understand by seeing the examples below

## Implement a new model for the process

To better understand how models are implemented, you can read the detailed instructions from the [previous section](@ref model_implementation_page). But for the sake of completeness, we'll implement a growth model here.

This growth model needs the carbohydrate assimilation that we could compute using *e.g.* the coupled energy balance process from `PlantBiophysics.jl`. Then the model removes the maintenance respiration and the growth respiration from that source of carbon, and increments the leaf biomass by the remaining carbon offer.

Let's implement this model below:

```@example usepkg
using PlantSimEngine, PlantMeteo # PlantMeteo is used for the meteorology

# Make the struct to hold the parameters, with its documentation:
"""
    DummyGrowth(Rm_factor, Rg_cost)
    DummyGrowth(;Rm_factor = 0.5, Rg_cost = 1.2)

Computes the leaf biomass growth of a plant.

# Arguments

- `Rm_factor`: the fraction of assimilation that goes into maintenance respiration
- `Rg_cost`: the cost of growth maintenance, in gram of carbon biomass per gram of assimilate
"""
struct DummyGrowth{T} <: AbstractGrowthModel
    Rm_factor::T
    Rg_cost::T
end

# Note that DummyGrowth is a subtype of AbstractGrowthModel, this is important

# Instantiate the struct with default values + kwargs:
function DummyGrowth(;Rm_factor = 0.5, Rg_cost = 1.2)
    DummyGrowth(promote(Rm_factor,Rg_cost)...)
end

# Define inputs:
function PlantSimEngine.inputs_(::DummyGrowth)
    (A=-Inf,)
end

# Define outputs:
function PlantSimEngine.outputs_(::DummyGrowth)
    (Rm=-Inf, Rg=-Inf, leaf_allocation=-Inf, leaf_biomass=0.0)
end

# Tells Julia what is the type of elements:
Base.eltype(x::DummyGrowth{T}) where {T} = T

# Implement the growth model:
function PlantSimEngine.run!(::DummyGrowth, models, status, meteo, constants, extra)

    # The maintenance respiration is simply a factor of the assimilation:
    status.Rm = status.A * models.growth.Rm_factor
    # Note that we use models.growth.Rm_factor to access the parameter of the model

    # Let's say that all carbon is allocated to the leaves:
    status.leaf_allocation = status.A - status.Rm

    # And that this carbon is allocated with a cost (growth respiration Rg):
    status.Rg = 1 - (status.leaf_allocation / models.growth.Rg_cost)

    status.leaf_biomass = status.leaf_biomass + status.leaf_allocation - status.Rg
end
```

Now we can make a simulation as usual:

```@example usepkg
meteo = Atmosphere(T = 22.0, Wind = 0.8333, P = 101.325, Rh = 0.4490995)

leaf = ModelList(DummyGrowth(), status = (A = 20.0,))

run!(leaf,meteo)

leaf[:leaf_biomass] # biomass in gC
```

We can also start the simulation later when the plant already has some biomass by initializing the `leaf_biomass`:

```@example usepkg
meteo = Atmosphere(T = 22.0, Wind = 0.8333, P = 101.325, Rh = 0.4490995)

leaf = ModelList(DummyGrowth(), status = (A = 20.0, leaf_biomass = 2400.0))

run!(leaf,meteo)

leaf[:leaf_biomass] # biomass in gC
```

# Implementing a new process

```@setup usepkg
using PlantSimEngine
using PlantMeteo
PlantSimEngine.@process growth
```

## Introduction

A process in this package defines a biological or physical phenomena. Think of any process happening in a system, such as light interception, photosynthesis, water, carbon and energy fluxes, growth, yield or even electricity produced by solar panels.

`PlantSimEngine.jl` was designed to make the implementation of new processes and models easy and fast. The next section showcases how to implement a new process with a simple example: implementing a growth model.

## Implement a process

A process is "declared", meaning we define a process, and then implement models for its simulation. Declaring a process generates some boilerplate code for its simulation: 

- an abstract type for the process
- a method for the `process` function, that is used internally

The abstract process type is then used as a supertype of all models implementations for the process, and is named `Abstract<process_name>Process`, *e.g.* `AbstractLight_InterceptionModel`.

Fortunately, PlantSimEngine provides a macro to generate all that at once: [`@process`](@ref). This macro takes only one argument: the name of the process.

For example, the photosynthesis process in [PlantBiophysics.jl](https://github.com/VEZY/PlantBiophysics.jl) is declared using just this tiny line of code:

```julia
@process "photosynthesis"
```

If we want to simulate the growth of a plant, we could add a new process called `growth`:

```julia
@process "growth"
```

And that's it! Note that the function guides you in the steps you can make after creating a process.

## Implement a new model for the process

Once process implementation is done, you can write a corresponding model implementation. A tutorial page showcasing a light interception model implementation can be found [here](@ref model_implementation_page)

A full model implementation for this process is available in the example script [ToyAssimGrowthModel.jl](https://github.com/VirtualPlantLab/PlantSimEngine.jl/blob/main/examples/ToyAssimGrowthModel.jl).

## [Under the hood](@id under_the_hood)

The `@process` macro is just a shorthand reducing boilerplate.

You can in its stead directly define a process by hand by defining an abstract type that is a subtype of `AbstractModel`:
```julia
abstract type AbstractGrowthModel <: PlantSimEngine.AbstractModel end
```
And by adding a method for the `process_` function that returns the name of the process:
```julia
PlantSimEngine.process_(::Type{AbstractGrowthModel}) = :growth
```

So in the earlier example, a new process was created called `growth`. This defined a new abstract structure called `AbstractGrowthModel`, which is used as a supertype of the models. This abstract type is always named using the process name in title case (using `titlecase()`), prefixed with `Abstract` and suffixed with `Model`.
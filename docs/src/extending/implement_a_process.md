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
@process "photosynthesis"
```

If we want to simulate the growth of a plant, we could add a new process called `growth`:

```julia
@process "growth"
```

And that's it! Note that the function guides you in the steps you can make after creating a process. Let's break it up here.

!!! tip
    If you know what you're doing, you can directly define a process by hand just by defining an abstract type that is a subtype of `AbstractModel`:
    ```julia
    abstract type AbstractGrowthModel <: PlantSimEngine.AbstractModel end
    ```
    And by adding a method for the `process_` function that returns the name of the process:
    ```julia
    PlantSimEngine.process_(::Type{AbstractGrowthModel}) = :growth
    ```
    But this way, you don't get the nice tutorial adapted to your process 🙃.

So what you just did is to create a new process called `growth`. By doing so, you created a new abstract structure called `AbstractGrowthModel`, which is used as a supertype of the models. This abstract type is always named using the process name in title case (using `titlecase()`), prefixed with `Abstract` and suffixed with `Model`.

!!! note
    If you don't understand what a supertype is, no worries, you'll understand by seeing the examples below

## Implement a new model for the process

To better understand how models are implemented, you can read the detailed instructions from the [next section](@ref model_implementation_page). But for the sake of completeness, we'll implement a growth model here.

This growth model needs the absorbed photosynthetically active radiation (aPPFD) as an input, and outputs the assimilation, the maintenance respiration, the growth respiration, the biomass increment and the biomass. The assimilation is computed as the product of the aPPFD and the light use efficiency (LUE). The maintenance respiration is a fraction of the assimilation, and the growth respiration is a fraction of the net primary productivity (NPP), which is the assimilation minus the maintenance respiration. The biomass increment is the NPP minus the growth respiration, and the biomass is the sum of the biomass increment and the previous biomass.

The model is available in the example script [ToyAssimGrowthModel.jl](https://github.com/VirtualPlantLab/PlantSimEngine.jl/blob/main/examples/ToyAssimGrowthModel.jl), and is reproduced below:

```@example usepkg
# Make the struct to hold the parameters, with its documentation:
"""
    ToyAssimGrowthModel(Rm_factor, Rg_cost)
    ToyAssimGrowthModel(; LUE=0.2, Rm_factor = 0.5, Rg_cost = 1.2)

Computes the biomass growth of a plant.

# Arguments

- `LUE=0.2`: the light use efficiency, in gC mol[PAR]⁻¹
- `Rm_factor=0.5`: the fraction of assimilation that goes into maintenance respiration
- `Rg_cost=1.2`: the cost of growth maintenance, in gram of carbon biomass per gram of assimilate

# Inputs

- `aPPFD`: the absorbed photosynthetic photon flux density, in mol[PAR] m⁻² d⁻¹

# Outputs

- `A`: the assimilation, in gC m⁻² d⁻¹
- `Rm`: the maintenance respiration, in gC m⁻² d⁻¹
- `Rg`: the growth respiration, in gC m⁻² d⁻¹
- `biomass_increment`: the daily biomass increment, in gC m⁻² d⁻¹
- `biomass`: the plant biomass, in gC m⁻² d⁻¹
"""
struct ToyAssimGrowthModel{T} <: AbstractGrowthModel
    LUE::T
    Rm_factor::T
    Rg_cost::T
end

# Note that ToyAssimGrowthModel is a subtype of AbstractGrowthModel, this is important

# Instantiate the `struct` with keyword arguments and default values:
function ToyAssimGrowthModel(; LUE=0.2, Rm_factor=0.5, Rg_cost=1.2)
    ToyAssimGrowthModel(promote(LUE, Rm_factor, Rg_cost)...)
end

# Define inputs:
function PlantSimEngine.inputs_(::ToyAssimGrowthModel)
    (aPPFD=-Inf,)
end

# Define outputs:
function PlantSimEngine.outputs_(::ToyAssimGrowthModel)
    (A=-Inf, Rm=-Inf, Rg=-Inf, biomass_increment=-Inf, biomass=0.0)
end

# Tells Julia what is the type of elements:
Base.eltype(x::ToyAssimGrowthModel{T}) where {T} = T

# Implement the growth model:
function PlantSimEngine.run!(::ToyAssimGrowthModel, models, status, meteo, constants, extra)

    # The assimilation is simply the absorbed photosynthetic photon flux density (aPPFD) times the light use efficiency (LUE):
    status.carbon_assimilation = status.aPPFD * models.growth.LUE
    # The maintenance respiration is simply a factor of the assimilation:
    status.Rm = status.carbon_assimilation * models.growth.Rm_factor
    # Note that we use models.growth.Rm_factor to access the parameter of the model

    # Net primary productivity of the plant (NPP) is the assimilation minus the maintenance respiration:
    NPP = status.carbon_assimilation - status.Rm

    # The NPP is used with a cost (growth respiration Rg):
    status.Rg = 1 - (NPP / models.growth.Rg_cost)

    # The biomass increment is the NPP minus the growth respiration:
    status.biomass_increment = NPP - status.Rg

    # The biomass is the biomass from the previous time-step plus the biomass increment:
    status.biomass = PlantMeteo.prev_value(status, :biomass; default=0.0) + status.biomass_increment
end

# And optionally, we can tell PlantSimEngine that we can safely parallelize our model over space (objects):
PlantSimEngine.ObjectDependencyTrait(::Type{<:ToyAssimGrowthModel}) = PlantSimEngine.IsObjectIndependent()
```

Now we can make a simulation as usual:

```@example usepkg
model = ModelList(ToyAssimGrowthModel(), status = (aPPFD = 20.0,))
run!(model)
model[:biomass] # biomass in gC m⁻²
```

We can also run the simulation over more time-steps:

```@example usepkg
model = ModelList(
    ToyAssimGrowthModel(),
    status=(aPPFD=[10.0, 30.0, 25.0],),
)

run!(model)

model.status[:biomass] # biomass in gC m⁻²
```
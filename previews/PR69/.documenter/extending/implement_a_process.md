
# Implement a new process {#Implement-a-new-process}

## Introduction {#Introduction}

`PlantSimEngine.jl` was designed to make the implementation of new processes and models easy and fast. Let&#39;s learn about how to implement a new process with a simple example: implementing a growth model.

## Implement a process {#Implement-a-process}

To implement a new process, we need to define an abstract structure that will help us associate the models to this process. We also need to generate some boilerplate code, such as a method for the `process` function. Fortunately, PlantSimEngine provides a macro to generate all that at once: [`@process`](/API#PlantSimEngine.@process-Tuple{Any,%20Vararg{Any}}). This macro takes only one argument: the name of the process.

For example, the photosynthesis process in [PlantBiophysics.jl](https://github.com/VEZY/PlantBiophysics.jl) is declared using just this tiny line of code:

```julia
@process "photosynthesis"
```


If we want to simulate the growth of a plant, we could add a new process called `growth`:

```julia
@process "growth"
```


And that&#39;s it! Note that the function guides you in the steps you can make after creating a process. Let&#39;s break it up here.

::: tip Tip

If you know what you&#39;re doing, you can directly define a process by hand just by defining an abstract type that is a subtype of `AbstractModel`:

```julia
abstract type AbstractGrowthModel <: PlantSimEngine.AbstractModel end
```


And by adding a method for the `process_` function that returns the name of the process:

```julia
PlantSimEngine.process_(::Type{AbstractGrowthModel}) = :growth
```


But this way, you don&#39;t get the nice tutorial adapted to your process 🙃.

:::

So what you just did is to create a new process called `growth`. By doing so, you created a new abstract structure called `AbstractGrowthModel`, which is used as a supertype of the models. This abstract type is always named using the process name in title case (using `titlecase()`), prefixed with `Abstract` and suffixed with `Model`.

::: tip Note

If you don&#39;t understand what a supertype is, no worries, you&#39;ll understand by seeing the examples below

:::

## Implement a new model for the process {#Implement-a-new-model-for-the-process}

To better understand how models are implemented, you can read the detailed instructions from the [next section](/extending/implement_a_model#model_implementation_page). But for the sake of completeness, we&#39;ll implement a growth model here.

This growth model needs the absorbed photosynthetically active radiation (aPPFD) as an input, and outputs the assimilation, the maintenance respiration, the growth respiration, the biomass increment and the biomass. The assimilation is computed as the product of the aPPFD and the light use efficiency (LUE). The maintenance respiration is a fraction of the assimilation, and the growth respiration is a fraction of the net primary productivity (NPP), which is the assimilation minus the maintenance respiration. The biomass increment is the NPP minus the growth respiration, and the biomass is the sum of the biomass increment and the previous biomass. Note that the previous biomass is always available in the `status` as long as you don&#39;t modify it.

The model is available in the example script [ToyAssimGrowthModel.jl](https://github.com/VirtualPlantLab/PlantSimEngine.jl/blob/main/examples/ToyAssimGrowthModel.jl), and is reproduced below:

```julia
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

- `aPPFD`: the absorbed photosynthetic photon flux density, in mol[PAR] m⁻² time-step⁻¹

# Outputs

- `carbon_assimilation`: the assimilation, in gC m⁻² time-step⁻¹
- `Rm`: the maintenance respiration, in gC m⁻² time-step⁻¹
- `Rg`: the growth respiration, in gC m⁻² time-step⁻¹
- `biomass_increment`: the daily biomass increment, in gC m⁻² time-step⁻¹
- `biomass`: the plant biomass, in gC m⁻² time-step⁻¹
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
    (carbon_assimilation=-Inf, Rm=-Inf, Rg=-Inf, biomass_increment=-Inf, biomass=0.0)
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
    status.biomass += status.biomass_increment
end

# And optionally, we can tell PlantSimEngine that we can safely parallelize our model over space (objects):
PlantSimEngine.ObjectDependencyTrait(::Type{<:ToyAssimGrowthModel}) = PlantSimEngine.IsObjectIndependent()
```


Now we can make a simulation as usual:

```julia
model = ModelList(ToyAssimGrowthModel(), status = (aPPFD = 20.0,))
run!(model)
model[:biomass] # biomass in gC m⁻²
```


```
1-element Vector{Float64}:
 2.666666666666667
```


We can also run the simulation over more time-steps:

```julia
model = ModelList(
    ToyAssimGrowthModel(),
    status=(aPPFD=[10.0, 30.0, 25.0],),
)

run!(model)

model.status[:biomass] # biomass in gC m⁻²
```


```
3-element Vector{Float64}:
 0.8333333333333334
 5.333333333333333
 8.916666666666666
```


# using PlantSimEngine, PlantMeteo # Import the necessary packages, PlantMeteo is used for the meteorology

# Defining the process:
@process "growth" verbose = false

# Make the struct to hold the parameters, with its documentation:
"""
    ToyAssimGrowth(Rm_factor, Rg_cost)
    ToyAssimGrowth(;Rm_factor = 0.5, Rg_cost = 1.2)

Computes the biomass growth of a plant.

# Arguments

- `Rm_factor`: the fraction of assimilation that goes into maintenance respiration
- `Rg_cost`: the cost of growth maintenance, in gram of carbon biomass per gram of assimilate
"""
struct ToyAssimGrowth{T} <: AbstractGrowthModel
    Rm_factor::T
    Rg_cost::T
end

# Note that ToyAssimGrowth is a subtype of AbstractGrowthModel, this is important

# Instantiate the `struct` with keyword arguments and default values:
function ToyAssimGrowth(; Rm_factor=0.5, Rg_cost=1.2)
    ToyAssimGrowth(promote(Rm_factor, Rg_cost)...)
end

# Define inputs:
function PlantSimEngine.inputs_(::ToyAssimGrowth)
    (A=-Inf,)
end

# Define outputs:
function PlantSimEngine.outputs_(::ToyAssimGrowth)
    (Rm=-Inf, Rg=-Inf, biomass_increment=-Inf, biomass=0.0)
end

# Tells Julia what is the type of elements:
Base.eltype(x::ToyAssimGrowth{T}) where {T} = T

# Implement the growth model:
function PlantSimEngine.run!(::ToyAssimGrowth, models, status, meteo, constants, extra)
    # The maintenance respiration is simply a factor of the assimilation:
    status.Rm = status.A * models.growth.Rm_factor
    # Note that we use models.growth.Rm_factor to access the parameter of the model

    # Net primary productivity of the plant (NPP) is the assimilation minus the maintenance respiration:
    NPP = status.A - status.Rm

    # The NPP is used with a cost (growth respiration Rg):
    status.Rg = 1 - (NPP / models.growth.Rg_cost)

    # The biomass increment is the NPP minus the growth respiration:
    status.biomass_increment = NPP - status.Rg

    # The biomass is the biomass from the previous time-step plus the biomass increment:
    status.biomass = PlantMeteo.prev_value(status, :biomass; default=0.0) + status.biomass_increment
end

# And optionally, we can tell PlantSimEngine that we can safely parallelize our model over space (objects):
PlantSimEngine.ObjectDependencyTrait(::Type{<:ToyAssimGrowth}) = PlantSimEngine.IsObjectIndependent()
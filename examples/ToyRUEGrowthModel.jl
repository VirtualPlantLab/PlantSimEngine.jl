# using PlantSimEngine, PlantMeteo # Import the necessary packages, PlantMeteo is used for the meteorology

# Defining the process:
@process "growth" verbose = false

# Make the struct to hold the parameters, with its documentation:
"""
    ToyRUEGrowthModel(efficiency)

Computes the carbon biomass increment of a plant based on the radiation use efficiency principle.

# Arguments

- `efficiency`: the radiation use efficiency, in gC[biomass] mol[PAR]⁻¹

# Inputs

- `aPPFD`: the absorbed photosynthetic photon flux density, in mol[PAR] m⁻² d⁻¹

# Outputs

- `biomass_increment`: the daily biomass increment, in gC[biomass] m⁻² d⁻¹
- `biomass`: the plant biomass, in gC[biomass] m⁻² d⁻¹
"""
struct ToyRUEGrowthModel{T} <: AbstractGrowthModel
    efficiency::T
end

# Note that ToyRUEGrowthModel is a subtype of AbstractGrowthModel, this is important

# Define inputs:
function PlantSimEngine.inputs_(::ToyRUEGrowthModel)
    (aPPFD=-Inf,)
end

# Define outputs:
function PlantSimEngine.outputs_(::ToyRUEGrowthModel)
    (biomass=0.0, biomass_increment=-Inf)
end

# Tells Julia what is the type of elements:
Base.eltype(x::ToyRUEGrowthModel{T}) where {T} = T

# Implement the growth model:
function PlantSimEngine.run!(::ToyRUEGrowthModel, models, status, meteo, constants, extra)
    status.biomass_increment = status.aPPFD * models.growth.efficiency
    status.biomass = PlantMeteo.prev_value(status, :biomass; default=0.0) + status.biomass_increment
end

# And optionally, we can tell PlantSimEngine that we can safely parallelize our model over space (objects):
PlantSimEngine.ObjectDependencyTrait(::Type{<:ToyRUEGrowthModel}) = PlantSimEngine.IsObjectIndependent()

# Note that this model cannot be parallelized over time because we use the biomass from the previous time-step.
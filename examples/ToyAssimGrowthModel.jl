# Defining the process:
PlantSimEngine.@process "growth" verbose = false

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
    status.biomass += status.biomass_increment
end

# And optionally, we can tell PlantSimEngine that we can safely parallelize our model over space (objects):
PlantSimEngine.ObjectDependencyTrait(::Type{<:ToyAssimGrowthModel}) = PlantSimEngine.IsObjectIndependent()
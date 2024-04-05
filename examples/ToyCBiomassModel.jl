# using PlantSimEngine, PlantMeteo # Import the necessary packages, PlantMeteo is used for the meteorology

PlantSimEngine.@process "carbon_biomass" verbose = false

"""
    ToyCBiomassModel(construction_cost)

Computes the carbon biomass of an organ based on the carbon allocation and construction cost.

# Arguments

- `construction_cost`: the construction cost of the organ, usually in gC gC⁻¹. Should be understood as the amount of carbon needed to build 1g of carbon biomass.

# Inputs

- `carbon_allocation`: the carbon allocation to the organ for the time-step, usually in gC m⁻² time-step⁻¹

# Outputs

- `carbon_biomass_increment`: the increment of carbon biomass, usually in gC time-step⁻¹
- `carbon_biomass`: the carbon biomass, usually in gC
- `growth_respiration`: the growth respiration, usually in gC time-step⁻¹

"""
struct ToyCBiomassModel{T} <: AbstractCarbon_BiomassModel
    construction_cost::T
end

# Define inputs:
function PlantSimEngine.inputs_(::ToyCBiomassModel)
    (carbon_allocation=-Inf,)
end

# Define outputs:
function PlantSimEngine.outputs_(::ToyCBiomassModel)
    (carbon_biomass_increment=-Inf, carbon_biomass=0.0, growth_respiration=-Inf,)
end

function PlantSimEngine.run!(m::ToyCBiomassModel, models, status, meteo, constants, extra_args)
    status.carbon_biomass_increment = status.carbon_allocation / m.construction_cost
    status.carbon_biomass += status.carbon_biomass_increment
    status.growth_respiration = status.carbon_allocation - status.carbon_biomass_increment
end

# Can be parallelized over organs (but not time-steps, as it is incrementally updating the biomass in the status):
PlantSimEngine.ObjectDependencyTrait(::Type{<:ToyCBiomassModel}) = PlantSimEngine.IsObjectIndependent()
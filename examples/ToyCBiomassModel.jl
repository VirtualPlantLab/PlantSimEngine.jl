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
    (carbon_allocation=Required(Real),)
end

# Define outputs:
function PlantSimEngine.outputs_(model::ToyCBiomassModel)
    initial = oftype(float(model.construction_cost), -Inf)
    return (
        carbon_biomass_increment=initial,
        carbon_biomass=zero(float(model.construction_cost)),
        growth_respiration=initial,
    )
end

function PlantSimEngine.run!(m::ToyCBiomassModel, status, environment, constants, context)
    status.carbon_biomass_increment = status.carbon_allocation / m.construction_cost
    status.carbon_biomass += status.carbon_biomass_increment
    status.growth_respiration = status.carbon_allocation - status.carbon_biomass_increment
end

# using PlantSimEngine, PlantMeteo # Import the necessary packages, PlantMeteo is used for the meteorology

# Defining the process:
PlantSimEngine.@process "carbon_allocation" verbose = false

# Make the struct to hold the parameters, with its documentation:
"""
    ToyCAllocationModel()

Computes the carbon allocation to each organ of a plant based on the plant total carbon offer and individual organ demand.
This model should be used at the plant scale, because it first computes the carbon availaible for allocation as the minimum between the total demand 
(sum of organs' demand) and total carbon offer (sum of organs' assimilation - total maintenance respiration), and then allocates the carbon relative 
to each organ's demand.

# Inputs

- `carbon_assimilation`: a vector of the assimilation of all photosynthetic organs, usually in gC m⁻² d⁻¹
- `Rm`: the maintenance respiration of the plant, usually in gC m⁻² d⁻¹
- `carbon_demand`: a vector of the carbon demand of the organs, usually in gC m⁻² d⁻¹

# Outputs

- `carbon_assimilation`: the carbon assimilation, usually in gC m⁻² d⁻¹

# Details

The units usually are in gC m⁻² d⁻¹, but they could be in another spatial or temporal unit depending on the unit of the inputs, *e.g.*
in gC plant⁻¹ d⁻¹.
"""
struct ToyCAllocationModel <: AbstractCarbon_AllocationModel end

# Define inputs:
function PlantSimEngine.inputs_(::ToyCAllocationModel)
    (carbon_assimilation=[-Inf], Rm=-Inf, carbon_demand=[-Inf],)
end

# Define outputs:
function PlantSimEngine.outputs_(::ToyCAllocationModel)
    (carbon_offer=-Inf, carbon_allocation=[-Inf],)
end

function PlantSimEngine.run!(::ToyCAllocationModel, models, status, meteo, constants, mtg)

    carbon_demand_tot = sum(status.carbon_demand)
    #Note: this model is multiscale, so status.carbon_demand, status.carbon_allocation, and status.carbon_assimilation are vectors.
    status.carbon_offer = sum(status.carbon_assimilation) - status.Rm

    # If the total demand is positive, we try allocating carbon:
    if carbon_demand_tot > 0.0
        # Proportion of the demand of each leaf compared to the total leaf demand: 
        proportion_carbon_demand = status.carbon_demand ./ carbon_demand_tot

        if carbon_demand_tot <= status.carbon_offer
            # If the carbon demand is lower than the offer we allocate the offer:
            carbon_allocation_organs = carbon_demand_tot
        else
            # Here we don't have enough carbon offer
            carbon_allocation_organs = status.carbon_offer
        end
        status.carbon_allocation .= carbon_allocation_organs .* proportion_carbon_demand
    else
        # If the carbon demand is 0.0, we allocate nothing:
        status.carbon_allocation .= 0.0
    end
end

# And also over time (time-steps):
PlantSimEngine.TimeStepDependencyTrait(::Type{<:ToyCAllocationModel}) = PlantSimEngine.IsTimeStepIndependent()
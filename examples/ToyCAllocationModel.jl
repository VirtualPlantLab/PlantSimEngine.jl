# using PlantSimEngine, PlantMeteo # Import the necessary packages, PlantMeteo is used for the meteorology

# Defining the process:
@process "carbon_allocation" verbose = false

# Make the struct to hold the parameters, with its documentation:
"""
    ToyCAllocationModel()

Computes the carbon allocation to each organ of a plant.
This model should be used at the plant scale, because it first computes the carbon availaible for allocation as the minimum between the total demand 
and total carbon offer, and then allocates it relative to their demand.

# Inputs

- `A`: the absorbed photosynthetic photon flux density, taken from the organs, in mol[PAR] m⁻² d⁻¹

# Outputs

- `A`: the assimilation, in gC m⁻² d⁻¹
"""
struct ToyCAllocationModel <: AbstractCarbon_AllocationModel end

# Define inputs:
function PlantSimEngine.inputs_(::ToyCAllocationModel)
    (A=[-Inf], carbon_demand=[-Inf],)
end

# Define outputs:
function PlantSimEngine.outputs_(::ToyCAllocationModel)
    (carbon_offer=-Inf, carbon_allocation=[-Inf])
end

function PlantSimEngine.run!(::ToyCAllocationModel, models, status, meteo, constants, mtg)

    carbon_demand_tot = sum(status.carbon_demand)
    status.carbon_offer = sum(status.A)
    #Note: this model is multiscale, so status.carbon_demand, status.carbon_allocation, and status.A are vectors.

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
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
    (A=-Inf, carbon_demand=-Inf,)
end

# Define outputs:
function PlantSimEngine.outputs_(::ToyCAllocationModel)
    (carbon_offer=-Inf, carbon_allocation=-Inf)
end

function PlantSimEngine.run!(::ToyCAllocationModel, models, status, meteo, constants, mtg)
    carbon_demand_organs = Vector{eltype(status.carbon_demand)}()
    MultiScaleTreeGraph.traverse!(mtg, symbol=["Leaf", "Internode"]) do node
        push!(carbon_demand_organs, node[:models].status[:carbon_demand])
    end

    carbon_demand = sum(carbon_demand_organs)

    status.carbon_offer = 0.0
    MultiScaleTreeGraph.traverse!(mtg, symbol="Leaf") do node
        status.carbon_offer += node[:models].status[:A]
    end

    # If the total demand is positive, we try allocating carbon:
    if carbon_demand > 0.0
        # Proportion of the demand of each leaf compared to the total leaf demand: 
        proportion_carbon_demand = carbon_demand_organs ./ carbon_demand

        if carbon_demand <= status.carbon_offer
            # If the carbon demand is lower than the offer we allocate the offer:
            carbon_allocation_organs = carbon_demand
        else
            # Here we don't have enough carbon offer
            carbon_allocation_organs = status.carbon_offer
        end
        carbon_allocation_organ = carbon_allocation_organs .* proportion_carbon_demand
    else
        # If the carbon demand is 0.0, we allocate nothing:
        carbon_allocation_organs = 0.0
        carbon_allocation_organ = zeros(typeof(carbon_demand_organs[1]), length(carbon_demand_organs))
    end

    # We allocate the carbon to the organs:
    MultiScaleTreeGraph.traverse!(mtg, symbol=["Leaf", "Internode"]) do organ
        organ[:models].status[:carbon_allocation] = popfirst!(carbon_allocation_organ)
    end
end

# And also over time (time-steps):
PlantSimEngine.TimeStepDependencyTrait(::Type{<:ToyCAllocationModel}) = PlantSimEngine.IsTimeStepIndependent()
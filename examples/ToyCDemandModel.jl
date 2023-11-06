# using PlantSimEngine, PlantMeteo # Import the necessary packages, PlantMeteo is used for the meteorology

# Defining the process:
PlantSimEngine.@process "carbon_demand" verbose = false

# Make the struct to hold the parameters, with its documentation:
"""
    ToyCDemandModel(optimal_biomass, development_duration)
    ToyCDemandModel(; optimal_biomass, development_duration)

Computes the carbon demand of an organ depending on its biomass under optimal conditions and the duration of its development in degree days.
The model assumes that the carbon demand is linear througout the duration of the development.

# Arguments

- `optimal_biomass`: the biomass of the organ under optimal conditions, in gC
- `development_duration`: the duration of the development of the organ, in degree days

# Inputs

- `TT`: the thermal time, in degree days

# Outputs

- `carbon_demand`: the carbon demand, in gC
"""
struct ToyCDemandModel{T} <: AbstractCarbon_DemandModel
    optimal_biomass::T
    development_duration::T
end

# Instantiate the `struct` with keyword arguments and default values:
function ToyCDemandModel(; optimal_biomass, development_duration)
    ToyCDemandModel(optimal_biomass, development_duration)
end

# Define inputs:
function PlantSimEngine.inputs_(::ToyCDemandModel)
    (TT=-Inf,)
end

# Define outputs:
function PlantSimEngine.outputs_(::ToyCDemandModel)
    (carbon_demand=-Inf,)
end

# Tells Julia what is the type of elements:
Base.eltype(::ToyCDemandModel{T}) where {T} = T

# Implement the growth model:
function PlantSimEngine.run!(::ToyCDemandModel, models, status, meteo, constants, extra)
    # The carbon demand is simply the biomass under optimal conditions divided by the duration of the development:
    status.carbon_demand = status.TT * models.carbon_demand.optimal_biomass / models.carbon_demand.development_duration
end

# And optionally, we can tell PlantSimEngine that we can safely parallelize our model over space (objects):
PlantSimEngine.ObjectDependencyTrait(::Type{<:ToyCDemandModel}) = PlantSimEngine.IsObjectIndependent()
# And also over time (time-steps):
PlantSimEngine.TimeStepDependencyTrait(::Type{<:ToyCDemandModel}) = PlantSimEngine.IsTimeStepIndependent()
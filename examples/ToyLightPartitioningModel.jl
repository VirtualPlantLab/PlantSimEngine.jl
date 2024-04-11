# using PlantSimEngine, PlantMeteo # Import the necessary packages, PlantMeteo is used for the meteorology

# Defining the process:
PlantSimEngine.@process "light_partitioning" verbose = false

# Make the struct to hold the parameters, with its documentation:
"""
    ToyLightPartitioningModel()

Computes the light partitioning based on relative surface.

# Inputs

- `aPPFD`: the absorbed photosynthetic photon flux density at the larger scale (*e.g.* scene), in mol[PAR] m⁻² time-step⁻¹ 

# Outputs

- `aPPFD`: the assimilation or photosynthesis, also sometimes denoted `A`, in gC time-step⁻¹

# Details


"""
struct ToyLightPartitioningModel <: AbstractLight_PartitioningModel end

# Define inputs:
PlantSimEngine.inputs_(::ToyLightPartitioningModel) = (aPPFD_larger_scale=-Inf, total_surface=-Inf, surface=-Inf,)

# Define outputs:
PlantSimEngine.outputs_(::ToyLightPartitioningModel) = (aPPFD=-Inf,)

function PlantSimEngine.run!(::ToyLightPartitioningModel, models, status, meteo, constants, extra)
    status.aPPFD = status.aPPFD_larger_scale * status.surface / status.total_surface
end

PlantSimEngine.TimeStepDependencyTrait(::Type{<:ToyLightPartitioningModel}) = PlantSimEngine.IsTimeStepIndependent()
# using PlantSimEngine, PlantMeteo # Import the necessary packages, PlantMeteo is used for the meteorology

# Defining the process:
PlantSimEngine.@process "photosynthesis" verbose = false

# Make the struct to hold the parameters, with its documentation:
"""
    ToyAssimModel(A)
    ToyAssimModel(; LUE=0.2, Rm_factor = 0.5, Rg_cost = 1.2)

Computes the assimilation of a plant (= photosynthesis).

# Arguments

- `LUE=0.2`: the light use efficiency, in gC mol[PAR]⁻¹

# Inputs

- `aPPFD`: the absorbed photosynthetic photon flux density, in mol[PAR] m⁻² d⁻¹
- `soil_water_content`: the soil water content, in %

# Outputs

- `A`: the assimilation, in gC m⁻² d⁻¹
"""
struct ToyAssimModel{T} <: AbstractPhotosynthesisModel
    LUE::T
end

# Instantiate the `struct` with keyword arguments and default values:
function ToyAssimModel(; LUE=0.2)
    ToyAssimModel(LUE)
end

# Define inputs:
function PlantSimEngine.inputs_(::ToyAssimModel)
    (aPPFD=-Inf, soil_water_content=-Inf)
end

# Define outputs:
function PlantSimEngine.outputs_(::ToyAssimModel)
    (A=-Inf,)
end

# Tells Julia what is the type of elements:
Base.eltype(::ToyAssimModel{T}) where {T} = T

# Implement the growth model:
function PlantSimEngine.run!(::ToyAssimModel, models, status, meteo, constants, extra)
    # The assimilation is simply the absorbed photosynthetic photon flux density (aPPFD) times the light use efficiency (LUE):
    status.A = status.aPPFD * models.photosynthesis.LUE * status.soil_water_content
end

# And optionally, we can tell PlantSimEngine that we can safely parallelize our model over space (objects):
PlantSimEngine.ObjectDependencyTrait(::Type{<:ToyAssimModel}) = PlantSimEngine.IsObjectIndependent()
# And also over time (time-steps):
PlantSimEngine.TimeStepDependencyTrait(::Type{<:ToyAssimModel}) = PlantSimEngine.IsTimeStepIndependent()
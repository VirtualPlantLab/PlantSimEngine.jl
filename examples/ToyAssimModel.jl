# using PlantSimEngine, PlantMeteo # Import the necessary packages, PlantMeteo is used for the meteorology

# Defining the process:
PlantSimEngine.@process "carbon_assimilation" verbose = false

# Make the struct to hold the parameters, with its documentation:
"""
    ToyAssimModel(LUE)

Computes the assimilation of a plant (= photosynthesis).

# Arguments

- `LUE=0.2`: the light use efficiency, in gC mol[PAR]⁻¹

# Inputs

- `aPPFD`: the absorbed photosynthetic photon flux density, in mol[PAR] m⁻² d⁻¹
- `soil_water_content`: the soil water content, in %

# Outputs

- `carbon_assimilation`: the assimilation or photosynthesis, also sometimes denoted `A`, in gC m⁻² d⁻¹

# Details

The assimilation is computed as the product of the absorbed photosynthetic photon flux density (aPPFD) and the light use efficiency (LUE),
so the units of the assimilation usually are in gC m⁻² d⁻¹, but they could be in another spatial or temporal unit depending on the unit of `aPPFD`, *e.g.* 
if `aPPFD` is in mol[PAR] plant⁻¹ d⁻¹, the assimilation will be in gC plant⁻¹ d⁻¹.
"""
struct ToyAssimModel{T} <: AbstractCarbon_AssimilationModel
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
    (carbon_assimilation=-Inf,)
end

# Tells Julia what is the type of elements:
Base.eltype(::ToyAssimModel{T}) where {T} = T

# Implement the growth model:
function PlantSimEngine.run!(::ToyAssimModel, models, status, meteo, constants, extra)
    # The assimilation is simply the absorbed photosynthetic photon flux density (aPPFD) times the light use efficiency (LUE):
    status.carbon_assimilation = status.aPPFD * models.carbon_assimilation.LUE * status.soil_water_content
end

# And optionally, we can tell PlantSimEngine that we can safely parallelize our model over space (objects):
PlantSimEngine.ObjectDependencyTrait(::Type{<:ToyAssimModel}) = PlantSimEngine.IsObjectIndependent()
# And also over time (time-steps):
PlantSimEngine.TimeStepDependencyTrait(::Type{<:ToyAssimModel}) = PlantSimEngine.IsTimeStepIndependent()
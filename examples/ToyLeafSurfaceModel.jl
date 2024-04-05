# using PlantSimEngine, PlantMeteo # Import the necessary packages, PlantMeteo is used for the meteorology

PlantSimEngine.@process "leaf_surface" verbose = false

"""
    ToyLeafSurfaceModel(SLA)

Computes the individual leaf surface from its biomass using the SLA.

# Arguments

- `SLA`: the specific leaf area, usually in **m² gC⁻¹**. Should be understood as the surface area of a leaf per unit of carbon biomass.
Values typically range from 0.002 to 0.027 m² gC⁻¹.

# Inputs

- `carbon_biomass`: the carbon biomass of the leaf, usually in gC

# Outputs

- `surface`: the leaf surface, usually in m²

"""
struct ToyLeafSurfaceModel{T} <: AbstractLeaf_SurfaceModel
    SLA::T
end

# Define inputs:
function PlantSimEngine.inputs_(::ToyLeafSurfaceModel)
    (carbon_biomass=-Inf,)
end

# Define outputs:
function PlantSimEngine.outputs_(::ToyLeafSurfaceModel)
    (surface=-Inf,)
end

function PlantSimEngine.run!(m::ToyLeafSurfaceModel, models, status, meteo, constants, extra_args)
    status.surface = status.carbon_biomass * m.SLA
end

# Can be parallelized over organs and time-steps:
PlantSimEngine.ObjectDependencyTrait(::Type{<:ToyLeafSurfaceModel}) = PlantSimEngine.IsObjectIndependent()
PlantSimEngine.TimeStepDependencyTrait(::Type{<:ToyLeafSurfaceModel}) = PlantSimEngine.IsTimeStepDependent()



# At plant scale:
"""
    ToyPlantLeafSurfaceModel()

Computes the leaf surface at plant scale by summing the individual leaf surfaces.

# Inputs

- `leaf_surfaces`: a vector of leaf surfaces, usually in m²

# Outputs

- `surface`: the leaf surface at plant scale, usually in m²

"""
struct ToyPlantLeafSurfaceModel <: AbstractLeaf_SurfaceModel end

# Define inputs:
function PlantSimEngine.inputs_(::ToyPlantLeafSurfaceModel)
    (leaf_surfaces=[-Inf],)
end

# Define outputs:
function PlantSimEngine.outputs_(::ToyPlantLeafSurfaceModel)
    (surface=-Inf,)
end

function PlantSimEngine.run!(m::ToyPlantLeafSurfaceModel, models, status, meteo, constants, extra_args)
    status.surface = sum(status.leaf_surfaces)
end

# Can be parallelized over time-steps:
PlantSimEngine.TimeStepDependencyTrait(::Type{<:ToyPlantLeafSurfaceModel}) = PlantSimEngine.IsTimeStepDependent()
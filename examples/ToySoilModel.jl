# Declaring the process of LAI dynamic:
PlantSimEngine.@process "soil_water" verbose = false


"""
    ToySoilWaterModel(values=[0.5])

A toy model to compute the soil water content. The model simply take a random value in
the `values` range using `rand`.

# Outputs

- `soil_water_content`: the soil water content (%).

# Arguments

- `values`: a range of `soil_water_content` values to sample from. Can be a vector of values `[0.5,0.6]` or a range `0.1:0.1:1.0`. Default is `[0.5]`.
"""
struct ToySoilWaterModel{T<:Union{AbstractRange{Float64},AbstractVector{Float64}}} <: AbstractSoil_WaterModel
    values::T
end

# Defining a method with keyword arguments and default values:
ToySoilWaterModel(values=[0.5]) = ToySoilWaterModel(values)

# Defining the inputs and outputs of the model:
PlantSimEngine.inputs_(::ToySoilWaterModel) = NamedTuple()
PlantSimEngine.outputs_(::ToySoilWaterModel) = (soil_water_content=-Inf,)

# Implementing the actual algorithm by adding a method to the run! function for our model:
function PlantSimEngine.run!(m::ToySoilWaterModel, models, status, meteo, constants=nothing, extra=nothing)
    status.soil_water_content = rand(m.values)
end

# The computation of ToySoilWaterModel is independant of previous values and other objects. We can add this information as 
# traits to the model to tell PlantSimEngine that it is safe to run the models in parallel:
PlantSimEngine.TimeStepDependencyTrait(::Type{<:ToySoilWaterModel}) = PlantSimEngine.IsTimeStepIndependent()
PlantSimEngine.ObjectDependencyTrait(::Type{<:ToySoilWaterModel}) = PlantSimEngine.IsObjectIndependent()
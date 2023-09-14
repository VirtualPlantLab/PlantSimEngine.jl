using Random
# Declaring the process of LAI dynamic:
@process "soil_water" verbose = false


"""
    ToySoilWaterModel()
    ToySoilWaterModel(;values=0.1:0.1:1.0,rng=MersenneTwister(1234))
    ToySoilWaterModel(values,rng)

A toy model to compute the soil water content. The model simply take a random value in
the `values` range using the `rng` random number generator.

# Outputs

- `soil_water_content`: the soil water content (%).
"""
struct ToySoilWaterModel <: AbstractSoil_WaterModel
    values::AbstractRange{Float64}
    rng::AbstractRNG
end

# Defining a method with keyword arguments and default values:
ToySoilWaterModel(; values=0.1:0.1:1.0, rng=MersenneTwister(1234)) = ToySoilWaterModel(values, rng)

# Defining the inputs and outputs of the model:
PlantSimEngine.inputs_(::ToySoilWaterModel) = NamedTuple()
PlantSimEngine.outputs_(::ToySoilWaterModel) = (soil_water_content=-Inf,)

# Implementing the actual algorithm by adding a method to the run! function for our model:
function PlantSimEngine.run!(m::ToySoilWaterModel, models, status, meteo, constants=nothing, extra=nothing)
    soil_water_content = rand(m.values)
end

# The computation of ToySoilWaterModel is independant of previous values and other objects. We can add this information as 
# traits to the model to tell PlantSimEngine that it is safe to run the models in parallel:
PlantSimEngine.TimeStepDependencyTrait(::Type{<:ToySoilWaterModel}) = PlantSimEngine.IsTimeStepIndependent()
PlantSimEngine.ObjectDependencyTrait(::Type{<:ToySoilWaterModel}) = PlantSimEngine.IsObjectIndependent()
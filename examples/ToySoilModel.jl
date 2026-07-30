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
struct ToySoilWaterModel{T<:Union{AbstractRange,AbstractVector}} <: AbstractSoil_WaterModel
    values::T
end

# Defining a zero-argument default without shadowing the generated positional
# constructor.
ToySoilWaterModel() = ToySoilWaterModel([0.5])

# Defining the inputs and outputs of the model:
PlantSimEngine.inputs_(::ToySoilWaterModel) = NamedTuple()
PlantSimEngine.outputs_(m::ToySoilWaterModel) = (
    soil_water_content=oftype(float(first(m.values)), -Inf),
)

# Implementing the actual algorithm by adding a method to the run! function for our model:
function PlantSimEngine.run!(m::ToySoilWaterModel, status, environment, constants=nothing, context=nothing)
    status.soil_water_content = rand(m.values)
end

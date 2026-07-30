
# Declaring the process of LAI dynamic:
PlantSimEngine.@process "Degreedays" verbose = false

# Declaring the model of LAI dynamic with its parameter values:

"""
    ToyDegreeDaysCumulModel(;init_TT=0.0, T_base=10.0, T_max=43.0)

Computes the thermal time in degree days and cumulated degree-days based on the average daily temperature (`T`),
the initial cumulated degree days, the base temperature below which there is no growth, and the maximum 
temperature for growh.
"""
struct ToyDegreeDaysCumulModel{T<:Real} <: AbstractDegreedaysModel
    init_TT::T
    T_base::T
    T_max::T
end

# Defining default values:
function ToyDegreeDaysCumulModel(; init_TT=0.0, T_base=10.0, T_max=43.0)
    parameters = promote(float(init_TT), float(T_base), float(T_max))
    return ToyDegreeDaysCumulModel(parameters...)
end

# Defining the inputs and outputs of the model:
PlantSimEngine.inputs_(::ToyDegreeDaysCumulModel) = NamedTuple()
PlantSimEngine.outputs_(m::ToyDegreeDaysCumulModel) = (
    TT=oftype(m.init_TT, -Inf),
    TT_cu=m.init_TT,
)
PlantSimEngine.environment_inputs_(m::ToyDegreeDaysCumulModel) = (T=zero(m.T_base),)

# Implementing the actual algorithm by adding a method to the run! function for our model:
function PlantSimEngine.run!(m::ToyDegreeDaysCumulModel, status, environment, constants=nothing, context=nothing)
    status.TT = max(zero(m.T_base), min(environment.T, m.T_max) - m.T_base)
    status.TT_cu += status.TT
end


# Declaring the process of LAI dynamic:
PlantSimEngine.@process "Degreedays" verbose = false

# Declaring the model of LAI dynamic with its parameter values:

"""
    ToyDegreeDaysCumulModel(;init_TT=0.0, T_base=10.0, T_max=43.0)

Computes the thermal time in degree days and cumulated degree-days based on the average daily temperature (`T`),
the initial cumulated degree days, the base temperature below which there is no growth, and the maximum 
temperature for growh.
"""
struct ToyDegreeDaysCumulModel <: AbstractDegreedaysModel
    init_TT::Float64
    T_base::Float64
    T_max::Float64
end

# Defining default values:
ToyDegreeDaysCumulModel(; init_TT=0.0, T_base=10.0, T_max=43.0) = ToyDegreeDaysCumulModel(init_TT, T_base, T_max)

# Defining the inputs and outputs of the model:
PlantSimEngine.inputs_(::ToyDegreeDaysCumulModel) = NamedTuple()
PlantSimEngine.outputs_(m::ToyDegreeDaysCumulModel) = (TT=-Inf, TT_cu=0.0,)

# Implementing the actual algorithm by adding a method to the run! function for our model:
function PlantSimEngine.run!(m::ToyDegreeDaysCumulModel, models, status, meteo, constants=nothing, extra=nothing)
    status.TT = max(0.0, min(meteo.T, m.T_max) - m.T_base)
    status.TT_cu += status.TT
end

# The computation of ToyDegreeDaysCumulModel dependents on previous values, but it is independent of other objects.
# The default trait is that models are dependent of other time-steps and object. So we need to change the default trait
# for objects:
PlantSimEngine.ObjectDependencyTrait(::Type{<:ToyDegreeDaysCumulModel}) = PlantSimEngine.IsObjectIndependent()
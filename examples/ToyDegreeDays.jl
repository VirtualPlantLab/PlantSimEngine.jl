
# Declaring the process of LAI dynamic:
@process "Degreedays" verbose = false

# Declaring the model of LAI dynamic with its parameter values:
struct ToyDegreeDaysCumulModel <: AbstractDegreedaysModel
    init_degreedays::Float64
end

# Defining default values:
ToyDegreeDaysCumulModel(init_degreedays=0.0) = ToyDegreeDaysCumulModel(init_degreedays)

# Defining the inputs and outputs of the model:
PlantSimEngine.inputs_(::ToyDegreeDaysCumulModel) = NamedTuple()
PlantSimEngine.outputs_(::ToyDegreeDaysCumulModel) = (degree_days_cu=-Inf,)

# Implementing the actual algorithm by adding a method to the run! function for our model:
function PlantSimEngine.run!(m::ToyDegreeDaysCumulModel, models, status, meteo, constants=nothing, extra=nothing)
    status.degree_days_cu =
        PlantMeteo.prev_value(status, :degree_days_cu, default=m.init_degreedays) + status.degree_days
    println("step = ", status.step)
end
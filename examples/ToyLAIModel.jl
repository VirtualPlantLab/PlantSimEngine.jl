
# Declaring the process of LAI dynamic:
PlantSimEngine.@process "LAI_Dynamic" verbose = false


# Declaring the model of LAI dynamic with its parameter values:
struct ToyLAIModel <: AbstractLai_DynamicModel
    max_lai::Float64
    dd_incslope::Int
    inc_slope::Float64
    dd_decslope::Int
    dec_slope::Float64
end

# Defining a method with keyword arguments and default values:
ToyLAIModel(; max_lai=8.0, dd_incslope=800, inc_slope=110, dd_decslope=1500, dec_slope=20) = ToyLAIModel(max_lai, dd_incslope, inc_slope, dd_decslope, dec_slope)

# Defining the inputs and outputs of the model:
PlantSimEngine.inputs_(::ToyLAIModel) = (TT_cu=-Inf,)
PlantSimEngine.outputs_(::ToyLAIModel) = (LAI=-Inf,)

# Implementing the actual algorithm by adding a method to the run! function for our model:
function PlantSimEngine.run!(::ToyLAIModel, models, status, meteo, constants=nothing, extra=nothing)
    status.LAI =
        models.LAI_Dynamic.max_lai *
        (1.0 /
         (1.0 + exp((models.LAI_Dynamic.dd_incslope - status.TT_cu) / models.LAI_Dynamic.inc_slope)) -
         1.0 / (1.0 + exp((models.LAI_Dynamic.dd_decslope - status.TT_cu) / models.LAI_Dynamic.dec_slope))
        )

    if status.LAI < 0.0
        status.LAI = 0.0
    end
end

# The computation of ToyLAIModel is independant of previous values and other objects. We can add this information as 
# traits to the model to tell PlantSimEngine that it is safe to run the models in parallel:
PlantSimEngine.TimeStepDependencyTrait(::Type{<:ToyLAIModel}) = PlantSimEngine.IsTimeStepIndependent()
PlantSimEngine.ObjectDependencyTrait(::Type{<:ToyLAIModel}) = PlantSimEngine.IsObjectIndependent()
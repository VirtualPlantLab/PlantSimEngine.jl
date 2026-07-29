
# Declaring the process of LAI dynamic:
PlantSimEngine.@process "LAI_Dynamic" verbose = false


# Declaring the model of LAI dynamic with its parameter values:

"""
    ToyLAIModel(;max_lai=8.0, dd_incslope=800, inc_slope=110, dd_decslope=1500, dec_slope=20)

Computes the Leaf Area Index (LAI) based on a sigmoid function of thermal time.

# Arguments

- `max_lai`: the maximum LAI value
- `dd_incslope`: the thermal time at which the LAI starts to increase
- `inc_slope`: the slope of the increase
- `dd_decslope`: the thermal time at which the LAI starts to decrease
- `dec_slope`: the slope of the decrease

# Inputs

- `TT_cu`: the cumulated thermal time since the beginning of the simulation, usually in °C days

# Outputs

- `LAI`: the Leaf Area Index, usually in m² m⁻²
"""
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
function PlantSimEngine.run!(model::ToyLAIModel, status, meteo, constants=nothing, extra=nothing)
    status.LAI =
        model.max_lai *
        (1.0 /
         (1.0 + exp((model.dd_incslope - status.TT_cu) / model.inc_slope)) -
         1.0 / (1.0 + exp((model.dd_decslope - status.TT_cu) / model.dec_slope))
        )

    if status.LAI < 0.0
        status.LAI = 0.0
    end
end

# ToyLAIModel is independent of previous values and other objects. The current
# public runtime remains sequential and owns execution policy.

# A second model at model scale:
"""
    ToyLAIfromLeafAreaModel()

Computes the Leaf Area Index (LAI) of the model based on the plants leaf area.

# Arguments

- `scene_area`: the area of the model, usually in m²

# Inputs

- `surface`: a vector of plant leaf surfaces, usually in m²

# Outputs

- `LAI`: the Leaf Area Index of the model, usually in m² m⁻²
- `total_surface`: the total surface of the plants, usually in m²
"""
struct ToyLAIfromLeafAreaModel{T} <: AbstractLai_DynamicModel
    scene_area::T
end

# Defining the inputs and outputs of the model:
PlantSimEngine.inputs_(::ToyLAIfromLeafAreaModel) = (plant_surfaces=[-Inf],)
PlantSimEngine.outputs_(::ToyLAIfromLeafAreaModel) = (LAI=-Inf, total_surface=-Inf)

# Implementing the actual algorithm by adding a method to the run! function for our model:
function PlantSimEngine.run!(m::ToyLAIfromLeafAreaModel, status, meteo, constants=nothing, extra=nothing)
    status.total_surface = sum(status.plant_surfaces)
    status.LAI = status.total_surface / m.scene_area
end

# ToyLAIfromLeafAreaModel is independent of previous values, but execution
# policy remains owned by the runtime.

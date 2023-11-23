
# Declaring the process of LAI dynamic:
PlantSimEngine.@process "organ_emergence" verbose = false

# Declaring the model of LAI dynamic with its parameter values:

"""
    ToyInternodeEmergence(;init_TT=0.0, TT_emergence = 300)

Computes the organ emergence based on cumulated thermal time since last event.
"""
struct ToyInternodeEmergence <: AbstractOrgan_EmergenceModel
    TT_emergence::Float64
end

# Defining default values:
ToyInternodeEmergence(; TT_emergence=300.0) = ToyInternodeEmergence(TT_emergence)

# Defining the inputs and outputs of the model:
PlantSimEngine.inputs_(m::ToyInternodeEmergence) = (TT_cu=-Inf,)
PlantSimEngine.outputs_(m::ToyInternodeEmergence) = (TT_cu_emergence=0.0,)

# Implementing the actual algorithm by adding a method to the run! function for our model:
function PlantSimEngine.run!(m::ToyInternodeEmergence, models, status, meteo, constants=nothing, sim_object=nothing)

    if length(status.node.children) == 1 && status.TT_cu - status.TT_cu_emergence >= m.TT_emergence
        # NB: the node can produce one leaf, and one internode only, so we check that it did not produce 
        # any internode yet.
        new_node = MultiScaleTreeGraph.Node(status.node, MultiScaleTreeGraph.NodeMTG("<", "Internode", 1, 2))
        status_new_node = PlantSimEngine.init_status!(new_node, sim_object.statuses, sim_object.status_templates, sim_object.map_other_scales, sim_object.var_need_init)
        leaf_node = MultiScaleTreeGraph.Node(new_node, MultiScaleTreeGraph.NodeMTG("+", "Leaf", 1, 2))
        PlantSimEngine.init_status!(leaf_node, sim_object.statuses, sim_object.status_templates, sim_object.map_other_scales, sim_object.var_need_init)

        status_new_node.TT_cu_emergence = status.TT_cu
    end

    return nothing
end
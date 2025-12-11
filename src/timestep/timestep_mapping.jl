
# TODO have a default constructor take in a meteo or something, and set up the default timestep automagically to be the finest weather timestep

# TODO type promotion for mapped timestep variables ?

struct ModelTimestepMapping
    model
    scale::String
    timestep::Period
end

mutable struct Orchestrator
    default_timestep::Period
    non_default_timestep_models::Vector{ModelTimestepMapping}
    
    function Orchestrator(default::Period, non_default_timestep_models::Vector{ModelTimestepMapping})
        @assert default >= Second(0) "The default_timestep should be greater than or equal to 0."
        return new(default, non_default_timestep_models)
    end
end

Orchestrator() = Orchestrator(Day(1), Vector{ModelTimestepMapping}())

Orchestrator(default::Period) = Orchestrator(default, Vector{ModelTimestepMapping}())


function init_timestep_mapping_data(node_mtg::MultiScaleTreeGraph.Node, dependency_graph)
    traverse_dependency_graph!(x -> register_mtg_node_in_timestep_mapping(x, node_mtg), dependency_graph, visit_hard_dep=false)
end

function register_mtg_node_in_timestep_mapping(node_dep::SoftDependencyNode, node_mtg::MultiScaleTreeGraph.Node)
    if isnothing(node_dep.timestep_mapping_data)
        return
    end

    # Having an extra level of indirection, mapping the MTG node to an index into a vector
    # Allows one to resize! the vector when it lacks space, saving in terms of # of memory allocations/copies, unsure if it'll be needed
    for mtsm in node_dep.timestep_mapping_data
        if node_dep.scale == symbol(node_mtg)
            push!(mtsm.mapping_data, node_id(node_mtg) => deepcopy(mtsm.mapping_data_template))
        end
    end
end
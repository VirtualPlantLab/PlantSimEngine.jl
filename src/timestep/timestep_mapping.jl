
# TODO have a default constructor take in a meteo or something, and set up the default timestep automagically to be the finest weather timestep

# TODO issue : what if the user wants to force initialize a variable that isn't at the default timestep ?
# This requires the ability to fit data with a vector that isn't at the default timestep
# As is, the current workaround is for the user to write their own model, I think, which is not ideal

# TODO check for cycles (and other errors) before timestep mapping, then do it again afterwards, as the new mapping dependencies might cause specific cycles.


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


function init_timestep_mapping_data(node_mtg::MultiScaleTreeGraph.Node, dependency_graph)
    traverse_dependency_graph!(x -> register_mtg_node_in_timestep_mapping(x, node_mtg), dependency_graph, visit_hard_dep=false)
end

function register_mtg_node_in_timestep_mapping(node_dep::SoftDependencyNode, node_mtg::MultiScaleTreeGraph.Node)
    if isnothing(node_dep.timestep_mapping_data)
        return
    end

    # no need to check the current softdependencynode's scale, I think
    # only the mapped downstream softdependencynodes

    # TODO having an extra level of indirection, mapping the MTG node to an index into a vector
    # Allows one to resize! the vector when it lacks space, saving in terms of # of memory allocations/copies
    for mtsm in node_dep.timestep_mapping_data
        if node_dep.scale == symbol(node_mtg)
            push!(mtsm.mapping_data, node_id(node_mtg) => deepcopy(mtsm.mapping_data_template))
        end
    end
end
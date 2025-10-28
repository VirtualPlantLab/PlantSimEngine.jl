
# Those names all suck, need to change them
# Some of them are probably not ideal for new users, too

# Some types can also be constrained a lot more, probably

# Many shortcuts will be taken, I'll try and comment what's missing/implicit/etc.

# TODO specify scale ?
struct TimestepMapper#{V}
    variable_from#::V
    timestep_from::Period # ? Not sure whether this is the best bit of info... Also, to or from ? And it should be a Period, no ?
    mapping_function
    mapping_data # TODO this should be internal
end

struct SimulationTimestepHandler#{W,V}
    model_timesteps::Dict{Any, Period} # where {W <: AbstractModel} # if a model isn't in there, then it follows the default, todo check if the given timestep respects the model's range
    timestep_variable_mapping::Dict{Any, TimestepMapper} #where {V}
end

SimulationTimestepHandler() = SimulationTimestepHandler(Dict{Any, Int}(), Dict{Any, TimestepMapper}()) #Dict{W, Int}(), Dict{V, TimestepMapper}()) where {W, V}

mutable struct Orchestrator
    # This is actually a general simulation parameter, not-scale specific 
    # todo change to Period
    default_timestep::Period

    # This needs to be per-scale : if a model is used at two different scales, 
    # and the same variable of that model maps to some other timestep to two *different* variables
    # then I believe we can only rely on the different scale to disambiguate
    non_default_timestep_data_per_scale::Dict{String, SimulationTimestepHandler}

    function Orchestrator(default::Period, per_scale::Dict{String, SimulationTimestepHandler})
        @assert default >= Second(0) "The default_timestep should be greater than or equal to 0."
        return new(default, per_scale)
    end
end

# TODO have a default constructor take in a meteo or something, and set up the default timestep automagically to be the finest weather timestep
# Other options are possible
Orchestrator() = Orchestrator(Day(1), Dict{String, SimulationTimestepHandler}())


#o = Orchestrator()
#oo = Orchestrator(1, Dict{String, SimulationTimestepHandler}())


# TODO issue : what if the user wants to force initialize a variable that isn't at the default timestep ?
# This requires the ability to fit data with a vector that isn't at the default timestep
# Automated model generation does not have that feature
# As is, the current workaround is for the user to write their own model, I think, which is not ideal

# TODO check for cycles (and other errors) before timestep mapping, then do it again afterwards, as the new mapping dependencies might cause specific cycles.


# TODO status initialisation ? 
# TODO type promotion for mapped timestep variables ?
# TODO check type if a variable is timestep mapped and scale mapped
# TODO simulation_id change consequences ?



# TODO prev timestep ? Vector mapping ?
struct Var_from
    model
    scale::String
    name::Symbol
    mapping_function::Function
    # mapping_data::Dict{NodeMTG, Vector{stuff}}
end

struct Var_to
    name::Symbol
end

struct ModelTimestepMapping
    model
    scale::String
    timestep::Period
    var_to_var::Dict{Var_to, Var_from}
end

mutable struct Orchestrator2
    default_timestep::Period
    non_default_timestep_mapping::Vector{ModelTimestepMapping}
    
    function Orchestrator2(default::Period, non_default_timestep_mapping::Vector{ModelTimestepMapping})
        @assert default >= Second(0) "The default_timestep should be greater than or equal to 0."
        return new(default, non_default_timestep_mapping)
    end
end

Orchestrator2() = Orchestrator2(Day(1), Vector{ModelTimestepMapping}())


# TODO parallelization, 

function init_timestep_mapping_data(node_mtg::MultiScaleTreeGraph.Node, dependency_graph)
    traverse_dependency_graph!(x -> register_mtg_node_in_timestep_mapping(x, node_mtg), dependency_graph, visit_hard_dep=false)
end

function register_mtg_node_in_timestep_mapping(node_dep::SoftDependencyNode, node_mtg::MultiScaleTreeGraph.Node)
    if isnothing(node_dep.timestep_mapping_data)
        return
    end

    # no need to check the current softdependencynode's scale, I think
    # only the mapped downstream softdependencynodes

    # TODO this structure doesn't play well with parallelisation... ?
    # TODO having an extra level of indirection, mapping the MTG node to an index into a vector
    # Allows one to resize! the vector when it lacks space, saving in terms of # of memory allocations/copies
    for mtsm in node_dep.timestep_mapping_data
        if node_dep.scale == symbol(node_mtg)
            push!(mtsm.mapping_data, node_id(node_mtg) => deepcopy(mtsm.mapping_data_template))
        end
    end
end
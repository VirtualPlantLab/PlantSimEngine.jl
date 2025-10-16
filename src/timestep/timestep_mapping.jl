
# Those names all suck, need to change them
# Some of them are probably not ideal for new users, too

# Some types can also be constrained a lot more, probably

struct TimestepMapper#{V}
    variable_from#::V
    timestep_from::Int
    mapping_function
end

struct SimulationTimestepHandler#{W,V}
    model_timesteps::Dict{Any, Int} # where {W <: AbstractModel} # if a model isn't in there, then it follows the default, todo check if the given timestep respects the model's range
    timestep_variable_mapping::Dict{Any, TimestepMapper} #where {V}
end

SimulationTimestepHandler() = SimulationTimestepHandler(Dict(), Dict()) #Dict{W, Int}(), Dict{V, TimestepMapper}()) where {W, V}

mutable struct Orchestrator
    # This is actually a general simulation parameter, not-scale specific 
    # todo change to Period
    default_timestep::Int64

    # This needs to be per-scale : if a model is used at two different scales, 
    # and the same variable of that model maps to some other timestep to two *different* variables
    # then I believe we can only rely on the different scale to disambiguate
    non_default_timestep_data_per_scale::Dict{String, SimulationTimestepHandler}

    function Orchestrator(default::Int64, per_scale::Dict{String, SimulationTimestepHandler})
        @assert default >= 0 "The default_timestep should be greater than or equal to 0."
        return new(default, per_scale)
    end
end

# TODO have a default constructor take in a meteo or something, and set up the default timestep automagically to be the finest weather timestep
# Other options are possible
Orchestrator() = Orchestrator(1, Dict{String, SimulationTimestepHandler}())


#o = Orchestrator()
#oo = Orchestrator(1, Dict{String, SimulationTimestepHandler}())
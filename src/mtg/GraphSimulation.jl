"""
    GraphSimulation(graph, mapping)
    GraphSimulation(graph, statuses, dependency_graph, models, outputs)

A type that holds all information for a simulation over a graph.

# Arguments

- `graph`: an graph, such as an MTG
- `mapping`: a dictionary of model mapping
- `statuses`: a structure that defines the status of each node in the graph
- `status_templates`: a dictionary of status templates
- `reverse_multiscale_mapping`: a dictionary of mapping for other scales
- `var_need_init`: a dictionary indicating if a variable needs to be initialized
- `dependency_graph`: the dependency graph of the models applied to the graph
- `models`: a dictionary of models
- `outputs`: a dictionary of outputs
"""
struct GraphSimulation{T,S,U,O,V}
    graph::T
    statuses::S
    status_templates::Dict{String,Dict{Symbol,Any}}
    reverse_multiscale_mapping::Dict{String,Dict{String,Dict{Symbol,Any}}}
    var_need_init::Dict{String,V}
    dependency_graph::DependencyGraph
    models::Dict{String,U}
    outputs::Dict{String,O}
    outputs_index::Dict{String, Int}
end

function GraphSimulation(graph, mapping; nsteps=1, outputs=nothing, type_promotion=nothing, check=true, verbose=false)
    GraphSimulation(init_simulation(graph, mapping; nsteps=nsteps, outputs=outputs, type_promotion=type_promotion, check=check, verbose=verbose)...)
end

dep(g::GraphSimulation) = g.dependency_graph
status(g::GraphSimulation) = g.statuses
status_template(g::GraphSimulation) = g.status_templates
reverse_mapping(g::GraphSimulation) = g.reverse_multiscale_mapping
var_need_init(g::GraphSimulation) = g.var_need_init
get_models(g::GraphSimulation) = g.models
outputs(g::GraphSimulation) = g.outputs

"""
    convert_outputs(sim_outputs::Dict{String,O} where O, sink; refvectors=false, no_value=nothing)
    convert_outputs(sim_outputs::TimeStepTable{T} where T, sink)

Convert the outputs returned by a simulation made on a plant graph into another format.

# Details

The first method operates on the outputs of a multiscale simulation, the second one on those of a typical single-scale simulation. 
The sink function determines the format used, for exemple a `DataFrame`.

# Arguments

- `sim_outputs : the outputs of a prior simulation, typically returned by `run!`.
- `sink`: a sink compatible with the Tables.jl interface (*e.g.* a `DataFrame`)
- `refvectors`: if `false` (default), the function will remove the RefVector values, otherwise it will keep them
- `no_value`: the value to replace `nothing` values. Default is `nothing`. Usually used to replace `nothing` values 
by `missing` in DataFrames.

# Examples

```@example
using PlantSimEngine, MultiScaleTreeGraph, DataFrames, PlantSimEngine.Examples
```

Import example models (can be found in the `examples` folder of the package, or in the `Examples` sub-modules): 

```jldoctest mylabel
julia> using PlantSimEngine.Examples;
```

$MAPPING_EXAMPLE

```@example
mtg = import_mtg_example();
```

```@example
out = run!(mtg, mapping, meteo, tracked_outputs = Dict(
    "Leaf" => (:carbon_assimilation, :carbon_demand, :soil_water_content, :carbon_allocation),
    "Internode" => (:carbon_allocation,),
    "Plant" => (:carbon_allocation,),
    "Soil" => (:soil_water_content,),
));
```

```@example
convert_outputs(out, DataFrames)
```
"""
function convert_outputs(outs::Dict{String,O} where O, sink; refvectors=false, no_value=nothing)
    @assert Tables.istable(sink) "The sink argument must be compatible with the Tables.jl interface (`Tables.istable(sink)` must return `true`, *e.g.* `DataFrame`)"


    variables_names_types = Iterators.flatten(collect(i.first => eltype(i.second[1]) for i in filter(x -> x.first != :node, vars)) for (organs, vars) in outs) |> collect
    variables_names_types_dict = Dict{Symbol,Any}()

    for (k, v) in variables_names_types
        if !haskey(variables_names_types_dict, k)
            variables_names_types_dict[k] = Union{typeof(no_value),v}
        else
            if !refvectors && v <: RefVector && !(variables_names_types_dict[k] <: Union{typeof(no_value),RefVector})
                continue
            end
            variables_names_types_dict[k] = Union{variables_names_types_dict[k],v}
        end
    end

    # If we have a variable that is only RefVector, we remove it from the variables_names_types:    
    !refvectors && filter!(x -> !(last(x) <: Union{typeof(no_value),RefVector}), variables_names_types_dict)

    variables_names_types = (timestep=Int, organ=String, node=Int, NamedTuple(variables_names_types_dict)...)
    var_names_all = keys(variables_names_types)
    t = NamedTuple{var_names_all,Tuple{values(variables_names_types)...}}[]

    for (organ, vars) in outs # organ = "Leaf"; vars = outs[organ]
        var_names = setdiff(collect(keys(vars)), [:node])
        if length(var_names) == 0
            continue
        end
        steps_iterable = axes(vars[var_names[1]], 1)
        for timestep in steps_iterable # timestep = 1
            node_iterable = axes(vars[var_names[1]][timestep], 1)
            for node in node_iterable # node = 1
                vals = Dict(zip(var_names, [something(vars[v][timestep][node], no_value) for v in var_names]))
                # Remove RefVector values:
                !refvectors && filter!(x -> !isa(x.second, RefVector), vals)
                vars_values = (; timestep=timestep, organ=organ, node=MultiScaleTreeGraph.node_id(vars[:node][timestep][node]), vals...)
                vars_no_values = setdiff(var_names_all, keys(vars_values))
                if length(vars_no_values) > 0
                    vars_values = (; vars_values..., zip(vars_no_values, [no_value for v in vars_no_values])...)
                end
                push!(
                    t,
                    NamedTuple{var_names_all}(vars_values)
                )
            end
        end
    end

    return sink(t)
end

function outputs(outs::Dict{String, O} where O, key::Symbol)
    Tables.columns(convert_outputs(outs, Vector{NamedTuple}))[key]
end

function outputs(outs::Dict{String, O} where O, i::T) where {T<:Integer}
    Tables.columns(convert_outputs(outs, Vector{NamedTuple}))[i]
end

# ModelLists now return outputs as a TimeStepTable{Status}, conversion is straightforward
function convert_outputs(out::TimeStepTable{T} where T, sink)
    @assert Tables.istable(sink) "The sink argument must be compatible with the Tables.jl interface (`Tables.istable(sink)` must return `true`, *e.g.* `DataFrame`)"      
    return sink(out)
end

function convert_outputs_2(outs::Dict{String,O} where O, sink; refvectors=false, no_value=nothing)
    ret = Dict{String, sink}()
    for (organ, vector_named_tuple) in outs
        ret[organ] = sink(vector_named_tuple)
    end
    return ret
end

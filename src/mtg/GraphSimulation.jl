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
- `Orchestrator : the structure that handles timestep peculiarities
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
    orchestrator::Orchestrator2

end

function GraphSimulation(graph, mapping; nsteps=1, outputs=nothing, type_promotion=nothing, check=true, verbose=false, orchestrator=Orchestrator2())
    GraphSimulation(init_simulation(graph, mapping; nsteps=nsteps, outputs=outputs, type_promotion=type_promotion, check=check, verbose=verbose, orchestrator=orchestrator)...)
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
# Another, possibly better way would be to just create the DataFrame directly from the outputs 
# and then remove the RefVector columns and replace the node one, hmm
function convert_outputs(outs::Dict{String,O} where O, sink; refvectors=false, no_value=nothing)
    ret = Dict{String, sink}()
    for (organ, status_vector) in outs
        # remove RefVector variables
        refv = ()
        if length(status_vector) > 0
            for (var, val) in pairs(status_vector[1])
                if !refvectors && isa(val, RefVector)
                    refv = (refv..., var)
                end
                if var == :node
                    refv = (refv..., var)
                end
            end
        else
            @warn "No instance found at the $organ scale, no output available, removing it from the Dict"
            continue
        end
       
        # Get the new NamedTuple type
        refv_nt = NamedTuple{refv}

        # Piddle around with the first element to get the final type to be able to allocate the exact vector size with a definite element type
        vector_named_tuple_1 = NamedTuple(status_vector[1])

        # replace the MTG node var with the id (MTG nodes aren't CSV-friendly)
        filtered_named_tuple = (;node=MultiScaleTreeGraph.node_id(vector_named_tuple_1.node),Base.structdiff(vector_named_tuple_1, refv_nt)...)
        filtered_vector_named_tuple = Vector{typeof(filtered_named_tuple)}(undef, length(status_vector))

        for i in 1:length(status_vector)
            vector_named_tuple_i = NamedTuple(status_vector[i])
            filtered_vector_named_tuple[i] = (;node=MultiScaleTreeGraph.node_id(vector_named_tuple_i.node), Base.structdiff(vector_named_tuple_i, refv_nt)...)
        end

        ret[organ] = sink(filtered_vector_named_tuple)
    end
    return ret
end

# TODO adapt these to new output structure or remove them
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
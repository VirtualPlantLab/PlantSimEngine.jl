"""
    init_statuses(mtg, mapping, dependency_graph=dep(mapping); type_promotion=nothing, verbose=true, check=true)
    
Get the status of each node in the MTG by node type, pre-initialised considering multi-scale variables.

# Arguments

- `mtg`: the plant graph
- `mapping`: a dictionary of model mapping
- `dependency_graph::DependencyGraph`: the first-order dependency graph where each model in the mapping is assigned a node. 
However, models that are identified as hard-dependencies are not given individual nodes. Instead, they are nested as child 
nodes under other models.
- `type_promotion`: the type promotion to use for the variables
- `verbose`: print information when compiling the mapping
- `check`: whether to check the mapping for errors. Passed to `init_node_status!`.

# Return

A NamedTuple of status by node type, a dictionary of status templates by node type, a dictionary of variables mapped to other scales,
a dictionary of variables that need to be initialised or computed by other models, and a vector of nodes that have a model defined for their symbol:

`(;statuses, status_templates, reverse_multiscale_mapping, vars_need_init, nodes_with_models)`
"""
function init_statuses(mtg, mapping, dependency_graph=hard_dependencies(mapping; verbose=false); type_promotion=nothing, verbose=false, check=true)
    # We compute the variables mapping for each scale:
    mapped_vars = mapped_variables(mapping, dependency_graph, verbose=verbose)

    # Update the types of the variables as desired by the user:
    convert_vars!(mapped_vars, type_promotion)

    # Compute the reverse multiscale dependencies, *i.e.* for each scale, which variable is mapped to the other scale
    reverse_multiscale_mapping = reverse_mapping(mapped_vars, all=false)
    # Note: this is used when we add a node value for such variable in the RefVector of the other scale.
    # Note 2: we use the `all=false` option to only get the variables that are mapped to another scale as a vector.
    # Note 3: we do it before `convert_reference_values!` because we need the variables to be MappedVar{MultiNodeMapping} to get the reverse mapping.

    # Convert the MappedVar{SelfNodeMapping} or MappedVar{SingleNodeMapping} to RefValues, and MappedVar{MultiNodeMapping} to RefVectors:
    convert_reference_values!(mapped_vars)

    # Get the variables that are not initialised or computed by other models in the output:
    vars_need_init = Dict(org => filter(x -> isa(last(x), UninitializedVar), vars) |> keys for (org, vars) in mapped_vars) |>
                     filter(x -> length(last(x)) > 0)

    # Note: these variables may be present in the MTG attributes, we check that below when traversing the MTG.

    # We traverse the MTG to initialise the statuses linked to the nodes:
    statuses = Dict(i => Status[] for i in collect(keys(mapped_vars)))
    MultiScaleTreeGraph.traverse!(mtg) do node # e.g.: node = MultiScaleTreeGraph.get_node(mtg, 5)
        init_node_status!(node, statuses, mapped_vars, reverse_multiscale_mapping, vars_need_init, type_promotion, check=check)
    end

    return (; statuses, mapped_vars, reverse_multiscale_mapping, vars_need_init)
end


"""
    init_node_status!(
        node, 
        statuses, 
        mapped_vars, 
        reverse_multiscale_mapping,
        vars_need_init=Dict{String,Any}(),
        type_promotion=nothing;
        check=true
    )

Initialise the status of a plant graph node, taking into account the multiscale mapping, and add it to the statuses dictionary.

# Arguments

- `node`: the node to initialise
- `statuses`: the dictionary of statuses by node type
- `mapped_vars`: the template of status for each node type
- `reverse_multiscale_mapping`: the variables that are mapped to other scales
- `var_need_init`: the variables that are not initialised or computed by other models
- `nodes_with_models`: the nodes that have a model defined for their symbol
- `type_promotion`: the type promotion to use for the variables
- `check`: whether to check the mapping for errors (see details)

# Details

Most arguments can be computed from the graph and the mapping:
- `statuses` is given by the first initialisation: `statuses = Dict(i => Status[] for i in nodes_with_models)`
- `mapped_vars` is computed using `mapped_variables()`, see code in `init_statuses`
- `vars_need_init` is computed using `vars_need_init = Dict(org => filter(x -> isa(last(x), UninitializedVar), vars) |> keys for (org, vars) in mapped_vars) |>
filter(x -> length(last(x)) > 0)`

The `check` argument is a boolean indicating if variables initialisation should be checked. In the case that some variables need initialisation (partially initialized mapping), we check if the value can be found 
in the node attributes (using the variable name). If `true`, the function returns an error if the attribute is missing, otherwise it uses the default value from the model.

"""
function init_node_status!(node, statuses, mapped_vars, reverse_multiscale_mapping, vars_need_init=Dict{String,Any}(), type_promotion=nothing; check=true)
    # Check if the node has a model defined for its symbol, if not, no need to compute
    symbol(node) ∉ collect(keys(mapped_vars)) && return

    # We make a copy of the template status for this node:
    st_template = copy(mapped_vars[symbol(node)])

    # We add a reference to the node into the status, so that we can access it from the models if needed.
    push!(st_template, :node => Ref(node))

    # If some variables still need to be instantiated in the status, look into the MTG node if we can find them,
    # and if so, use their value in the status:
    if haskey(vars_need_init, symbol(node)) && length(vars_need_init[symbol(node)]) > 0
        for var in vars_need_init[symbol(node)] # e.g. var = :carbon_biomass
            if !haskey(node, var)
                if !check
                    # If we don't check, we use the default value from the model (and if it's an UninitializedVar we take its default value):
                    if isa(st_template[var], UninitializedVar)
                        st_template[var] = st_template[var].value
                    end
                    continue
                end
                error("Variable `$(var)` is not computed by any model, not initialised by the user in the status, and not found in the MTG at scale $(symbol(node)) (checked for MTG node $(node_id(node))).")
            end
            # Applying the type promotion to the node attribute if needed:
            if isnothing(type_promotion)
                node_var = node[var]
            else
                node_var =
                    try
                        promoted_var_type = []
                        for (subtype, newtype) in type_promotion
                            if isa(node[var], subtype)
                                converted_var = convert(newtype, node[var])
                                @warn "Promoting `$(var)` value taken from MTG node $(node_id(node)) ($(symbol(node))) from $subtype to $newtype: $converted_var ($(typeof(converted_var)))" maxlog = 5
                                push!(promoted_var_type, converted_var)
                            end
                        end
                        length(promoted_var_type) > 0 ? promoted_var_type[1] : node[var]
                    catch e
                        error("Failed to convert variable `$(var)` in MTG node $(node_id(node)) ($(symbol(node))) from type `$(typeof(node[var]))` to type `$(eltype(st_template[var]))`: $(e)")
                    end
            end
            @assert typeof(node_var) == eltype(st_template[var]) string(
                "Initializing variable `$(var)` using MTG node $(node_id(node)) ($(symbol(node))): expected type $(eltype(st_template[var])), found $(typeof(node_var)). ",
                "Please check the type of the variable in the MTG, and make it a $(eltype(st_template[var])) by updating the model, or by using `type_promotion`."
            )
            st_template[var] = node_var
            # NB: the variable is not a reference to the value in the MTG, but a copy of it.
            # This is because we can't reference a value in a Dict. If we need a ref, the user can use a RefValue in the MTG directly,
            # and it will be automatically passed as is.
        end
    end

    # Make the node status from the template:
    st = status_from_template(st_template)

    push!(statuses[symbol(node)], st)

    # Instantiate the RefVectors on the fly for other scales that map into this scale, *i.e.*
    # add a reference to the value of any variable that is used by another scale into its RefVector:
    if haskey(reverse_multiscale_mapping, symbol(node))
        for (organ, vars) in reverse_multiscale_mapping[symbol(node)] # e.g.: organ = "Leaf"; vars = reverse_multiscale_mapping[symbol(node)][organ]
            for (var_source, var_target) in vars # e.g.: var_source = :soil_water_content; var_target = vars[var_source]
                push!(mapped_vars[organ][var_target], refvalue(st, var_source))
            end
        end
    end
    return st
end

"""
    status_from_template(d::Dict{Symbol,Any})

Create a status from a template dictionary of variables and values. If the values 
are already RefValues or RefVectors, they are used as is, else they are converted to Refs.

# Arguments

- `d::Dict{Symbol,Any}`: A dictionary of variables and values.

# Returns

- A [`Status`](@ref).

# Examples

```jldoctest mylabel
julia> using PlantSimEngine
```

```jldoctest mylabel
julia> a, b = PlantSimEngine.status_from_template(Dict(:a => 1.0, :b => 2.0));
```

```jldoctest mylabel
julia> a
1.0
```

```jldoctest mylabel
julia> b
2.0
```
"""
function status_from_template(d::Dict{Symbol,T} where {T})
    Status(NamedTuple(first(i) => ref_var(last(i)) for i in d))
end

"""
    ref_var(v)

Create a reference to a variable. If the variable is already a `Base.RefValue`,
it is returned as is, else it is returned as a Ref to the copy of the value,
or a Ref to the `RefVector` (in case `v` is a `RefVector`).

# Examples

```jldoctest mylabel
julia> using PlantSimEngine;
```

```jldoctest mylabel
julia> PlantSimEngine.ref_var(1.0)
Base.RefValue{Float64}(1.0)
```

```jldoctest mylabel
julia> PlantSimEngine.ref_var([1.0])
Base.RefValue{Vector{Float64}}([1.0])
```

```jldoctest mylabel
julia> PlantSimEngine.ref_var(Base.RefValue(1.0))
Base.RefValue{Float64}(1.0)
```

```jldoctest mylabel
julia> PlantSimEngine.ref_var(Base.RefValue([1.0]))
Base.RefValue{Vector{Float64}}([1.0])
```

```jldoctest mylabel
julia> PlantSimEngine.ref_var(PlantSimEngine.RefVector([Ref(1.0), Ref(2.0), Ref(3.0)]))
Base.RefValue{PlantSimEngine.RefVector{Float64}}(RefVector{Float64}[1.0, 2.0, 3.0])
```
"""
ref_var(v) = Base.Ref(copy(v))
ref_var(v::T) where {T<:AbstractString} = Base.Ref(v) # No copy method for strings, so directly making a Ref out of it
ref_var(v::T) where {T<:Base.RefValue} = v
ref_var(v::T) where {T<:RefVector} = Base.Ref(v)

"""
    init_simulation(mtg, mapping; nsteps=1, outputs=nothing, type_promotion=nothing, check=true, verbose=true)

Initialise the simulation. Returns:

- the mtg
- a status for each node by organ type, considering multi-scale variables
- the dependency graph of the models
- the models parsed as a Dict of organ type => NamedTuple of process => model mapping
- the pre-allocated outputs

# Arguments

- `mtg`: the MTG
- `mapping::Dict{String,Any}`: a dictionary of model mapping
- `nsteps`: the number of steps of the simulation
- `outputs`: the dynamic outputs needed for the simulation
- `type_promotion`: the type promotion to use for the variables
- `check`: whether to check the mapping for errors. Passed to `init_node_status!`.
- `verbose`: print information about errors in the mapping

# Details

The function first computes a template of status for each organ type that has a model in the mapping.
This template is used to initialise the status of each node of the MTG, taking into account the user-defined 
initialisation, and the (multiscale) mapping. The mapping is used to make references to the variables
that are defined at another scale, so that the values are automatically updated when the variable is changed at
the other scale. Two types of multiscale variables are available: `RefVector` and `MappedVar`. The first one is
used when the variable is mapped to a vector of nodes, and the second one when it is mapped to a single node. This 
is given by the user through the mapping, using a string for a single node (*e.g.* `=> "Leaf"`), and a vector of strings for a vector of
nodes (*e.g.* `=> ["Leaf"]` for one type of node or `=> ["Leaf", "Internode"]` for several). 

The function also computes the dependency graph of the models, i.e. the order in which the models should be
called, considering the dependencies between them. The dependency graph is used to call the models in the right order
when the simulation is run.

Note that if a variable is not computed by models or initialised from the mapping, it is searched in the MTG attributes. 
The value is not a reference to the one in the attribute of the MTG, but a copy of it. This is because we can't reference 
a value in a Dict. If you need a reference, you can use a `Ref` for your variable in the MTG directly, and it will be 
automatically passed as is.
"""
function init_simulation(mtg, mapping; nsteps=1, outputs=nothing, type_promotion=nothing, check=true, verbose=false)

    # Get the status of each node by node type, pre-initialised considering multi-scale variables:
    statuses, status_templates, reverse_multiscale_mapping, vars_need_init =
        init_statuses(mtg, mapping, hard_dependencies(mapping; verbose=false); type_promotion=type_promotion, verbose=verbose, check=check)

    # Print an info if models are declared for nodes that don't exist in the MTG:
    if check && any(x -> length(last(x)) == 0, statuses)
        model_no_node = join(findall(x -> length(x) == 0, statuses), ", ")
        @info "Models given for $model_no_node, but no node with this symbol was found in the MTG." maxlog = 1
    end

    models = Dict(first(m) => parse_models(get_models(last(m))) for m in mapping)

    outputs = pre_allocate_outputs(statuses, outputs, nsteps, check=check)

    return (; mtg, statuses, status_templates, reverse_multiscale_mapping, vars_need_init, dependency_graph=dep(mapping, verbose=verbose), models, outputs)
end
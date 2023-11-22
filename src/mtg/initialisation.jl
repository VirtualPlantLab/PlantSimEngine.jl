"""
    init_statuses(mtg, mapping; type_promotion=nothing, check=true)
    
Get the status of each node in the MTG by node type, pre-initialised considering multi-scale variables.
"""
function init_statuses(mtg, mapping; type_promotion=nothing, check=true)
    # We make a pre-initialised status for each kind of organ (this is a template for each node type):
    status_templates = status_template(mapping, type_promotion)
    # Get the reverse mapping, i.e. the variables that are mapped to other scales. This is used to initialise 
    # the RefVectors properly:
    map_other_scales = reverse_mapping(mapping, all=false)
    #NB: we use all=false because we only want the variables that are mapped as RefVectors.

    # We need to know which variables are not initialized, and not computed by other models:
    var_need_init = to_initialize(mapping, mtg)

    # If we find some, we return an error:
    check && error_mtg_init(var_need_init)

    nodes_with_models = collect(keys(status_templates))
    # We traverse the MTG to initialise the statuses linked to the nodes:
    statuses = Dict(i => Status[] for i in nodes_with_models)
    MultiScaleTreeGraph.traverse!(mtg) do node # e.g.: node = get_node(mtg, 5)
        init_status!(node, statuses, status_templates, map_other_scales, var_need_init, nodes_with_models)
    end

    return statuses
end


"""
    init_status!(
        node, 
        statuses, 
        status_templates, 
        map_other_scales, 
        var_need_init=Dict{String,Any}(), 
        nodes_with_models=collect(keys(status_templates))
    )

Initialise the status of a node, taking into account the multiscale mapping, and add it to the 
statuses dictionary.

# Arguments

- `node`: the node to initialise
- `statuses`: the dictionary of statuses by node type
- `status_templates`: the template of status for each node type
- `map_other_scales`: the variables that are mapped to other scales
- `var_need_init`: the variables that are not initialised or computed by other models
- `nodes_with_models`: the nodes that have a model defined for their symbol

# Details

Most arguments can be computed from the graph and the mapping:
- `statuses` is given by the first initialisation: `statuses = Dict(i => Status[] for i in nodes_with_models)`
- `status_templates` is computed usin `status_template(mappinxg, type_promotion)`
- `map_other_scales` is computed using `reverse_mapping(mapping, all=false)`. We use `all=false` because we only 
want the variables that are mapped as `RefVectors`
- `var_need_init` is computed using `to_initialize(mapping, mtg)`
- `nodes_with_models` is computed using `collect(keys(status_templates))`
"""
function init_status!(node, statuses, status_templates, map_other_scales, var_need_init=Dict{String,Any}(), nodes_with_models=collect(keys(status_templates)))
    # Check if the node has a model defined for its symbol, if not, no need to compute
    node.MTG.symbol ∉ nodes_with_models && return

    # We make a copy of the template status for this node:
    st_template = copy(status_templates[node.MTG.symbol])

    # We add a reference to the node into the status, so that we can access it from the models if needed.
    push!(st_template, :node => Ref(node))

    # If some variables still need to be instantiated in the status, look into the MTG node if we can find them,
    # and if so, use their value in the status:
    if haskey(var_need_init, node.MTG.symbol) && length(var_need_init[node.MTG.symbol].need_var_from_mtg) > 0
        for i in var_need_init[node.MTG.symbol].need_var_from_mtg
            @assert typeof(node[i.var]) == typeof(st_template[i.var]) string(
                "Initializing variable $(i.var) using MTG node $(node.id): expected type $(typeof(st_template[i.var])), found $(typeof(node[i.var])). ",
                "Please check the type of the variable in the MTG, and make it a $(typeof(st_template[i.var]))."
            )
            st_template[i.var] = node[i.var]
            # NB: the variable is not a reference to the value in the MTG, but a copy of it.
            # This is because we can't reference a value in a Dict. If we need a ref, the user can use a RefValue in the MTG directly,
            # and it will be automatically passed as is.
        end
    end

    # Make the node status from the template:
    st = status_from_template(st_template)

    push!(statuses[node.MTG.symbol], st)

    # Instantiate the RefVectors on the fly for other scales that map into this scale, *i.e.*
    # add a reference to the value of any variable that is used by another scale into its RefVector:
    if haskey(map_other_scales, node.MTG.symbol)
        for (organ, vars) in map_other_scales[node.MTG.symbol]
            for var in vars # e.g.: var = :carbon_demand
                push!(status_templates[organ][var], refvalue(st, var))
            end
        end
    end
end


"""
    status_template(models::Dict{String,Any}, type_promotion)

Create a status template for a given set of models and type promotion.

# Arguments
- `models::Dict{String,Any}`: A dictionary of models.
- `type_promotion`: The type promotion to use.

# Returns

- A dictionary with the organ types as keys, and a dictionary of variables => default values as values.

# Examples

```jldoctest mylabel
julia> using PlantSimEngine;
```

Import example models (can be found in the `examples` folder of the package, or in the `Examples` sub-modules): 

```jldoctest mylabel
julia> using PlantSimEngine.Examples;
```

```jldoctest mylabel
julia> models = Dict( \
            "Plant" => \
                MultiScaleModel( \
                    model=ToyCAllocationModel(), \
                    mapping=[ \
                        :A => ["Leaf"], \
                        :carbon_demand => ["Leaf", "Internode"], \
                        :carbon_allocation => ["Leaf", "Internode"] \
                    ], \
                ), \
            "Internode" => ToyCDemandModel(optimal_biomass=10.0, development_duration=200.0), \
            "Leaf" => ( \
                MultiScaleModel( \
                    model=ToyAssimModel(), \
                    mapping=[:soil_water_content => "Soil",], \
                ), \
                ToyCDemandModel(optimal_biomass=10.0, development_duration=200.0), \
                Status(aPPFD=1300.0, TT=10.0), \
            ), \
            "Soil" => ( \
                ToySoilWaterModel(), \
            ), \
        );
```

```jldoctest mylabel
julia> organs_statuses = PlantSimEngine.status_template(models, nothing)
Dict{String, Dict{Symbol, Any}} with 4 entries:
  "Soil"      => Dict(:soil_water_content=>RefValue{Float64}(-Inf))
  "Internode" => Dict(:carbon_allocation=>-Inf, :TT=>-Inf, :carbon_demand=>-Inf)
  "Plant"     => Dict(:carbon_allocation=>RefVector{Float64}[], :A=>RefVector{F…
  "Leaf"      => Dict(:carbon_allocation=>-Inf, :A=>-Inf, :TT=>10.0, :aPPFD=>13…
```

Note that variables that are multiscale (*i.e.* defined in a mapping) are linked between scales, so if we write at a scale, the value will be 
automatically updated at the other scale:

```jldoctest mylabel
julia> organs_statuses["Soil"][:soil_water_content] === organs_statuses["Leaf"][:soil_water_content]
true
```
"""
function status_template(mapping::Dict{String,T}, type_promotion) where {T}
    organs_mapping, var_outputs_from_mapping = compute_mapping(mapping, type_promotion)
    # Vector of pre-initialised variables with the default values for each variable, taking into account user-defined initialisation, and multiscale mapping:
    organs_statuses_dict = Dict{String,Dict{Symbol,Any}}()
    dict_mapped_vars = Dict{Pair,Any}()

    for organ in keys(mapping) # e.g.: organ = "Internode"
        # Parsing the models into a NamedTuple to get the process name:
        node_models = parse_models(get_models(mapping[organ]))

        # Get the status if any was given by the user (this can be used as default values in the mapping):
        st = get_status(mapping[organ]) # User status

        if isnothing(st)
            st = NamedTuple()
        else
            st = NamedTuple(st)
        end

        # Add the variables that are defined as multiscale (coming from other scales):
        if haskey(organs_mapping, organ)
            st_vars_mapped = (; zip(vars_from_mapping(organs_mapping[organ]), vars_type_from_mapping(organs_mapping[organ]))...)
            !isnothing(st_vars_mapped) && (st = merge(st, st_vars_mapped))
        end

        # Add the variable(s) written by other scales into this node scale:
        haskey(var_outputs_from_mapping, organ) && (st = merge(st, var_outputs_from_mapping[organ]))

        # Then we initialise a status taking into account the status given by the user.
        # This step is done to get default values for each variables:
        if length(st) == 0
            st = nothing
        else
            st = Status(st)
        end

        st = add_model_vars(st, node_models, type_promotion; init_fun=x -> Status(x))

        # For the variables that are RefValues of other variables at a different scale, we need to actually create a reference to this variable
        # in the status. So we replace the RefValue by a RefValue to the actual variable, and instantiate a Status directly with the actual Refs.
        val_pointers = Dict{Symbol,Any}(zip(keys(st), values(st)))
        if any(x -> isa(x, MappedVar), values(st))
            for (k, v) in val_pointers # e.g.: k = :soil_water_content; v = val_pointers[k]
                if isa(v, MappedVar)
                    # First time we encounter this variable as a MappedVar, we create its value into the dict_mapped_vars Dict:
                    if !haskey(dict_mapped_vars, v.organ => v.var)
                        push!(dict_mapped_vars, Pair(v.organ, v.var) => Ref(st[k].default))
                    end

                    # Then we replace the MappedVar by a RefValue to the actual variable:
                    val_pointers[k] = dict_mapped_vars[v.organ=>v.var]
                else
                    val_pointers[k] = st[k]
                end
            end
        end
        organs_statuses_dict[organ] = val_pointers
    end

    return organs_statuses_dict
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


# Return an error if some variables are not initialized or computed by other models in the output
# from to_initialize(models, organs_statuses)
function error_mtg_init(var_need_init)
    if length(var_need_init) > 0
        error_string = String[]
        for need_init in var_need_init
            organ_init = first(need_init)
            need_initialisation = last(need_init).need_initialisation

            # A model needs initialisations:
            if length(need_initialisation) > 0
                push!(
                    error_string,
                    "Nodes of type $organ_init need variable(s) $(join(need_initialisation, ", ")) to be initialized or computed by a model."
                )
            end

            # The mapping is wrong:
            need_models_from_scales = last(need_init).need_models_from_scales
            for er in need_models_from_scales
                var, scale, need_scales = er
                push!(
                    error_string,
                    "Nodes of type $need_scales should provide a model to compute variable `:$var` as input for nodes of type $scale, but none is provided."
                )
            end
        end

        if length(error_string) > 0
            error(join(error_string, "\n"))
        end
    end
end


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
- `check`: whether to check the mapping for errors
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
function init_simulation(mtg, mapping; nsteps=1, outputs=nothing, type_promotion=nothing, check=true, verbose=true)
    # Get the status of each node by node type, pre-initialised considering multi-scale variables:
    statuses = init_statuses(mtg, mapping; type_promotion=type_promotion, check=check)
    # Print an info if models are declared for nodes that don't exist in the MTG:
    if check && any(x -> length(last(x)) == 0, statuses)
        model_no_node = join(findall(x -> length(x) == 0, statuses), ", ")
        @info "Models given for $model_no_node, but no node with this symbol was found in the MTG." maxlog = 1
    end

    # Compute the multi-scale dependency graph of the models:
    dependency_graph = dep(mapping, verbose=verbose)

    models = Dict(first(m) => parse_models(get_models(last(m))) for m in mapping)

    outputs = pre_allocate_outputs(statuses, outputs, nsteps, check=check)

    return (; mtg, statuses, dependency_graph, models, outputs)
end
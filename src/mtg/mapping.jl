inputs_(m::MultiScaleModel) = inputs_(m.model)
outputs_(m::MultiScaleModel) = outputs_(m.model)


"""
    model(m::AbstractModel)

Get the model of an AbstractModel (it is the model itself if it is not a MultiScaleModel).
"""
model(m::AbstractModel) = m

# Functions to get the models from the dictionary that defines the mapping:

"""
    get_models(m)

Get the models of a dictionary of model mapping.

# Arguments

- `m::Dict{String,Any}`: a dictionary of model mapping

Returns a vector of models

# Examples

```jldoctest mylabel
julia> using PlantSimEngine
julia> include(joinpath(pkgdir(PlantSimEngine), "examples/ToyAssimModel.jl"));
julia> include(joinpath(pkgdir(PlantSimEngine), "examples/ToyCDemandModel.jl"));
julia> include(joinpath(pkgdir(PlantSimEngine), "examples/ToyCAllocationModel.jl"));
julia> include(joinpath(pkgdir(PlantSimEngine), "examples/ToySoilModel.jl"));
```

If we just give a MultiScaleModel, we get its model as a one-element vector:

```jldoctest mylabel
julia> models = MultiScaleModel(
            model=ToyCAllocationModel(),
            mapping=[
                :A => ["Leaf"],
                :carbon_demand => ["Leaf", "Internode"],
                :carbon_allocation => ["Leaf", "Internode"]
            ],
        );
```

```jldoctest mylabel
julia> get_models(models)
1-element Vector{ToyCAllocationModel}:
 ToyCAllocationModel()
```

If we give a tuple of models, we get each model in a vector:

```jldoctest mylabel
julia> models2 = (
        MultiScaleModel(
            model=ToyAssimModel(),
            mapping=[:soil_water_content => "Soil",],
            # Notice we provide "Soil", not ["Soil"], so a single value is expected here
        ),
        ToyCDemandModel(optimal_biomass=10.0, development_duration=200.0),
        Status(aPPFD=1300.0, TT=10.0),
    );
```

```jldoctest mylabel
julia> get_models(models2)
2-element Vector{AbstractModel}:
 ToyAssimModel{Float64}(0.2)
 ToyCDemandModel{Float64}(10.0, 200.0)
```
"""
get_models(m) = [model(i) for i in m if !isa(i, Status)]

# Get the models of a MultiScaleModel:
get_models(m::MultiScaleModel) = [model(m)]
# Note: it is returning a vector of models, because in this case the user provided a single MultiScaleModel instead of a vector of.

# Get the models of an AbstractModel:
get_models(m::AbstractModel) = [model(m)]

# Same, for the status (if any provided):

"""
    get_status(m)

Get the status of a dictionary of model mapping.

# Arguments

- `m::Dict{String,Any}`: a dictionary of model mapping

Returns a [`Status`](@ref) or `nothing`.

# Examples

See [`get_models`](@ref) for examples.
"""
function get_status(m)
    st = Status[i for i in m if isa(i, Status)]
    @assert length(st) <= 1 "Only one status can be provided for each organ type."
    length(st) == 0 && return nothing
    return first(st)
end

get_status(m::MultiScaleModel) = nothing
get_status(m::AbstractModel) = nothing

"""
    get_mapping(m)

Get the mapping of a dictionary of model mapping.

# Arguments

- `m::Dict{String,Any}`: a dictionary of model mapping

Returns a vector of pairs of symbols and strings or vectors of strings

# Examples

See [`get_models`](@ref) for examples.
"""
function get_mapping(m)
    mod_mapping = [mapping(i) for i in m if isa(i, MultiScaleModel)]
    if length(mod_mapping) == 0
        return Pair{Symbol,String}[]
    end
    return reduce(vcat, mod_mapping)
end

get_mapping(m::MultiScaleModel{T,S}) where {T,S} = mapping(m)
get_mapping(m::AbstractModel) = Pair{Symbol,String}[]

"""
    compute_mapping(models::Dict{String,Any}, type_promotion)

Compute the mapping of a dictionary of model mapping.

# Arguments

- `models::Dict{String,Any}`: a dictionary of model mapping
- `type_promotion`: the type promotion to use for the variables

# Returns

- organs_mapping: for each organ type, the variables that are mapped to other scales, how they are mapped (RefVector or RefValue)
and the nodes that are targeted by the mapping
- var_outputs_from_mapping: for each organ type, the variables that are written by a model at another scale and its default value


# Examples

```jldoctest mylabel
julia> using PlantSimEngine
julia> include(joinpath(pkgdir(PlantSimEngine), "examples/ToyAssimModel.jl"));
julia> include(joinpath(pkgdir(PlantSimEngine), "examples/ToyCDemandModel.jl"));
julia> include(joinpath(pkgdir(PlantSimEngine), "examples/ToyCAllocationModel.jl"));
julia> include(joinpath(pkgdir(PlantSimEngine), "examples/ToySoilModel.jl"));
```

```jldoctest mylabel
models = Dict(
    "Plant" =>
        MultiScaleModel(
            model=ToyCAllocationModel(),
            mapping=[
                # inputs
                :A => ["Leaf"],
                :carbon_demand => ["Leaf", "Internode"],
                # outputs
                :carbon_allocation => ["Leaf", "Internode"]
            ],
        ),
    "Internode" => ToyCDemandModel(optimal_biomass=10.0, development_duration=200.0),
    "Leaf" => (
        MultiScaleModel(
            model=ToyAssimModel(),
            mapping=[:soil_water_content => "Soil",],
            # Notice we provide "Soil", not ["Soil"], so a single value is expected here
        ),
        ToyCDemandModel(optimal_biomass=10.0, development_duration=200.0),
        Status(aPPFD=1300.0, TT=10.0),
    ),
)
```

```jldoctest mylabel
compute_mapping(models, nothing)
```
"""
function compute_mapping(models::Dict{String,Any}, type_promotion)
    # Initialise a dict that defines the multiscale variables for each organ type:
    organs_mapping = Dict{String,Any}()
    # Initialise a Dict that defines the variables that are outputs from a mapping, 
    # i.e. variables that are written by a model at another scale:
    var_outputs_from_mapping = Dict{String,Vector{Pair{Symbol,Any}}}()
    for organ in keys(models)
        # organ = "Leaf"
        map_vars = get_mapping(models[organ])
        if length(map_vars) == 0
            continue
        end

        multiscale_vars = collect(first(i) for i in map_vars)
        mods = get_models(models[organ])
        ins = merge(inputs_.(mods)...)
        outs = merge(outputs_.(mods)...)

        # Variables in the node that are defined as multiscale:
        multi_scale_ins = intersect(keys(ins), multiscale_vars) # inputs: variables that are taken from another scale
        multi_scale_outs = intersect(keys(outs), multiscale_vars) # outputs: variables that are written to another scale

        multi_scale_vars = Status(convert_vars(type_promotion, merge(ins[multi_scale_ins], outs[multi_scale_outs])))

        # Users can provide initialisation values in a status. We get them here:
        st = get_status(models[organ])

        # Add the values given by the user (initialisation) to the mapping, and make it a Status:
        if isnothing(st)
            new_st = multi_scale_vars
        else
            # If the user provided the multiscale variable in the status, and it is an output variable, 
            # we use those values for the mapping:
            for i in keys(multi_scale_vars)
                if i in multi_scale_outs && i in keys(st)
                    multi_scale_vars[i] = st[i]
                end
            end
            # NB: we do this only for multiscale outputs, because this output cannot be 
            # defined from the models at the target scale, so we need to add it to this other scale
            # as an output variable.

            new_st = Status(merge(NamedTuple(st), NamedTuple(multi_scale_vars)))
            diff_keys = intersect(keys(st), keys(multi_scale_vars))
            for i in diff_keys
                if isa(new_st[i], RefVector)
                    new_st[i][1] = st[i]
                else
                    new_st[i] = st[i]
                end
            end
        end

        # Add outputs from this scale as a variable for other scales:
        outputs_from_other_scale!(var_outputs_from_mapping, NamedTuple(new_st)[(multi_scale_outs)], map_vars)

        organ_mapping = Dict{Union{String,Vector{String}},Dict{Symbol,Union{RefVector,MappedVar}}}()
        for var_mapping in map_vars
            # var_mapping = map_vars[1]
            variable, organs_mapped = var_mapping

            ref_var = create_var_ref(organs_mapped, variable, getproperty(multi_scale_vars, variable))
            if haskey(organ_mapping, organs_mapped)
                push!(organ_mapping[organs_mapped], variable => ref_var)
            else
                organ_mapping[organs_mapped] = Dict(variable => ref_var)
            end

            # If the mapping is one node type only and is given as a string, we add the variable of the source scale 
            # as a MappedVar linked to itself, so we remember to not deepcopy when we build the status for the source node.
            # This is a special case for when the source scale only has one node in the MTG, and one variable is mapped.
            if isa(organs_mapped, AbstractString)
                if !haskey(organs_mapping, organs_mapped)
                    organs_mapping[organs_mapped] = Dict(organs_mapped => organ_mapping[organs_mapped])
                else
                    push!(organs_mapping[organs_mapped][organs_mapped], organ_mapping[organs_mapped])
                end
            end
        end
        organs_mapping[organ] = organ_mapping
    end

    for (k, v) in organs_mapping
        organs_mapping[k] = Dict(k => NamedTuple(v) for (k, v) in v)
    end

    var_outputs_from_mapping = Dict(k => NamedTuple(v) for (k, v) in var_outputs_from_mapping)

    return (; organs_mapping, var_outputs_from_mapping)
end

# Functions to get the variables from the mapping:
"""
    vars_from_mapping(m)

Get the variables that are used in the multiscale models.

# Arguments

- `m::Dict`: a dictionary of model mapping

Returns a dictionary of variables (values) to organs (keys)

See also `vars_type_from_mapping` to get the variables type.

# Examples

```jldoctest
vars_mapping = Dict(
    ["Leaf"] => Dict(:A => RefVector{Float64}[-Inf]), 
    ["Leaf", "Internode"] => Dict(
        :carbon_allocation => RefVector{Float64}[], 
        :carbon_demand => RefVector{Float64}[])
);
```

```jldoctest
julia> vars_from_mapping(vars_mapping)
3-element Vector{Symbol}:
 :A
 :carbon_allocation
 :carbon_demand
```
"""
vars_from_mapping(m) = collect(Iterators.flatten(keys.(values(m))))
vars_type_from_mapping(m) = collect(Iterators.flatten(values.(values(m))))

"""
    MappedVar(organ, var, default)

A variable mapped to another scale.

# Arguments

- `organ`: the organ(s) that are targeted by the mapping
- `var`: the variable that is mapped
- `default`: the default value of the variable

# Examples

```jldoctest
julia> using PlantSimEngine
```

```jldoctest
julia> MappedVar("Leaf", :A, 1.0)
```
"""
struct MappedVar{S<:Union{A,Vector{A}} where {A<:AbstractString},T}
    organ::S
    var::Symbol
    default::T
end

"""
    create_var_ref(organ::Vector{<:AbstractString}, default::T) where {T}
    create_var_ref(organ::AbstractString, default)

Create a referece variable. The reference is a `RefVector` if the organ is a vector of strings, and a `MappedVar` 
if it is a singleton string. This is because we want to avoid indeing into a vector of values if there is only one 
value to map.
"""
function create_var_ref(organ::Vector{<:AbstractString}, var, default::T) where {T}
    RefVector(Base.RefValue{T}[])
end

create_var_ref(organ::AbstractString, var, default) = MappedVar(organ, var, default)

function outputs_from_other_scale!(var_outputs_from_mapping, multi_scale_outs, map_vars)
    multi_scale_outs_organ = filter(x -> first(x) in keys(multi_scale_outs), map_vars)
    for (var, organs) in multi_scale_outs_organ # var, organs = multi_scale_outs_organ[1]
        if isa(organs, String)
            organs = [organs]
        end
        for org in organs # org = organs[1]
            if haskey(var_outputs_from_mapping, org)
                push!(var_outputs_from_mapping[org], var => multi_scale_outs[var])
            else
                var_outputs_from_mapping[org] = [var => multi_scale_outs[var]]
            end
        end
    end
end

"""
    init_simulation(mtg, models; type_promotion=nothing, check=true, verbose=true)

Initialise the simulation. Returns:

- the mtg
- a status for each node by organ type, considering multi-scale variables
- the dependency graph of the models
- the models parsed as a Dict of organ type => NamedTuple of process => model mapping

# Arguments

- `mtg`: the MTG
- `models::Dict{String,Any}`: a dictionary of model mapping
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
function init_simulation(mtg, models; type_promotion=nothing, check=true, verbose=true)
    # We make a pre-initialised status for each kind of organ (this is a template for each node type):
    organs_statuses = status_template(models, type_promotion)
    # Get the reverse mapping, i.e. the variables that are mapped to other scales. This is used to initialise 
    # the RefVectors properly:
    var_refvector = reverse_mapping(models, all=false)
    #NB: we use all=false because we only want the variables that are mapped as RefVectors.

    # We need to know which variables are not initialized, and not computed by other models:
    var_need_init = to_initialize(models, organs_statuses, mtg)

    # If we find some, we return an error:
    check && error_mtg_init(var_need_init)

    # Get the status of each node by node type, pre-initialised considering multi-scale variables:
    statuses = init_statuses(mtg, organs_statuses, var_refvector, var_need_init)

    # Print an info if models are declared for nodes that don't exist in the MTG:
    if check && any(x -> length(last(x)) == 0, statuses)
        model_no_node = join(findall(x -> length(x) == 0, statuses), ", ")
        @info "Models given for $model_no_node, but no node with this symbol was found in the MTG." maxlog = 1
    end

    # Compute the multi-scale dependency graph of the models:
    dependency_graph = multiscale_dep(models, verbose=verbose)

    models = Dict(first(m) => PlantSimEngine.parse_models(PlantSimEngine.get_models(last(m))) for m in models)

    return mtg, statuses, dependency_graph, models
end

"""
    GraphSimulation(graph, mapping)
    GraphSimulation(graph, statuses, dependency_graph)

A type that holds all information for a simulation over a graph.

# Arguments

- `graph`: an graph, such as an MTG
- `mapping`: a dictionary of model mapping
- `statuses`: a structure that defines the status of each node in the graph
- `dependency_graph`: the dependency graph of the models applied to the graph
"""
struct GraphSimulation{T,S}
    graph::T
    statuses::S
    dependency_graph::DependencyGraph
    models::Dict{String,NamedTuple}
end

function GraphSimulation(graph, mapping; type_promotion=nothing, check=true, verbose=true)
    GraphSimulation(init_simulation(graph, mapping; type_promotion=type_promotion, check=check, verbose=verbose)...)
end

dep(g::GraphSimulation) = g.dependency_graph
status(g::GraphSimulation) = g.statuses
get_models(g::GraphSimulation) = g.models

function map_scale(f, m, scale::String)
    map_scale(f, m, [scale])
end

function map_scale(f, m, scales::AbstractVector{String})
    map(s -> f(m, s), scales)
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
    status_template(models::Dict{String,Any}, type_promotion)

Create a status template for a given set of models and type promotion.

# Arguments
- `models::Dict{String,Any}`: A dictionary of models.
- `type_promotion`: The type promotion to use.

# Returns

- A dictionary with the organ types as keys, and a dictionary of variables => default values as values.

# Examples

```jldoctest mylabel
julia> using PlantSimEngine, Random
julia> include(joinpath(pkgdir(PlantSimEngine), "examples/ToyAssimModel.jl"));
julia> include(joinpath(pkgdir(PlantSimEngine), "examples/ToyCDemandModel.jl"));
julia> include(joinpath(pkgdir(PlantSimEngine), "examples/ToyCAllocationModel.jl"));
julia> include(joinpath(pkgdir(PlantSimEngine), "examples/ToySoilModel.jl"));
```

```jldoctest mylabel
julia> models = Dict(
            "Plant" =>
                MultiScaleModel(
                    model=ToyCAllocationModel(),
                    mapping=[
                        # inputs
                        :A => ["Leaf"],
                        :carbon_demand => ["Leaf", "Internode"],
                        # outputs
                        :carbon_allocation => ["Leaf", "Internode"]
                    ],
                ),
            "Internode" => ToyCDemandModel(optimal_biomass=10.0, development_duration=200.0),
            "Leaf" => (
                MultiScaleModel(
                    model=ToyAssimModel(),
                    mapping=[:soil_water_content => "Soil",],
                    # Notice we provide "Soil", not ["Soil"], so a single value is expected here
                ),
                ToyCDemandModel(optimal_biomass=10.0, development_duration=200.0),
                Status(aPPFD=1300.0, TT=10.0),
            ),
            "Soil" => (
                ToySoilWaterModel(),
            ),
        );
```

```jldoctest mylabel
julia> status_template(models, nothing)
Dict{String, Dict{Symbol, Any}} with 4 entries:
  "Soil"      => Dict(:soil_water_content=>RefValue{Float64}(-Inf))
  "Internode" => Dict(:carbon_allocation=>-Inf, :TT=>-Inf, :carbon_demand=>-Inf)
  "Plant"     => Dict(:carbon_allocation=>RefVector{Float64}[], :A=>RefVector{Float64}[], :carbon_offer=>-Inf, :carbon_demand=>RefVector{Float64}[])
  "Leaf"      => Dict(:carbon_allocation=>-Inf, :A=>-Inf, :TT=>10.0, :aPPFD=>1300.0, :soil_water_content=>RefValue{Float64}(-Inf), :carbon_demand=>-Inf)
```

Note that variables that are multiscale (*i.e.* defined in a mapping) are linked between scales, so if we write at a scale, the value will be 
automatically updated at the other scale:

```jldoctest mylabel
organs_statuses["Soil"][:soil_water_content] === organs_statuses["Leaf"][:soil_water_content]
true
```
"""
function status_template(models::Dict{String,Any}, type_promotion)
    organs_mapping, var_outputs_from_mapping = compute_mapping(models, type_promotion)
    # Vector of pre-initialised variables with the default values for each variable, taking into account user-defined initialisation, and multiscale mapping:
    organs_statuses_dict = Dict{String,Dict{Symbol,Any}}()
    dict_mapped_vars = Dict{Pair,Any}()

    for organ in keys(models) # e.g.: organ = "Internode"
        # Parsing the models into a NamedTuple to get the process name:
        node_models = parse_models(get_models(models[organ]))

        # Get the status if any was given by the user (this can be used as default values in the mapping):
        st = get_status(models[organ]) # User status

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
julia> a, b = status_from_template(Dict(:a => 1.0, :b => 2.0));
julia> a
1.0
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
it is returned as is, else it is returned as a Ref to the copy of the value, or a 
or a Ref to the `RefVector` (in case `v` is a `RefVector`).

# Examples

```jldoctest mylabel
julia> using PlantSimEngine
julia> ref_var(1.0)
Base.RefValue{Float64}(1.0)
```

```jldoctest mylabel
julia> ref_var([1.0])
Base.RefValue{Vector{Float64}}([1.0])
```

```jldoctest mylabel
julia> ref_var(Base.RefValue(1.0))
Base.RefValue{Float64}(1.0)
```

```jldoctest mylabel
julia> ref_var(Base.RefValue([1.0]))
Base.RefValue{Vector{Float64}}([1.0])
```

```jldoctest mylabel
julia> ref_var(RefVector([Ref(1.0), Ref(2.0), Ref(3.0)]))
Base.RefValue{RefVector{Float64}}(RefVector{Float64}[1.0, 2.0, 3.0])
```
"""
ref_var(v) = Base.Ref(copy(v))
ref_var(v::T) where {T<:Base.RefValue} = v
ref_var(v::T) where {T<:RefVector} = Base.Ref(v)


"""
    reverse_mapping(models; all=true)

Get the reverse mapping of a dictionary of model mapping, *i.e.* the variables that are mapped to other scales.
This is used for *e.g.* knowing which scales are needed to add values to others.

# Arguments

- `models::Dict{String,Any}`: A dictionary of model mapping.
- `all::Bool`: Whether to get all the variables that are mapped to other scales, including the ones that are mapped as single values.

# Returns

- A dictionary of variables (keys) to a dictionary (values) of organs => vector of variables.

# Examples

```jldoctest mylabel
julia> using PlantSimEngine
julia> include(joinpath(pkgdir(PlantSimEngine), "examples/ToyAssimModel.jl"));
julia> include(joinpath(pkgdir(PlantSimEngine), "examples/ToyCDemandModel.jl"));
julia> include(joinpath(pkgdir(PlantSimEngine), "examples/ToyCAllocationModel.jl"));
julia> include(joinpath(pkgdir(PlantSimEngine), "examples/ToySoilModel.jl"));
```

```jldoctest mylabel
julia> models = Dict(
            "Plant" =>
                MultiScaleModel(
                    model=ToyCAllocationModel(),
                    mapping=[
                        # inputs
                        :A => ["Leaf"],
                        :carbon_demand => ["Leaf", "Internode"],
                        # outputs
                        :carbon_allocation => ["Leaf", "Internode"]
                    ],
                ),
            "Internode" => ToyCDemandModel(optimal_biomass=10.0, development_duration=200.0),
            "Leaf" => (
                MultiScaleModel(
                    model=ToyAssimModel(),
                    mapping=[:soil_water_content => "Soil",],
                    # Notice we provide "Soil", not ["Soil"], so a single value is expected here
                ),
                ToyCDemandModel(optimal_biomass=10.0, development_duration=200.0),
                Status(aPPFD=1300.0, TT=10.0),
            ),
            "Soil" => (
                ToySoilWaterModel(),
            ),
        );
```

```jldoctest mylabel
julia> reverse_mapping(models)
Dict{String, Any} with 2 entries:
  "Internode" => Dict("Plant"=>[:carbon_demand, :carbon_allocation])
  "Leaf"      => Dict("Plant"=>[:A, :carbon_demand, :carbon_allocation])
```
"""
function reverse_mapping(models; all=true)
    var_to_ref = Dict{String,Any}(i => Dict{String,Vector{Symbol}}() for i in keys(models))
    for organ in keys(models)
        # organ = "Plant"
        map_vars = get_mapping(models[organ])
        for i in map_vars # e.g.: i = :carbon_demand => ["Leaf", "Internode"] 
            mapped = last(i) # e.g.: mapped = ["Leaf", "Internode"]

            # If we want to get all the variables that are mapped to other scales, including the ones that are mapped as single values:
            isa(mapped, AbstractString) && all && (mapped = [mapped])

            if isa(mapped, Vector)
                for j in mapped # e.g.: j = "Leaf"
                    if haskey(var_to_ref[j], organ)
                        push!(var_to_ref[j][organ], first(i))
                    else
                        var_to_ref[j][organ] = [first(i)]
                    end
                end
            end
        end
    end

    return filter!(x -> length(last(x)) > 0, var_to_ref)
end

"""
    init_statuses(mtg, models, status_template, var_need_init)
    init_statuses(mtg, models, status_template)

Get the status of each node in the MTG by node type, pre-initialised considering multi-scale variables
using the template given by `status_template`.
"""
function init_statuses(mtg, status_template, var_refvector, var_need_init=Dict{String,Any}())
    nodes_with_models = collect(keys(status_template))
    # We traverse the MTG to initialise the statuses linked to the nodes:
    statuses = Dict(i => Status[] for i in nodes_with_models)
    MultiScaleTreeGraph.traverse!(mtg) do node # e.g.: node = get_node(mtg, 5)
        # Check if the node has a model defined for its symbol
        node.MTG.symbol ∉ nodes_with_models && return

        # We make a copy of the template status for this node:
        st_template = copy(status_template[node.MTG.symbol])

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
        if haskey(var_refvector, node.MTG.symbol)
            for (organ, vars) in var_refvector[node.MTG.symbol]
                for var in vars # e.g.: var = :carbon_demand
                    push!(status_template[organ][var], refvalue(st, var))
                end
            end
        end
    end
    return statuses
end

"""
    variables_multiscale(node, organ, mapping)

Get the variables of a HardDependencyNode, taking into account the multiscale mapping, *i.e.*
defining variables as `MappedVar` if they are mapped to another scale.
"""
function variables_multiscale(node, organ, mapping)
    map(variables(node)) do vars
        vars_ = Vector{Union{Symbol,PlantSimEngine.MappedVar}}()
        for var in vars # e.g. var = :soil_water_content
            if haskey(mapping[organ], var)
                push!(vars_, PlantSimEngine.MappedVar(mapping[organ][var], var, nothing))
            else
                push!(vars_, var)
            end
        end
        return (vars_...,)
    end
end
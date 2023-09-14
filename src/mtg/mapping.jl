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
get_models(m::AbstractModel) = model(m)

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
    ["Leaf"] => Dict(:A => PlantSimEngine.RefVector{Float64}[-Inf]), 
    ["Leaf", "Internode"] => Dict(
        :carbon_allocation => PlantSimEngine.RefVector{Float64}[], 
        :carbon_demand => PlantSimEngine.RefVector{Float64}[])
);
```

```jldoctest
julia> PlantSimEngine.vars_from_mapping(vars_mapping)
3-element Vector{Symbol}:
 :A
 :carbon_allocation
 :carbon_demand
```
"""
vars_from_mapping(m) = collect(Iterators.flatten(keys.(values(m))))
vars_type_from_mapping(m) = collect(Iterators.flatten(values.(values(m))))

"""
    create_var_ref(organ::Vector{<:AbstractString}, default::T) where {T}
    create_var_ref(organ::AbstractString, default)

Create a RefVector from a vector of organs and a default value. The RefVector will be filled with the default value.

Create the reference to a multiscale variable. The reference is a RefVector if the organ was given as a vector, or a Ref if it is a scalar.
"""
function create_var_ref(organ::Vector{<:AbstractString}, var, default::T) where {T}
    RefVector(Base.RefValue{T}[])
end

#! reverse parameter order , it is more logical
struct MappedVar{S<:AbstractString,T}
    organ::S
    var::Symbol
    default::T
end

function create_var_ref(organ::AbstractString, var, default)
    MappedVar(organ, var, default)
end

function outputs_from_other_scale!(var_outputs_from_mapping, multi_scale_outs, map_vars)
    multi_scale_outs_organ = filter(x -> first(x) in keys(multi_scale_outs), map_vars)
    for (var, organs) in multi_scale_outs_organ
        # var, organs = multi_scale_outs_organ[1]
        if isa(organs, String)
            organs = [organs]
        end
        for org in organs
            # org = organs[1]
            if haskey(var_outputs_from_mapping, org)
                push!(var_outputs_from_mapping[org], var => multi_scale_outs[var])
            else
                var_outputs_from_mapping[org] = [var => multi_scale_outs[var]]
            end
        end
    end
end

# Initialisations with the mapping:
function init_simulation!(mtg, models; type_promotion=nothing, check=true)
    # if check
    #     attr_name_sym = Set(keys(models))
    #     multiscale_vars_names = collect(keys(multiscale_vars))
    #     for i in multiscale_vars_names
    #         if isa(i, Vector{String})
    #             for n in i
    #                 push!(attr_name_sym, n)
    #             end
    #         else
    #             push!(attr_name_sym, i)
    #         end
    #     end
    #     # Check if all components have a model
    #     component_no_models = setdiff(MultiScaleTreeGraph.components(mtg), attr_name_sym)
    #     if length(component_no_models) > 0
    #         @info string("No model found for component(s) ", join(component_no_models, ", ", ", and ")) maxlog = 1
    #     end
    # end

    # Initialise a dict that defines the multiscale variables for each organ type:
    organs_mapping = Dict{String,Any}()
    # Initialise a Dict that defines the variables that are outputs from a mapping, 
    # i.e. variables that are written by a model at another scale:
    var_outputs_from_mapping = Dict{String,Vector{Pair{Symbol,Any}}}()
    for organ in keys(models)
        # organ = "Leaf"
        map_vars = PlantSimEngine.get_mapping(models[organ])
        if length(map_vars) == 0
            continue
        end

        multiscale_vars = collect(first(i) for i in map_vars)
        mods = PlantSimEngine.get_models(models[organ])
        ins = merge(PlantSimEngine.inputs_.(mods)...)
        outs = merge(PlantSimEngine.outputs_.(mods)...)

        # Variables in the node that are defined as multiscale:
        multi_scale_ins = intersect(keys(ins), multiscale_vars) # inputs: variables that are taken from another scale
        multi_scale_outs = intersect(keys(outs), multiscale_vars) # outputs: variables that are written to another scale

        multi_scale_vars = Status(PlantSimEngine.convert_vars(type_promotion, merge(ins[multi_scale_ins], outs[multi_scale_outs])))

        # Users can provide initialisation values in a status. We get them here:
        st = PlantSimEngine.get_status(models[organ])

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
            diff = intersect(keys(st), keys(multi_scale_vars))
            for i in diff
                if isa(new_st[i], PlantSimEngine.RefVector)
                    new_st[i][1] = st[i]
                else
                    new_st[i] = st[i]
                end
            end
        end

        # Add outputs from this scale as a variable for other scales:
        PlantSimEngine.outputs_from_other_scale!(var_outputs_from_mapping, NamedTuple(new_st)[(multi_scale_outs)], map_vars)

        organ_mapping = Dict{Union{String,Vector{String}},Dict{Symbol,Union{PlantSimEngine.RefVector,PlantSimEngine.MappedVar}}}()
        for var_mapping in map_vars
            # var_mapping = map_vars[1]
            variable, organs_mapped = var_mapping

            if haskey(organ_mapping, organs_mapped)
                push!(organ_mapping[organs_mapped], variable => PlantSimEngine.create_var_ref(organs_mapped, variable, getproperty(multi_scale_vars, variable)))
            else
                organ_mapping[organs_mapped] = Dict(variable => PlantSimEngine.create_var_ref(organs_mapped, variable, getproperty(multi_scale_vars, variable)))
            end
        end

        organs_mapping[organ] = Dict(k => NamedTuple(v) for (k, v) in organ_mapping)
        # organs_mapping[organ] = organ_mapping
    end

    # Output of the code above: 
    # - organs_mapping: for each organ type, the variables that are mapped to other scales, how they are mapped (RefVector or RefValue)
    #   and the nodes that are targeted by the mapping
    # - var_outputs_from_mapping: for each organ type, the variables that are written by a model at another scale and its default value

    var_outputs_from_mapping = Dict(k => NamedTuple(v) for (k, v) in var_outputs_from_mapping)

    #! recommencer par ici. Ce qu'il faut que je fasse: 
    #! 1. instantier des RefVector{Type} pour chaque variable multiscale, pour chaque type de mapping, e.g. :A => ["Leaf, "Internode"]
    #! 2. créer un Status pour chaque noeud de façon usuelle, sauf que:
    #!      - pour les variables multiscale, que l'on instancie en utilisant les RefVector vides.
    #!      - pour les variables multiscale qui sont des outputs d'autres échelles, on doit créer la variable avec une bonne valeur par défaut.
    #! 3. traverser les MTG pour remplir les RefVector, sachant qu'ils seront automatiquement remplis partout puisque c'est des Ref (a vérifier).
    #! 4. ajouter des checks, par exemple une variable output
    #! 5. faire un tableau de status, qui potentiellement référence le noeud. Et faire une `sort` en fonction de l'arbre de dépendence multi-échelle
    #! 6. ajouter des tests

    # Vector of statuses, pre-initialised with the default values for each variable, taking into account user-defined initialisation, and multiscale mapping:
    organs_statuses = Dict{String,Status}()
    #! what we need to do here:
    #! 1. get the models for the node
    #! 2. get the variables that are defined as multiscale (used by other scales),
    #!    and use them as default values for the status (do not forget to remove the default value at some point)
    #!    (check why we need a default value here, it was used for the output at the other scale but may not be needed anymore)
    #! 3. get the variables that are written by a model from another scale (if so), and add them to the status
    #! tip: utiliser `var_outputs_from_mapping` pour ajouter les variables dans le status
    #! des échelles cibles. (Dict de échelle cible: variables à ajouter)

    # We make a pre-initialised status for each kind of organ:
    for organ in keys(models)
        # organ = "Soil"
        # Parsing the models into a NamedTuple to get the process name:
        node_models = PlantSimEngine.parse_models(PlantSimEngine.get_models(models[organ]))

        # Get the status if any was given by the user (this can be used as default values in the mapping):
        st = PlantSimEngine.get_status(models[organ]) # User status

        if isnothing(st)
            st = NamedTuple()
        else
            st = NamedTuple(st)
        end

        # Add the variables that are defined as multiscale (coming from other scales):
        if haskey(organs_mapping, organ)
            st_vars_mapped = (; zip(PlantSimEngine.vars_from_mapping(organs_mapping[organ]), PlantSimEngine.vars_type_from_mapping(organs_mapping[organ]))...)
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

        st = PlantSimEngine.add_model_vars(st, node_models, type_promotion; init_fun=x -> Status(x))
        # The status is added to the vector of statuses.
        push!(organs_statuses, organ => st)
    end

    # For the variables that are RefValues of other variables at a different scale, we need to actually create a reference to this variable
    # in the status. So we replace the RefValue by a RefValue to the actual variable, and instantiate a Status directly with the actual Refs.
    for (organ, st) in organs_statuses # e.g.: organ = "Leaf"; st = organs_statuses[organ]
        # If there is any MappedVar in the status:
        if any(x -> isa(x, PlantSimEngine.MappedVar), values(st))
            val_pointers = Dict{Symbol,Any}(zip(keys(st), values(st)))
            for (k, v) in val_pointers
                if isa(v, PlantSimEngine.MappedVar)
                    val_pointers[k] = PlantSimEngine.refvalue(organs_statuses[val.organ], val.var)
                else
                    val_pointers[k] = PlantSimEngine.refvalue(st, k)
                end
            end
            organs_statuses[organ] = Status(NamedTuple(val_pointers))
        end
    end

    #! continue here. What we need to do:
    #! 3. traverser les MTG pour remplir les RefVector, sachant qu'ils seront automatiquement remplis partout puisque c'est des Ref (a vérifier).
    #! 4. ajouter des checks, par exemple une variable output
    #! 5. faire un tableau de status, qui potentiellement référence le noeud. Et faire une `sort` en fonction de l'arbre de dépendence multi-échelle
    #! 6. ajouter des tests
    statuses = Status[]
    # We traverse the MTG to initialise the mapping depending on the number of nodes and their types
    traverse!(mtg) do node
        # Check if the node has a model defined for its symbol:
        # node = get_node(mtg, 1)
        push!(statuses, organs_statuses[node.MTG.symbol])
        organs_statuses
    end
end
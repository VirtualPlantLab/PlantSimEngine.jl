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

            ref_var = PlantSimEngine.create_var_ref(organs_mapped, variable, getproperty(multi_scale_vars, variable))
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
    create_var_ref(organ::Vector{<:AbstractString}, default::T) where {T}
    create_var_ref(organ::AbstractString, default)

Create a RefVector from a vector of organs and a default value. The RefVector will be filled with the default value.

Create the reference to a multiscale variable. The reference is a RefVector if the organ was given as a vector, or a Ref if it is a scalar.
"""
function create_var_ref(organ::Vector{<:AbstractString}, var, default::T) where {T}
    RefVector(Base.RefValue{T}[])
end

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
    # We make a pre-initialised status for each kind of organ (this is a template for each node type):
    organs_statuses = PlantSimEngine.status_template(models, type_promotion)

    # We need to know which variables are not initialized, and not computed by other models:
    var_need_init = PlantSimEngine.to_initialize(models, organs_statuses, mtg)

    # If we find some, we return an error:
    check && PlantSimEngine.error_mtg_init(var_need_init)

    #! continue here. What we need to do:
    #!  - traverser les MTG pour initialiser un Status par organe, et mettre le vecteur de ces status dans un Dict{Organe, Status}
    #!  - dans le même traversal, trouver les variables qui doivent être initialisées depuis le mtg (et erreur si elles n'y sont pas)
    #!  - remplir les RefVector, sachant qu'ils seront automatiquement remplis partout puisque c'est des Ref (a vérifier).
    #!  - Ajouter la référence au noeud dans le status ? 
    #!  - calculer le graphe de dépendence des modèles, et faire des calls en fonction
    #!  - ajouter des tests
    #!  - ajouter des checks, e.g. est-ce que tous les organes du MTG ont un modèle ou pas...

    organs_statuses_dict = Dict{String,Dict{Symbol,Any}}()
    dict_mapped_vars = Dict{Pair,Any}()
    # # For the variables that are RefValues of other variables at a different scale, we need to actually create a reference to this variable
    # # in the status. So we replace the RefValue by a RefValue to the actual variable, and instantiate a Status directly with the actual Refs.
    for (organ, st) in organs_statuses # e.g.: organ = "Soil"; st = organs_statuses[organ]
        val_pointers = Dict{Symbol,Any}(zip(keys(st), values(st)))
        # If there is any MappedVar in the status:
        if any(x -> isa(x, PlantSimEngine.MappedVar), values(st))
            for (k, v) in val_pointers # e.g.: k = :soil_water_content; v = val_pointers[k]
                if isa(v, PlantSimEngine.MappedVar)
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

    #! Continue here (bis): use organs_statuses_dict to initialise the MTG nodes statuses. The Status will be created manually
    #! to control the references. 
    #! Standard values will be copied and a reference to this copy will be used. 
    #! RefValues will be used as is (i.e. the reference will be passed to the Status)
    #! RefVector will be passes as is, and instantiated on the fly traversing the MTG.

    nodes_with_models = collect(keys(organs_statuses))
    # We traverse the MTG a first time to initialise the statuses linked to the nodes:
    statuses = Dict(i => Status[] for i in nodes_with_models)
    traverse!(mtg) do node # e.g.: node = get_node(mtg, 5)
        if node.MTG.symbol in nodes_with_models # Check if the node has a model defined for its symbol
            # If there is any MappedVar in the status:
            st = organs_statuses[node.MTG.symbol]
            if any(x -> isa(x, PlantSimEngine.MappedVar), values(st))
                val_pointers = Dict{Symbol,Any}(zip(keys(st), values(st)))
                for (k, v) in val_pointers
                    if isa(v, PlantSimEngine.MappedVar)
                        val_pointers[k] = PlantSimEngine.refvalue(organs_statuses[v.organ], v.var)
                    else
                        val_pointers[k] = PlantSimEngine.refvalue(st, k)
                    end
                end
                st = Status(NamedTuple(val_pointers))
            else
                st = deepcopy(st)
            end

            push!(statuses[node.MTG.symbol], st)
        end
    end
    #! 1. For the soil_water_content of the soil, we need a way to know that it will be mapped,
    #!  so we need to reference the original status, not deepcopying it. We should use a MappedVar
    #!  too, referencing the "Soil" type of node in the template (i.e. itself).
    #! 2. We need a way to know if a variable of a node needs to be pushed into a RefVector of another scale,
    #!  so this way we only traverse the MTG once and push into the RefVector of the template status.

    # Print an info if models are declared for nodes that don't exist in the MTG:
    if check && any(x -> length(last(x)) == 0, statuses)
        model_no_node = join(findall(x -> length(x) == 0, statuses), ", ")
        @info "Models given for $model_no_node, but no node with this symbol was found in the MTG." maxlog = 1
    end

    push!(statuses[1][:carbon_allocation], PlantSimEngine.refvalue(statuses[2], :carbon_allocation))
end


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
- A dictionary with a `status` template for each organ type.

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
Dict{String, Status} with 4 entries:
  "Soil"      => Status(soil_water_content = -Inf,)
  "Internode" => Status(TT = -Inf, carbon_demand = -Inf, carbon_allocation = -Inf)
  "Plant"     => Status(A = RefVector{Float64}[], carbon_demand = RefVector{Float64}[], carbon_offer = -Inf, carbon_allocation = RefVector{Float64}[])
  "Leaf"      => Status(aPPFD = 1300.0, soil_water_content = MappedVar{String, Float64}("Soil", :soil_water_content, -Inf), A = -Inf, TT = 10.0, carbon_demand = -Inf, carbon_allocation = -Inf)
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
    # Vector of statuses, pre-initialised with the default values for each variable, taking into account user-defined initialisation, and multiscale mapping:
    organs_statuses = Dict{String,Status}()

    for organ in keys(models)
        # organ = "Internode"
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
        # The status is added to the vector of statuses.
        push!(organs_statuses, organ => st)
    end

    return organs_statuses
end

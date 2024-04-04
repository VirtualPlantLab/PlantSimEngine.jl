inputs_(m::MultiScaleModel) = inputs_(m.model)
outputs_(m::MultiScaleModel) = outputs_(m.model)


"""
    model_(m::AbstractModel)

Get the model of an AbstractModel (it is the model itself if it is not a MultiScaleModel).
"""
model_(m::AbstractModel) = m

# Functions to get the models from the dictionary that defines the mapping:

"""
    get_models(m)

Get the models of a dictionary of model mapping.

# Arguments

- `m::Dict{String,Any}`: a dictionary of model mapping

Returns a vector of models

# Examples

```jldoctest mylabel
julia> using PlantSimEngine;
```

Import example models (can be found in the `examples` folder of the package, or in the `Examples` sub-modules): 

```jldoctest mylabel
julia> using PlantSimEngine.Examples;
```

If we just give a MultiScaleModel, we get its model as a one-element vector:

```jldoctest mylabel
julia> models = MultiScaleModel( \
            model=ToyCAllocationModel(), \
            mapping=[ \
                :carbon_assimilation => ["Leaf"], \
                :carbon_demand => ["Leaf", "Internode"], \
                :carbon_allocation => ["Leaf", "Internode"] \
            ], \
        );
```

```jldoctest mylabel
julia> PlantSimEngine.get_models(models)
1-element Vector{ToyCAllocationModel}:
 ToyCAllocationModel()
```

If we give a tuple of models, we get each model in a vector:

```jldoctest mylabel
julia> models2 = (  \
        MultiScaleModel( \
            model=ToyAssimModel(), \
            mapping=[:soil_water_content => "Soil",], \
        ), \
        ToyCDemandModel(optimal_biomass=10.0, development_duration=200.0), \
        Status(aPPFD=1300.0, TT=10.0), \
    );
```

Notice that we provide "Soil", not ["Soil"] in the mapping because a single value is expected for the mapping here.

```jldoctest mylabel
julia> PlantSimEngine.get_models(models2)
2-element Vector{AbstractModel}:
 ToyAssimModel{Float64}(0.2)
 ToyCDemandModel{Float64}(10.0, 200.0)
```
"""
get_models(m) = [model_(i) for i in m if !isa(i, Status)]

# Get the models of a MultiScaleModel:
get_models(m::MultiScaleModel) = [model_(m)]
# Note: it is returning a vector of models, because in this case the user provided a single MultiScaleModel instead of a vector of.

# Get the models of an AbstractModel:
get_models(m::AbstractModel) = [model_(m)]

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
    mod_mapping = [mapping_(i) for i in m if isa(i, MultiScaleModel)]
    if length(mod_mapping) == 0
        return Pair{Symbol,String}[]
    end
    return reduce(vcat, mod_mapping) |> unique
end

get_mapping(m::MultiScaleModel{T,S}) where {T,S} = mapping_(m)
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

```julia
using PlantSimEngine
```

Import example models (can be found in the `examples` folder of the package, or in the `Examples` sub-modules): 

```jldoctest mylabel
julia> using PlantSimEngine.Examples;
```

```julia
mapping = Dict( 
    "Plant" =>  ( 
        MultiScaleModel(  
            model=ToyCAllocationModel(), 
            mapping=[ 
                :carbon_assimilation => ["Leaf"], 
                :carbon_demand => ["Leaf", "Internode"], 
                :carbon_allocation => ["Leaf", "Internode"] 
            ], 
        ), 
        MultiScaleModel(  
            model=ToyPlantRmModel(), 
            mapping=[:Rm_organs => ["Leaf" => :Rm, "Internode" => :Rm],]
        ), 
    ),
    "Internode" => ( 
        ToyCDemandModel(optimal_biomass=10.0, development_duration=200.0), 
        ToyMaintenanceRespirationModel(1.5, 0.06, 25.0, 0.6, 0.004), 
        Status(TT=10.0) 
    ), 
    "Leaf" => ( 
        MultiScaleModel( 
            model=ToyAssimModel(), 
            mapping=[:soil_water_content => "Soil",], 
        ), 
        ToyCDemandModel(optimal_biomass=10.0, development_duration=200.0), 
        ToyMaintenanceRespirationModel(2.1, 0.06, 25.0, 1.0, 0.025), 
        Status(aPPFD=1300.0, TT=10.0), 
    ), 
    "Soil" => ( 
        ToySoilWaterModel(), 
    ), 
)
```

```julia
organs_mapping, var_outputs_from_mapping = compute_mapping(models, nothing);
```

```julia
compute_mapping(models, Dict(Float64 => Float32, Vector{Float64} => Vector{Float32}))
```
"""
function compute_mapping(models::Dict{String,T}, type_promotion) where {T}
    # Initialise a dict that defines the multiscale variables for each organ type:
    organs_mapping = Dict{String,Any}()
    # Initialise a Dict that defines the variables that are outputs from a mapping, 
    # i.e. variables that are written by a model at another scale:
    var_outputs_from_mapping = Dict{String,Vector{Pair{Symbol,Any}}}()

    # rev_mapping = reverse_mapping(models; all=true)

    for organ in keys(models)
        # organ = "Plant"
        map_vars = get_mapping(models[organ])
        if length(map_vars) == 0
            continue
        end

        multiscale_vars = collect(first(i) for i in map_vars)
        mods = get_models(models[organ])
        ins = merge(inputs_.(mods)...)
        outs = merge(outputs_.(mods)...)
        multi_scale_outs = intersect(keys(outs), multiscale_vars) # outputs: variables that are written to another scale
        multi_scale_vars_vec = find_var_mapped_default(models, organ, map_vars, ins, outs)

        # As a status, promoted to what the user required:
        multi_scale_vars = Status(convert_vars(NamedTuple(multi_scale_vars_vec), type_promotion))

        # Users can provide initialisation values in a status. We get them here:
        st = get_status(models[organ])

        # Add the values given by the user (initialisation) to the mapping, and make it a Status:
        if isnothing(st)
            new_st = multi_scale_vars
        else
            # If the user provided the multiscale variable in the status, and it is an output variable, 
            # we use those values for the mapping:
            for i in keys(multi_scale_vars) # e.g. i = keys(multi_scale_vars)[1]
                if i in multi_scale_outs && i in keys(st)
                    multi_scale_vars[i] = st[i]
                end
            end
            # NB: we do this only for multiscale outputs, because this output cannot be 
            # defined from the models at the target scale, so we need to add it to this other scale
            # as an output variable.

            new_st = Status(merge(NamedTuple(convert_vars(st, type_promotion)), NamedTuple(multi_scale_vars)))
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
        outputs_from_other_scale!(var_outputs_from_mapping, NamedTuple(new_st)[(multi_scale_outs)], map_vars, organ)

        organ_mapping = Dict{Union{String,Vector{String}},Dict{Symbol,Union{RefVector,MappedVar}}}()
        for var_mapping in map_vars
            # var_mapping = map_vars[1]
            variable, organs_mapped = var_mapping

            ref_var_ = create_var_ref(organs_mapped, variable, getproperty(multi_scale_vars, variable))
            if haskey(organ_mapping, organs_mapped)
                push!(organ_mapping[organs_mapped], variable => ref_var_)
            else
                organ_mapping[organs_mapped] = Dict(variable => ref_var_)
            end

            # If the mapping is one node type only and is given as a string, we add the variable of the source scale 
            # as a MappedVar linked to itself, so we remember to not deepcopy when we build the status for the source node.
            # This is a special case for when the source scale only has one node in the MTG, and one variable is mapped.
            if isa(organs_mapped, AbstractString)
                if !haskey(organs_mapping, organs_mapped)
                    organs_mapping[organs_mapped] = Dict{Union{String,Vector{String}},Any}(organs_mapped => organ_mapping[organs_mapped])
                elseif !haskey(organs_mapping[organs_mapped], organs_mapped)
                    push!(organs_mapping[organs_mapped], organs_mapped => organ_mapping[organs_mapped])
                elseif !haskey(organs_mapping[organs_mapped][organs_mapped], variable)
                    push!(organs_mapping[organs_mapped][organs_mapped], variable => organ_mapping[organs_mapped][variable])
                    # else
                    #@info "Variable $variable already mapped from scale $organs_mapped to scale $organs_mapped. Skipping."
                    # NB: I removed this else because it happens a lot when we have a variable mapped a lot to a scale (e.g. :TT)
                end
            end
        end

        if haskey(organs_mapping, organ)
            merge!(organs_mapping[organ], deepcopy(organ_mapping))
        else
            organs_mapping[organ] = deepcopy(organ_mapping)
        end
    end

    for (k, v) in organs_mapping
        organs_mapping[k] = Dict(k => NamedTuple(v) for (k, v) in v)
    end

    var_outputs_from_mapping = Dict(k => NamedTuple(v) for (k, v) in var_outputs_from_mapping)

    return (; organs_mapping, var_outputs_from_mapping)
end

"""
    AbstractNodeMapping

Abstract type for the type of node mapping, *e.g.* single node mapping or multiple node mapping.
"""
abstract type AbstractNodeMapping end

"""
    SingleNodeMapping(scale)

Type for the single node mapping, *e.g.* `[:soil_water_content => "Soil",]`. Note that "Soil" is given as a scalar,
which means that `:soil_water_content` will be a scalar value taken from the unique "Soil" node in the plant graph.
"""
struct SingleNodeMapping <: AbstractNodeMapping
    scale::String
end

"""
    SelfNodeMapping()

Type for the self node mapping, *i.e.* a node that maps onto itself.
This is used to flag variables that will be referenced as a scalar value by other models. It can happen in two conditions:
    - the variable is computed by another scale, so we need this variable to exist as an input to this scale (it is not 
    computed at this scale otherwise)
    - the variable is an used as input to another scale but as a single value (scalar), so we need to reference it as a scalar.
"""

struct SelfNodeMapping <: AbstractNodeMapping end

"""
    MultiNodeMapping(scale)

Type for the multiple node mapping, *e.g.* `[:carbon_assimilation => ["Leaf"],]`. Note that "Leaf" is given as a vector,
which means `:carbon_assimilation` will be a vector of values taken from each "Leaf" in the plant graph.
"""
struct MultiNodeMapping <: AbstractNodeMapping
    scale::Vector{String}
end

MultiNodeMapping(scale::String) = MultiNodeMapping([scale])

"""
    vars_from_mapping(m)

Get the variables that are used in the multiscale models.

# Arguments

- `m::Dict`: a dictionary of model mapping

Returns a dictionary of variables (values) to organs (keys)

See also `vars_type_from_mapping` to get the variables type.

# Examples

```jldoctest test1
julia> vars_mapping = Dict( \
    ["Leaf"] => Dict(:carbon_assimilation => PlantSimEngine.RefVector{Float64}[]), \
    ["Leaf", "Internode"] => Dict( \
        :carbon_allocation => PlantSimEngine.RefVector{Float64}[], \
        :carbon_demand => PlantSimEngine.RefVector{Float64}[] \
    ) \
)
Dict{Vector{String}, Dict{Symbol, Vector{PlantSimEngine.RefVector{Float64}}}} with 2 entries:
  ["Leaf"]              => Dict(:carbon_assimilation=>[])
  ["Leaf", "Internode"] => Dict(:carbon_allocation=>[], :carbon_demand=>[])
```

```jldoctest test1
julia> PlantSimEngine.vars_from_mapping(vars_mapping)
3-element Vector{Symbol}:
 :carbon_assimilation
 :carbon_allocation
 :carbon_demand
```
"""
vars_from_mapping(m) = collect(Iterators.flatten(keys.(values(m))))
vars_type_from_mapping(m) = collect(Iterators.flatten(values.(values(m))))

"""
    MappedVar(source_organ, variable, source_variable, source_default)

A variable mapped to another scale.

# Arguments

- `source_organ`: the organ(s) that are targeted by the mapping
- `variable`: the name of the variable that is mapped
- `source_variable`: the name of the variable from the source organ (the one that computes the variable)
- `source_default`: the default value of the variable

# Examples

```jldoctest
julia> using PlantSimEngine
```

```jldoctest
julia> PlantSimEngine.MappedVar(PlantSimEngine.SingleNodeMapping("Leaf"), :carbon_assimilation, :carbon_assimilation, 1.0)
PlantSimEngine.MappedVar{PlantSimEngine.SingleNodeMapping, Symbol, Float64}(PlantSimEngine.SingleNodeMapping("Leaf"), :carbon_assimilation, :carbon_assimilation, 1.0)
```
"""
struct MappedVar{O<:AbstractNodeMapping,V<:Union{S,Vector{S}} where {S<:Symbol},T}
    source_organ::O
    variable::Symbol
    source_variable::V
    source_default::T
end

mapped_variable(m::MappedVar) = m.variable
source_organs(m::MappedVar) = m.source_organ
source_organs(m::MappedVar{O,V,T}) where {O<:AbstractNodeMapping,V,T} = nothing
mapped_organ(m::MappedVar{O,V,T}) where {O,V,T} = source_organs(m).scale
mapped_organ(m::MappedVar{O,V,T}) where {O<:SelfNodeMapping,V,T} = nothing
mapped_organ_type(m::MappedVar{O,V,T}) where {O<:AbstractNodeMapping,V,T} = O
source_variable(m::MappedVar) = m.source_variable
function source_variable(m::MappedVar{O,V,T}, organ) where {O<:SingleNodeMapping,V<:Symbol,T}
    @assert organ == mapped_organ(m) "Organ $organ not found in the mapping of the variable $(mapped_variable(m))."
    m.source_variable
end

function source_variable(m::MappedVar{O,V,T}, organ) where {O<:MultiNodeMapping,V<:Vector{Symbol},T}
    @assert organ in mapped_organ(m) "Organ $organ not found in the mapping of the variable $(mapped_variable(m))."
    m.source_variable[findfirst(o -> o == organ, mapped_organ(m))]
end

mapped_default(m::MappedVar) = m.source_default
mapped_default(m::MappedVar{O,V,T}, organ) where {O<:MultiNodeMapping,V<:Vector{Symbol},T} = m.source_default[findfirst(o -> o == organ, mapped_organ(m))]
mapped_default(m) = m # For any variable that is not a MappedVar, we return it as is

""" 
    UninitializedVar(variable, value)

A variable that is not initialized yet, it is given a name and a default value.
"""
struct UninitializedVar{T}
    variable::Symbol
    value::T
end

Base.eltype(u::UninitializedVar{T}) where {T} = T

"""
    create_var_ref(organ::Vector{<:AbstractString}, default::T) where {T}
    create_var_ref(organ::AbstractString, default)

Create a reference variable. The reference is a `RefVector` if the organ is a vector of strings, and a `MappedVar` 
if it is a singleton string. This is because we want to avoid indexing into a vector of values if there is only one 
value to map.
"""
function create_var_ref(organ::Vector{<:AbstractString}, var, default::AbstractVector{T}) where {T}
    RefVector(Base.RefValue{T}[])
end

create_var_ref(organ::AbstractString, var, default) = MappedVar(organ, var, default)

function outputs_from_other_scale!(var_outputs_from_mapping, multi_scale_outs, map_vars, current_organ)
    multi_scale_outs_organ = filter(x -> first(x) in keys(multi_scale_outs), map_vars)
    for (var, organs) in multi_scale_outs_organ # var, organs = multi_scale_outs_organ[2]
        if isa(organs, Pair)
            organs = organs.first
        end

        if isa(multi_scale_outs[var], AbstractVector)
            var_default_value = multi_scale_outs[var][1]
        else
            error(
                "The variable $var is an output variable mapped from `$organs` to `$current_organ`, but its default value is not a vector. " *
                "Make sure the model that computes this variable has a vector of values as outputs."
            )
        end
        if isa(organs, String)
            organs = [organs]
        end
        for org in organs # org = organs[1]
            if haskey(var_outputs_from_mapping, org)
                push!(var_outputs_from_mapping[org], var => var_default_value)
            else
                var_outputs_from_mapping[org] = [var => var_default_value]
            end
        end
    end
end

function map_scale(f, m, scale::String)
    map_scale(f, m, [scale])
end

function map_scale(f, m, scales::AbstractVector{String})
    map(s -> f(m, s), scales)
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
    reverse_mapping(mapping::Dict{String,Tuple{Any,Vararg{Any}}}; all=true)
    reverse_mapping(mapped_vars::Dict{String,Dict{Symbol,Any}})

Get the reverse mapping of a dictionary of model mapping, *i.e.* the variables that are mapped to other scales, or in other words,
what variables are given to other scales from a given scale.
This is used for *e.g.* knowing which scales are needed to add values to others.

# Arguments

- `mapping::Dict{String,Any}`: A dictionary of model mapping.
- `all::Bool`: Whether to get all the variables that are mapped to other scales, including the ones that are mapped as single values.

# Returns

A dictionary of organs (keys) with a dictionary of organs => vector of pair of variables. You can read the output as:
"for each organ (source organ), to which other organ (target organ) it is giving values for its own variables. Then for each of these source organs, which variable it is
giving to the target organ (first symbol in the pair), and to which variable it is mapping the value into the target organ (second symbol in the pair)".

# Examples

```jldoctest mylabel
julia> using PlantSimEngine
```

Import example models (can be found in the `examples` folder of the package, or in the `Examples` sub-modules): 

```jldoctest mylabel
julia> using PlantSimEngine.Examples;
```

```jldoctest mylabel
julia> mapping = Dict( \
            "Plant" => \
                MultiScaleModel( \
                    model=ToyCAllocationModel(), \
                    mapping=[ \
                        :carbon_assimilation => ["Leaf"], \
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

Notice we provide "Soil", not ["Soil"] in the mapping of the `ToyAssimModel` for the `Leaf`. This is because
we expect a single value for the `soil_water_content` to be mapped here (there is only one soil). This allows 
to get the value as a singleton instead of a vector of values.

```jldoctest mylabel
julia> PlantSimEngine.reverse_mapping(mapping)
Dict{String, Dict{String, Dict{Symbol, Any}}} with 3 entries:
  "Soil"      => Dict("Leaf"=>Dict(:soil_water_content=>:soil_water_content))
  "Internode" => Dict("Plant"=>Dict(:carbon_allocation=>:carbon_allocation, :ca…
  "Leaf"      => Dict("Plant"=>Dict(:carbon_allocation=>:carbon_allocation, :ca…
```
"""
function reverse_mapping(mapping::Dict{String,T}; all=true) where {T<:Any}
    # Method for the reverse mapping applied directly on the mapping (not used in the code base)
    mapped_vars = mapped_variables(mapping, dep(mapping), verbose=false)
    reverse_mapping(mapped_vars, all=all)
end

function reverse_mapping(mapped_vars::Dict{String,Dict{Symbol,Any}}; all=true)
    reverse_multiscale_mapping = Dict{String,Dict{String,Dict{Symbol,Any}}}(org => Dict{String,Dict{Symbol,Any}}() for org in keys(mapped_vars))
    for (organ, vars) in mapped_vars # e.g.: organ = "Plant"; vars = mapped_vars[organ]
        for (var, val) in vars # e.g. var = :Rm_organs; val = vars[var]
            if isa(val, MappedVar) && !isa(val, MappedVar{SelfNodeMapping}) && (all || !isa(val, MappedVar{SingleNodeMapping}))
                # Note: We skip the MappedVar{SelfNodeMapping} because it is a special case where the variable is mapped to itself
                # and we don't want to add it to the reverse mapping. We also skip the MappedVar{SingleNodeMapping} if `all=false`
                # because we don't want to add the variables that are mapped as single values to the reverse mapping.

                mapped_orgs = mapped_organ(val)
                isnothing(mapped_orgs) && continue
                if mapped_orgs isa String
                    mapped_orgs = [mapped_orgs]
                end

                for mapped_o in mapped_orgs # e.g.: mapped_o = "Leaf"
                    # if !haskey(reverse_multiscale_mapping, mapped_o)
                    #     reverse_multiscale_mapping[mapped_o] = Dict{Symbol,Vector{MappedVar}}()
                    # end
                    if !haskey(reverse_multiscale_mapping[mapped_o], organ)
                        reverse_multiscale_mapping[mapped_o][organ] = Dict{Symbol,Any}(source_variable(val, mapped_o) => mapped_variable(val))
                    end
                    push!(reverse_multiscale_mapping[mapped_o][organ], source_variable(val, mapped_o) => mapped_variable(val))
                end
            end
        end
    end
    filter!(x -> length(last(x)) > 0, reverse_multiscale_mapping)
end
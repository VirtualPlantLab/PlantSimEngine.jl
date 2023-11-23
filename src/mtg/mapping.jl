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
                :A => ["Leaf"], \
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
    return reduce(vcat, mod_mapping)
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

        multi_scale_vars_vec = Pair{Symbol,Any}[]
        for (var, scales) in map_vars # e.g. var = :A; scales = ["Leaf"]
            isa(scales, AbstractString) && (scales = [scales])

            # The variable default value is always taken from the upper-stream model:
            if var in keys(ins)
                # The variable is taken as an input from another scale. We take its default value from the model at the other scale:
                mapped_out_var = []
                for s in scales
                    @assert haskey(models, s) "Scale $s required as a mapping for scale $organ, but not found in the mapping."
                    mapped_out = merge(PlantSimEngine.outputs_.(PlantSimEngine.get_models(models[s]))...)
                    @assert hasproperty(mapped_out, var) "No model computes variable $var at scale $s, need one for scale $organ"
                    push!(mapped_out_var, mapped_out[var])
                end
                mapped_out = unique(mapped_out_var)
                if length(mapped_out) > 1
                    @info "Found different default values for variable $var in models at scales $scales: $mapped_out. Taking the first one."
                end
                mapped_out = mapped_out[1]

                # If the variable is given as a vector as default value, it means it will be taken from several organs.
                # In this case, we keep the vector format:
                if isa(ins[var], AbstractVector)
                    mapped_out = fill(mapped_out, length(ins[var]))
                end
                push!(multi_scale_vars_vec, var => mapped_out)
            elseif var in keys(outs)
                # The variable is an output of this scale for another scale. We take its default value from this scale:
                push!(multi_scale_vars_vec, var => outs[var])
            else
                error("Variable $var required to be mapped from scale(s) $scales to scale $organ was not found in any model from the scale(s) $scales.")
            end
        end

        multi_scale_vars = Status(PlantSimEngine.convert_vars(type_promotion, NamedTuple(multi_scale_vars_vec)))

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

            new_st = Status(merge(NamedTuple(convert_vars(type_promotion, st)), NamedTuple(multi_scale_vars)))
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
                    organs_mapping[organs_mapped] = Dict(organs_mapped => organ_mapping[organs_mapped])
                elseif !haskey(organs_mapping[organs_mapped], organs_mapped)
                    push!(organs_mapping[organs_mapped], organs_mapped => organ_mapping[organs_mapped])
                elseif !haskey(organs_mapping[organs_mapped][organs_mapped], variable)
                    push!(organs_mapping[organs_mapped][organs_mapped], variable => organ_mapping[organs_mapped][variable])
                else
                    @info "Variable $variable already mapped from scale $organs_mapped to scale $organs_mapped. Skipping."
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

```jldoctest test1
julia> vars_mapping = Dict( \
    ["Leaf"] => Dict(:A => PlantSimEngine.RefVector{Float64}[]), \
    ["Leaf", "Internode"] => Dict( \
        :carbon_allocation => PlantSimEngine.RefVector{Float64}[], \
        :carbon_demand => PlantSimEngine.RefVector{Float64}[] \
    ) \
)
Dict{Vector{String}, Dict{Symbol, Vector{PlantSimEngine.RefVector{Float64}}}} with 2 entries:
  ["Leaf"]              => Dict(:A=>[])
  ["Leaf", "Internode"] => Dict(:carbon_allocation=>[], :carbon_demand=>[])
```

```jldoctest test1
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
julia> PlantSimEngine.MappedVar("Leaf", :A, 1.0)
PlantSimEngine.MappedVar{String, Float64}("Leaf", :A, 1.0)
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
if it is a singleton string. This is because we want to avoid indexing into a vector of values if there is only one 
value to map.
"""
function create_var_ref(organ::Vector{<:AbstractString}, var, default::AbstractVector{T}) where {T}
    RefVector(Base.RefValue{T}[])
end

create_var_ref(organ::AbstractString, var, default) = MappedVar(organ, var, default)

function outputs_from_other_scale!(var_outputs_from_mapping, multi_scale_outs, map_vars)
    multi_scale_outs_organ = filter(x -> first(x) in keys(multi_scale_outs), map_vars)
    for (var, organs) in multi_scale_outs_organ # var, organs = multi_scale_outs_organ[1]
        if isa(multi_scale_outs[var], AbstractVector)
            var_default_value = multi_scale_outs[var][1]
        else
            error(
                "The variable $var is an output variable mapped to nodes of type $organs, but its default value is not a vector. " *
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
it is returned as is, else it is returned as a Ref to the copy of the value, or a 
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

Notice we provide "Soil", not ["Soil"] in the mapping of the `ToyAssimModel` for the `Leaf`. This is because
we expect a single value for the `soil_water_content` to be mapped here (there is only one soil). This allows 
to get the value as a singleton instead of a vector of values.

```jldoctest mylabel
julia> PlantSimEngine.reverse_mapping(models)
Dict{String, Any} with 3 entries:
  "Soil"      => Dict("Leaf"=>[:soil_water_content])
  "Internode" => Dict("Plant"=>[:carbon_demand, :carbon_allocation])
  "Leaf"      => Dict("Plant"=>[:A, :carbon_demand, :carbon_allocation])
```
"""
function reverse_mapping(models; all=true)
    var_to_ref = Dict{String,Dict{String,Vector{Symbol}}}(i => Dict{String,Vector{Symbol}}() for i in keys(models))
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
    variables_multiscale(node, organ, mapping)

Get the variables of a HardDependencyNode, taking into account the multiscale mapping, *i.e.*
defining variables as `MappedVar` if they are mapped to another scale.
"""
function variables_multiscale(node, organ, mapping)
    map(variables(node)) do vars
        vars_ = Vector{Union{Symbol,MappedVar}}()
        for var in vars # e.g. var = :soil_water_content
            if haskey(mapping[organ], var)
                push!(vars_, MappedVar(mapping[organ][var], var, nothing))
            else
                push!(vars_, var)
            end
        end
        return (vars_...,)
    end
end
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
    - the variable is used as input to another scale but as a single value (scalar), so we need to reference it as a scalar.
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
PlantSimEngine.MappedVar{PlantSimEngine.SingleNodeMapping, Symbol, Symbol, Float64}(PlantSimEngine.SingleNodeMapping("Leaf"), :carbon_assimilation, :carbon_assimilation, 1.0)
```
"""
struct MappedVar{O<:AbstractNodeMapping,V1<:Union{Symbol,PreviousTimeStep},V2<:Union{S,Vector{S}} where {S<:Symbol},T}
    source_organ::O
    variable::V1
    source_variable::V2
    source_default::T
end

mapped_variable(m::MappedVar) = m.variable
source_organs(m::MappedVar) = m.source_organ
source_organs(m::MappedVar{O,V1,V2,T}) where {O<:AbstractNodeMapping,V1,V2,T} = nothing
mapped_organ(m::MappedVar{O,V1,V2,T}) where {O,V1,V2,T} = source_organs(m).scale
mapped_organ(m::MappedVar{O,V1,V2,T}) where {O<:SelfNodeMapping,V1,V2,T} = nothing
mapped_organ_type(m::MappedVar{O,V1,V2,T}) where {O<:AbstractNodeMapping,V1,V2,T} = O
source_variable(m::MappedVar) = m.source_variable
function source_variable(m::MappedVar{O,V1,V2,T}, organ) where {O<:SingleNodeMapping,V1,V2<:Symbol,T}
    @assert organ == mapped_organ(m) "Organ $organ not found in the mapping of the variable $(mapped_variable(m))."
    m.source_variable
end

function source_variable(m::MappedVar{O,V1,V2,T}, organ) where {O<:MultiNodeMapping,V1,V2<:Vector{Symbol},T}
    @assert organ in mapped_organ(m) "Organ $organ not found in the mapping of the variable $(mapped_variable(m))."
    m.source_variable[findfirst(o -> o == organ, mapped_organ(m))]
end

mapped_default(m::MappedVar) = m.source_default
mapped_default(m::MappedVar{O,V1,V2,T}, organ) where {O<:MultiNodeMapping,V1,V2<:Vector{Symbol},T} = m.source_default[findfirst(o -> o == organ, mapped_organ(m))]
mapped_default(m) = m # For any variable that is not a MappedVar, we return it as is

# This defines the type of mapping setup: either single or multiscale. Used to dispatch methods for e.g. `dep` or `to_initialize`.
abstract type AbstractScaleSetup end

struct MultiScale <: AbstractScaleSetup end
struct SingleScale <: AbstractScaleSetup end

"""
    ModelMapping(mapping; check=true)

Validated mapping between MTG scales and model definitions.

Each scale entry may be provided as:
- a single model,
- a tuple of models with an optional [`Status`](@ref),

At construction time, the mapping is normalized and checked to fail early on common
configuration errors:
- each scale must define at least one model,
- at most one `Status` is allowed per scale,
- mapped scales must exist in the mapping,
- mapped source variables must exist on the source scale (as a model output or status variable),
- duplicate process declarations at a given scale are rejected.

# Notes

The type behaves like a read-only dictionary keyed by scale name (`String`).
Use `Dict(mapping)` to recover a plain dictionary.
"""
struct ModelMapping{S<:AbstractScaleSetup,D} <: AbstractDict{String,Tuple} where {D<:Union{Dict{String,Tuple},ModelList}}
    data::D
end

ModelMapping{S}(data) where {S<:AbstractScaleSetup} = ModelMapping{S,typeof(data)}(data)

"""
    model_rate(model::AbstractModel)

Optional model hook used by [`ModelMapping`](@ref) to check rate compatibility.

By default it returns `nothing` (no explicit rate contract). Package users can provide
model-specific methods that return a comparable value (for example `Dates.Period`), and
`ModelMapping` will reject incompatible mapped couplings.
"""
model_rate(::AbstractModel) = nothing
model_rate(model::MultiScaleModel) = model_rate(model_(model))

Base.length(mapping::ModelMapping{MultiScale}) = length(mapping.data)
Base.length(::ModelMapping{SingleScale}) = 1
Base.iterate(mapping::ModelMapping{MultiScale}, state...) = iterate(mapping.data, state...)
# Base.iterate(mapping::ModelMapping{SingleScale}, state...) = iterate(mapping.data.models, state...)
Base.show(io::IO, mapping::ModelMapping) = print(io, "ModelMapping with scales: ", join(keys(mapping), ", "))
# Base.show(io::IO, mapping::ModelMapping{SingleScale}) = print(io, "Single Scale ModelMapping:\n", mapping.data.models)
Base.show(io::IO, mapping::ModelMapping{SingleScale}) = print(io, "Single Scale ModelMapping")

function Base.show(io::IO, m::MIME"text/plain", t::ModelMapping{SingleScale})
    print(io, "Single Scale ModelMapping:\n")
    show(io, m, t.data)
end

function Base.show(io::IO, m::MIME"text/plain", t::ModelMapping)
    print(io, "ModelMapping with scales: ", join(keys(t), ", "))
end

Base.keys(mapping::ModelMapping) = keys(mapping.data)
Base.values(mapping::ModelMapping) = values(mapping.data)
Base.pairs(mapping::ModelMapping) = pairs(mapping.data)
Base.keys(::ModelMapping{SingleScale}) = ("Default",)
Base.values(mapping::ModelMapping{SingleScale}) = ((values(mapping.data.models)..., status(mapping.data)),)
Base.pairs(mapping::ModelMapping{SingleScale}) = ("Default" => (values(mapping.data.models)..., status(mapping.data)),)
Base.getindex(mapping::ModelMapping, key::String) = mapping.data[key]
Base.getindex(mapping::ModelMapping, key::AbstractString) = mapping.data[String(key)]
function Base.getindex(mapping::ModelMapping{SingleScale}, key::String)
    key == "Default" || throw(KeyError(key))
    return (values(mapping.data.models)..., status(mapping.data))
end
Base.getindex(mapping::ModelMapping{SingleScale}, key::AbstractString) = getindex(mapping, String(key))
Base.getindex(mapping::ModelMapping{SingleScale}, key::Symbol) = getindex(mapping.data, key)
Base.getindex(mapping::ModelMapping{SingleScale}, key::Integer) = getindex(mapping.data, key)
Base.haskey(mapping::ModelMapping, key::String) = haskey(mapping.data, key)
Base.haskey(mapping::ModelMapping, key::AbstractString) = haskey(mapping.data, String(key))
Base.eltype(::Type{ModelMapping}) = Pair{String,Tuple}
Base.copy(mapping::ModelMapping{MultiScale}) = ModelMapping(copy(mapping.data); check=false)
Base.copy(mapping::ModelMapping{SingleScale}) = ModelMapping{SingleScale,ModelList}(copy(mapping.data))
Base.copy(mapping::ModelMapping{SingleScale}, status) = ModelMapping{SingleScale,ModelList}(copy(mapping.data, status))
Base.Dict(mapping::ModelMapping) = copy(mapping.data)
Base.:(==)(left::ModelMapping{SingleScale}, right::ModelMapping{SingleScale}) = left.data == right.data

function Base.getproperty(mapping::ModelMapping{SingleScale}, name::Symbol)
    name === :data && return getfield(mapping, :data)
    return getproperty(getfield(mapping, :data), name)
end

function ModelMapping{MultiScale}(mapping::T; check::Bool=true) where {T<:AbstractDict}
    normalized = _normalize_multiscale_mapping(mapping)
    check && _check_multiscale_mapping!(normalized)
    ModelMapping{MultiScale,Dict{String,Tuple}}(normalized)
end

ModelMapping(mapping::AbstractDict; check::Bool=true) = ModelMapping{MultiScale}(mapping; check=check)

ModelMapping(mapping::ModelMapping; check::Bool=true) = check ? ModelMapping(mapping.data; check=true) : mapping

"""
    ModelMapping(scale_mapping_pairs...; check=true)
    ModelMapping(models...; scale="Default", status=nothing, check=true, processes...)

Convenience constructors for [`ModelMapping`](@ref):

- pass `scale => models` pairs directly (dict-like syntax),
- or pass models/processes directly for a single scale (old `ModelList` syntax).
"""
function ModelMapping(
    args...;
    scale::AbstractString="Default",
    status=nothing,
    check::Bool=true,
    processes...
)
    isempty(args) && isempty(processes) && error(
            "No mapping or model was provided. Use `ModelMapping(\"Scale\" => models)` or pass models directly."
        )

    # Backwards compatibility: allow dict-like construction for type promotion maps,
    # e.g. `ModelMapping(Float64 => Float32)`.
    if !isempty(args) && all(arg -> arg isa Pair && !(first(arg) isa Union{AbstractString,Symbol}), args)
        return Dict(args)
    end

    if _all_scale_pairs(args)
        isempty(processes) || error(
            "Cannot mix scale-level pairs with process keyword arguments. ",
            "Use either `\"Scale\" => models` pairs, or single-scale process/model arguments."
        )
        isnothing(status) || error(
            "`status` cannot be used with scale-level pair syntax. ",
            "Provide statuses inside each scale mapping instead."
        )
        raw_mapping = Dict{String,Any}(String(first(pair)) => last(pair) for pair in args)
        return ModelMapping{MultiScale}(raw_mapping; check=check)
    end

    _contains_scale_like_pair(args) && error(
        "Invalid argument mix: scale-level pairs must not be mixed with model arguments."
    )

    return ModelMapping{SingleScale,ModelList}(ModelList(args...; status=status, type_promotion=nothing, variables_check=check, processes...))

    #TODO: Use the following when we merge the ModelList and ModelMapping paths (create a fake scale):
    single_scale_models = _single_scale_mapping_entries(args, processes, status)
    # return ModelMapping{SingleScale}(Dict(String(scale) => single_scale_models), check=check)
end

# Canonical API dispatches for model mappings.
dep(mapping::ModelMapping{SingleScale}; verbose::Bool=true) = dep(mapping.data)
dep(mapping::ModelMapping{MultiScale}; verbose::Bool=true) = dep(mapping.data; verbose=verbose)
hard_dependencies(mapping::ModelMapping{SingleScale}; verbose::Bool=true) = hard_dependencies(mapping.data)
hard_dependencies(mapping::ModelMapping{MultiScale}; verbose::Bool=true) = hard_dependencies(mapping.data; verbose=verbose)
inputs(mapping::ModelMapping) = inputs(mapping.data)
outputs(mapping::ModelMapping) = outputs(mapping.data)
variables(mapping::ModelMapping) = variables(mapping.data)
to_initialize(mapping::ModelMapping, graph=nothing) = to_initialize(mapping.data, graph)
reverse_mapping(mapping::ModelMapping; all=true) = reverse_mapping(mapping.data; all=all)
init_variables(mapping::ModelMapping{SingleScale}; verbose=true) = init_variables(mapping.data; verbose=verbose)
to_initialize(mapping::ModelMapping{SingleScale}) = to_initialize(mapping.data)
to_initialize(mapping::ModelMapping{SingleScale}, graph) = to_initialize(mapping)
pre_allocate_outputs(mapping::ModelMapping{SingleScale}, outs, nsteps; type_promotion=nothing, check=true) =
    pre_allocate_outputs(mapping.data, outs, nsteps; type_promotion=type_promotion, check=check)

function _all_scale_pairs(args)
    !isempty(args) && all(arg -> arg isa Pair && first(arg) isa Union{AbstractString,Symbol}, args)
end

function _contains_scale_like_pair(args)
    any(arg -> arg isa Pair && first(arg) isa Union{AbstractString,Symbol}, args)
end

function _single_scale_mapping_entries(args, processes, status)
    models = Any[]

    for arg in args
        if arg isa Pair && first(arg) isa Symbol
            push!(models, last(arg))
        elseif arg isa NamedTuple
            append!(models, values(arg))
        elseif arg isa Tuple
            append!(models, arg)
        else
            push!(models, arg)
        end
    end

    append!(models, values(processes))

    if !isnothing(status)
        status_entry = status isa Status ? status : Status(status)
        push!(models, status_entry)
    end

    return tuple(models...)
end

function _normalize_multiscale_mapping(mapping::AbstractDict)
    isempty(mapping) && error("ModelMapping cannot be empty. Provide at least one scale with models.")
    normalized = Dict{String,Tuple}()
    for (scale, scale_mapping) in pairs(mapping)
        scale_name = String(scale)
        normalized[scale_name] = _normalize_scale_mapping(scale_name, scale_mapping)
    end
    return normalized
end

function _normalize_scale_mapping(scale::String, scale_mapping::ModelList)
    return _normalize_scale_mapping(scale, (values(scale_mapping.models)..., status(scale_mapping)))
end

function _normalize_scale_mapping(scale::String, scale_mapping::Union{AbstractModel,MultiScaleModel,ModelSpec})
    return (scale_mapping,)
end

function _normalize_scale_mapping(scale::String, scale_mapping::Tuple)
    normalized_items = Any[]
    for item in scale_mapping
        if item isa ModelList
            append!(normalized_items, values(item.models))
            push!(normalized_items, status(item))
        elseif item isa Union{AbstractModel,MultiScaleModel,ModelSpec,Status}
            push!(normalized_items, item)
        else
            error(
                "Invalid mapping entry at scale `$scale`: expected models/ModelSpec, Status, or ModelList, got $(typeof(item))."
            )
        end
    end
    return tuple(normalized_items...)
end

function _normalize_scale_mapping(scale::String, scale_mapping)
    error(
        "Invalid mapping entry at scale `$scale`: expected a model/ModelSpec, tuple of models/Status, or ModelList, got $(typeof(scale_mapping))."
    )
end

function _check_multiscale_mapping!(mapping::Dict{String,Tuple})
    _check_scales_have_models!(mapping)
    _check_scale_process_uniqueness!(mapping)
    _check_mapped_sources_exist!(mapping)
    return mapping
end

function _check_scales_have_models!(mapping::Dict{String,Tuple})
    for (scale, scale_mapping) in mapping
        n_status = count(item -> item isa Status, scale_mapping)
        n_status > 1 && error("Scale `$scale` defines $n_status statuses. Only one Status is allowed per scale.")

        models = get_models(scale_mapping)
        isempty(models) && error(
            "Scale `$scale` defines no model. Add at least one model, or remove this scale from the mapping."
        )
    end
end

function _check_scale_process_uniqueness!(mapping::Dict{String,Tuple})
    for (scale, scale_mapping) in mapping
        process_names = [_process_name_for_mapping_check(model) for model in get_models(scale_mapping)]
        duplicates = unique(filter(p -> count(==(p), process_names) > 1, process_names))
        isempty(duplicates) && continue
        duplicate_names = join(string.(duplicates), ", ")
        error(
            "Scale `$scale` defines duplicate process(es): $duplicate_names. ",
            "Keep only one model per process at a given scale (or use hard dependencies)."
        )
    end
end

function _process_name_for_mapping_check(model)
    try
        return process(model)
    catch
        return Symbol(nameof(typeof(model)))
    end
end

function _check_mapped_sources_exist!(mapping::Dict{String,Tuple})
    available_variables = _available_variables_by_scale(mapping)
    scale_rates = _declared_model_rates_by_scale(mapping)

    for (target_scale, scale_mapping) in mapping
        for item in scale_mapping
            mapped_vars = _mapping_item_mapped_variables(item)
            isempty(mapped_vars) && continue

            base_model = _mapping_item_model(item)
            model_inputs = Set(keys(inputs_(base_model)))
            model_outputs = Set(keys(outputs_(base_model)))
            for mapped_var in mapped_vars
                mapped_variable_name = first(mapped_var) isa PreviousTimeStep ? first(mapped_var).variable : first(mapped_var)
                checks_source_value = (mapped_variable_name in model_inputs) && !(mapped_variable_name in model_outputs)

                for (source_scale_raw, source_variable) in _as_mapping_sources(last(mapped_var))
                    source_scale = isempty(source_scale_raw) ? target_scale : source_scale_raw

                    haskey(mapping, source_scale) || error(
                        "Scale `$target_scale` maps variable `$(first(mapped_var))` to missing scale `$source_scale`. ",
                        "Add `$source_scale` to ModelMapping, or fix the mapped scale name."
                    )

                    if checks_source_value && source_variable ∉ available_variables[source_scale]
                        error(
                            "Scale `$target_scale` maps variable `$(first(mapped_var))` to `$source_scale.$source_variable`, ",
                            "but `$source_variable` is not available at scale `$source_scale` (neither model output nor Status variable). ",
                            "Define a model output for `$source_variable`, initialize it in the source scale Status, or update the mapping."
                        )
                    end

                    if checks_source_value && !_rates_compatible(scale_rates[target_scale], scale_rates[source_scale])
                        error(
                            "Scale `$target_scale` declares model rate $(scale_rates[target_scale]) but maps input `$(first(mapped_var))` ",
                            "from scale `$source_scale` with model rate $(scale_rates[source_scale]). ",
                            "Align model rates between scales or remove explicit `model_rate` declarations."
                        )
                    end
                end
            end
        end
    end
end

_mapping_item_mapped_variables(item::ModelSpec) = mapped_variables_(item)
_mapping_item_mapped_variables(item::MultiScaleModel) = mapped_variables_(item)
_mapping_item_mapped_variables(::Any) = Pair{Symbol,String}[]

_mapping_item_model(item::ModelSpec) = model_(item)
_mapping_item_model(item::MultiScaleModel) = model_(item)

_as_mapping_sources(source::Pair{<:AbstractString,Symbol}) = (String(first(source)) => last(source),)
_as_mapping_sources(source::AbstractVector{<:Pair{<:AbstractString,Symbol}}) =
    Tuple(String(first(item)) => last(item) for item in source)

function _available_variables_by_scale(mapping::Dict{String,Tuple})
    available = Dict{String,Set{Symbol}}()
    for (scale, scale_mapping) in mapping
        vars = Set{Symbol}()
        for model in get_models(scale_mapping)
            union!(vars, keys(outputs_(model)))
        end
        st = get_status(scale_mapping)
        !isnothing(st) && union!(vars, keys(st))
        available[scale] = vars
    end
    return available
end

function _declared_model_rates_by_scale(mapping::Dict{String,Tuple})
    rates = Dict{String,Any}()
    for (scale, scale_mapping) in mapping
        declared_rates = unique(filter(!isnothing, map(model_rate, get_models(scale_mapping))))
        if length(declared_rates) > 1
            error(
                "Scale `$scale` declares incompatible model rates $(declared_rates). ",
                "Use a single rate per scale, or leave `model_rate` undefined (`nothing`)."
            )
        end
        rates[scale] = isempty(declared_rates) ? nothing : only(declared_rates)
    end
    return rates
end

_rates_compatible(rate1, rate2) = isnothing(rate1) || isnothing(rate2) || rate1 == rate2

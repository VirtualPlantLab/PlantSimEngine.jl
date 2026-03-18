"""
    AbstractNodeMapping

Abstract type for the type of node mapping, *e.g.* single node mapping or multiple node mapping.
"""
abstract type AbstractNodeMapping end

@noinline function _warn_string_scale(context::Symbol)
    Base.depwarn(
        "String scale names are deprecated and will be removed in a future release. Use Symbol scales, e.g. `:Leaf` instead of `\"Leaf\"`.",
        context
    )
end

_normalize_scale(scale::Symbol; warn::Bool=false, context::Symbol=:PlantSimEngine) = scale
function _normalize_scale(scale::AbstractString; warn::Bool=true, context::Symbol=:PlantSimEngine)
    warn && _warn_string_scale(context)
    return Symbol(scale)
end

"""
    SingleNodeMapping(scale)

Type for the single node mapping, *e.g.* `[:soil_water_content => :Soil,]`. Note that `:Soil` is given as a scalar,
which means that `:soil_water_content` will be a scalar value taken from the unique `:Soil` node in the plant graph.
"""
struct SingleNodeMapping <: AbstractNodeMapping
    scale::Symbol
end

SingleNodeMapping(scale::Union{Symbol,AbstractString}) =
    SingleNodeMapping(_normalize_scale(scale; warn=scale isa AbstractString, context=:SingleNodeMapping))

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

Type for the multiple node mapping, *e.g.* `[:carbon_assimilation => [:Leaf],]`. Note that `:Leaf` is given as a vector,
which means `:carbon_assimilation` will be a vector of values taken from each `:Leaf` in the plant graph.
"""
struct MultiNodeMapping <: AbstractNodeMapping
    scale::Vector{Symbol}
end

MultiNodeMapping(scale::Union{Symbol,AbstractString}) = MultiNodeMapping([scale])
function MultiNodeMapping(scale::AbstractVector{<:Union{Symbol,AbstractString}})
    normalized = Symbol[
        _normalize_scale(s; warn=s isa AbstractString, context=:MultiNodeMapping) for s in scale
    ]
    return MultiNodeMapping(normalized)
end

"""
    MappedVar(source_organ, variable, source_variable, source_default)

A variable mapped to another scale.

# Arguments

- `source_organ`: the organ(s) that are targeted by the mapping
- `variable`: the name of the variable that is mapped
- `source_variable`: the name of the variable from the source organ (the one that computes the variable)
- `source_default`: the default value of the variable

# Examples

```jldoctest mylabel
julia> using PlantSimEngine

julia> PlantSimEngine.MappedVar(PlantSimEngine.SingleNodeMapping(:Leaf), :carbon_assimilation, :carbon_assimilation, 1.0)
PlantSimEngine.MappedVar{PlantSimEngine.SingleNodeMapping, Symbol, Symbol, Float64}(PlantSimEngine.SingleNodeMapping(:Leaf), :carbon_assimilation, :carbon_assimilation, 1.0)
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
    ModelMappingInfo

Cached metadata computed at `ModelMapping` construction time to avoid repeated
normalization/introspection work across runtime entrypoints.
"""
struct ModelMappingInfo
    validated::Bool
    is_valid::Bool
    is_multirate::Bool
    scales::Vector{Symbol}
    models_per_scale::Dict{Symbol,Int}
    processes_per_scale::Dict{Symbol,Vector{Symbol}}
    declared_rates::Dict{Symbol,Any}
    vars_need_init::Any
    model_specs::Dict{Symbol,Dict{Symbol,ModelSpec}}
    recommendations::Vector{String}
end

function _empty_model_mapping_info()
    ModelMappingInfo(
        false,
        false,
        false,
        Symbol[],
        Dict{Symbol,Int}(),
        Dict{Symbol,Vector{Symbol}}(),
        Dict{Symbol,Any}(),
        NamedTuple(),
        Dict{Symbol,Dict{Symbol,ModelSpec}}(),
        String[],
    )
end

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

The type behaves like a read-only dictionary keyed by scale name (`Symbol`).
Use `Dict(mapping)` to recover a plain dictionary.
"""
struct ModelMapping{S<:AbstractScaleSetup,D} <: AbstractDict{Symbol,Tuple} where {D<:Union{Dict{Symbol,Tuple},ModelList}}
    data::D
    info::ModelMappingInfo
end

function _build_model_mapping(::Type{S}, data; validated::Bool) where {S<:AbstractScaleSetup}
    info = try
        _build_model_mapping_info(S, data; validated=validated)
    catch
        _empty_model_mapping_info()
    end
    ModelMapping{S,typeof(data)}(data, info)
end

ModelMapping{S}(data) where {S<:AbstractScaleSetup} = _build_model_mapping(S, data; validated=false)

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
function Base.show(io::IO, mapping::ModelMapping)
    print(
        io,
        "ModelMapping(",
        length(mapping.info.scales),
        " scale",
        length(mapping.info.scales) == 1 ? "" : "s",
        ", multirate=",
        mapping.info.is_multirate,
        ")"
    )
end

function _isempty_vars_need_init(vars_need_init)
    vars_need_init isa NamedTuple && return isempty(keys(vars_need_init))
    vars_need_init isa AbstractDict && return all(isempty, values(vars_need_init))
    vars_need_init isa AbstractVector && return isempty(vars_need_init)
    return isnothing(vars_need_init)
end

function _timing_group_label_for_spec(spec::ModelSpec)
    if !isnothing(timestep(spec))
        return string("explicit ", timestep(spec), " (ModelSpec)")
    end

    model_clock = timespec(model_(spec))
    if !_is_default_clock(model_clock)
        return string("model timespec ", model_clock)
    end

    return "meteo base step (inferred at runtime)"
end

function _model_timing_groups(info::ModelMappingInfo)
    groups = Dict{String,Int}()
    for specs_at_scale in values(info.model_specs), spec in values(specs_at_scale)
        label = _timing_group_label_for_spec(spec)
        groups[label] = get(groups, label, 0) + 1
    end
    return groups
end

function _show_model_mapping_plain(io::IO, mapping::ModelMapping)
    info = mapping.info
    println(io, "ModelMapping")
    println(io, "  validated: ", info.validated, " (", info.is_valid ? "valid" : "invalid", ")")
    println(io, "  multirate: ", info.is_multirate)
    println(io, "  scales (", length(info.scales), "): ", join(info.scales, ", "))
    for scale in info.scales
        print(io, "  - ", scale, ": ", get(info.models_per_scale, scale, 0), " model(s)")
        processes = get(info.processes_per_scale, scale, Symbol[])
        if !isempty(processes)
            print(io, ", Processes=", join(string.(processes), ", "))
        end
        rate = get(info.declared_rates, scale, nothing)
        if !isnothing(rate)
            print(io, ", Rate=", rate)
        end
        println(io)
    end
    timing_groups = _model_timing_groups(info)
    if !isempty(timing_groups)
        println(io, "  Timing groups:")
        for label in sort!(collect(keys(timing_groups)); by=string)
            println(io, "  - ", label, ": ", timing_groups[label], " model(s)")
        end
        println(io, "  Get resolved timings with: `effective_rate_summary(modelmapping, meteo)`")
    end
    if _isempty_vars_need_init(info.vars_need_init)
        println(io, "  Variables to initialize: none")
    else
        println(io, "  Variables to initialize: ", info.vars_need_init)
    end
    if !isempty(info.recommendations)
        println(io, "  Recommendations:")
        for recommendation in info.recommendations
            println(io, "  - ", recommendation)
        end
    end
end

function Base.show(io::IO, m::MIME"text/plain", mapping::ModelMapping)
    if get(io, :compact, false)
        return show(io, mapping)
    end
    _show_model_mapping_plain(io, mapping)
    if mapping isa ModelMapping{SingleScale}
        println(io, "  status:")
        show(io, m, mapping.data)
    end
end

Base.keys(mapping::ModelMapping) = keys(mapping.data)
Base.values(mapping::ModelMapping) = values(mapping.data)
Base.pairs(mapping::ModelMapping) = pairs(mapping.data)
Base.keys(::ModelMapping{SingleScale}) = (:Default,)
Base.values(mapping::ModelMapping{SingleScale}) = ((values(mapping.data.models)..., status(mapping.data)),)
Base.pairs(mapping::ModelMapping{SingleScale}) = (:Default => (values(mapping.data.models)..., status(mapping.data)),)
Base.getindex(mapping::ModelMapping, key::Symbol) = mapping.data[key]
function Base.getindex(mapping::ModelMapping, key::AbstractString)
    sym = _normalize_scale(key; warn=true, context=:ModelMapping)
    return mapping.data[sym]
end
function Base.getindex(mapping::ModelMapping{SingleScale}, key::Symbol)
    if key == :Default
        return (values(mapping.data.models)..., status(mapping.data))
    end
    return getindex(mapping.data, key)
end
Base.getindex(mapping::ModelMapping{SingleScale}, key::AbstractString) = getindex(mapping, _normalize_scale(key; warn=true, context=:ModelMapping))
Base.getindex(mapping::ModelMapping{SingleScale}, key::Integer) = getindex(mapping.data, key)
Base.haskey(mapping::ModelMapping, key::Symbol) = haskey(mapping.data, key)
Base.haskey(mapping::ModelMapping, key::AbstractString) = haskey(mapping.data, _normalize_scale(key; warn=true, context=:ModelMapping))
Base.eltype(::Type{ModelMapping}) = Pair{Symbol,Tuple}
Base.copy(mapping::ModelMapping{MultiScale}) = _build_model_mapping(MultiScale, copy(mapping.data); validated=mapping.info.validated)
Base.copy(mapping::ModelMapping{SingleScale}) = _build_model_mapping(SingleScale, copy(mapping.data); validated=mapping.info.validated)
Base.copy(mapping::ModelMapping{SingleScale}, status) = _build_model_mapping(SingleScale, copy(mapping.data, status); validated=mapping.info.validated)
Base.Dict(mapping::ModelMapping) = copy(mapping.data)
Base.:(==)(left::ModelMapping{SingleScale}, right::ModelMapping{SingleScale}) = left.data == right.data

function Base.getproperty(mapping::ModelMapping{SingleScale}, name::Symbol)
    (name === :data || name === :info) && return getfield(mapping, name)
    return getproperty(getfield(mapping, :data), name)
end

function ModelMapping{MultiScale}(mapping::T; check::Bool=true) where {T<:AbstractDict}
    normalized = _normalize_multiscale_mapping(mapping)
    check && _check_multiscale_mapping!(normalized)
    _build_model_mapping(MultiScale, normalized; validated=check)
end

ModelMapping(mapping::AbstractDict; check::Bool=true) = ModelMapping{MultiScale}(mapping; check=check)

ModelMapping(mapping::ModelMapping; check::Bool=true) = check ? ModelMapping(mapping.data; check=true) : mapping

"""
    ModelMapping(scale_mapping_pairs...; check=true)
    ModelMapping(models...; scale=:Default, status=nothing, check=true, processes...)

Convenience constructors for [`ModelMapping`](@ref):

- pass `scale => models` pairs directly (dict-like syntax),
- or pass models/processes directly for a single scale (old `ModelList` syntax).
"""
function ModelMapping(
    args...;
    scale::Union{Symbol,AbstractString}=:Default,
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
        raw_mapping = Dict{Symbol,Any}(
            _normalize_scale(first(pair); warn=first(pair) isa AbstractString, context=:ModelMapping) => last(pair)
            for pair in args
        )
        return ModelMapping{MultiScale}(raw_mapping; check=check)
    end

    _contains_scale_like_pair(args) && error(
        "Invalid argument mix: scale-level pairs must not be mixed with model arguments."
    )

    flat_args = Any[]
    for arg in args
        if arg isa Pair && first(arg) isa Symbol
            push!(flat_args, last(arg))
        elseif arg isa NamedTuple
            append!(flat_args, values(arg))
        elseif arg isa Tuple
            append!(flat_args, arg)
        else
            push!(flat_args, arg)
        end
    end

    return _build_model_mapping(
        SingleScale,
        ModelList(flat_args...; status=status, type_promotion=nothing, variables_check=check, processes...);
        validated=check
    )

    #TODO: Use the following when we merge the ModelList and ModelMapping paths (create a fake scale):
    single_scale_models = _single_scale_mapping_entries(args, processes, status)
    # return ModelMapping{SingleScale}(Dict(_normalize_scale(scale) => single_scale_models), check=check)
end

# Canonical API dispatches for model mappings.
dep(mapping::ModelMapping{SingleScale}; verbose::Bool=true) = dep(mapping.data)
dep(mapping::ModelMapping{MultiScale}; verbose::Bool=true) = dep(mapping.data; verbose=verbose)
hard_dependencies(mapping::ModelMapping{SingleScale}; verbose::Bool=true) = hard_dependencies(mapping.data)
hard_dependencies(mapping::ModelMapping{MultiScale}; verbose::Bool=true) = hard_dependencies(mapping.data; verbose=verbose)
inputs(mapping::ModelMapping) = inputs(mapping.data)
outputs(mapping::ModelMapping) = outputs(mapping.data)
variables(mapping::ModelMapping) = variables(mapping.data)
function to_initialize(mapping::ModelMapping, graph=nothing)
    isnothing(graph) && return mapping.info.vars_need_init
    return to_initialize(mapping.data, graph)
end
reverse_mapping(mapping::ModelMapping; all=true) = reverse_mapping(mapping.data; all=all)
init_variables(mapping::ModelMapping{SingleScale}; verbose=true) = init_variables(mapping.data; verbose=verbose)
to_initialize(mapping::ModelMapping{SingleScale}) = mapping.info.vars_need_init
to_initialize(mapping::ModelMapping{SingleScale}, graph) = to_initialize(mapping)
pre_allocate_outputs(mapping::ModelMapping{SingleScale}, outs, nsteps; type_promotion=nothing, check=true) =
    pre_allocate_outputs(mapping.data, outs, nsteps; type_promotion=type_promotion, check=check)

mapping_info(mapping::ModelMapping) = mapping.info
is_multirate(mapping::ModelMapping) = mapping.info.is_multirate
is_valid(mapping::ModelMapping) = mapping.info.is_valid

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
    normalized = Dict{Symbol,Tuple}()
    for (scale, scale_mapping) in pairs(mapping)
        scale_name = _normalize_scale(scale; warn=scale isa AbstractString, context=:ModelMapping)
        normalized[scale_name] = _normalize_scale_mapping(scale_name, scale_mapping)
    end
    return normalized
end

function _normalize_scale_mapping(scale::Symbol, scale_mapping::ModelList)
    return _normalize_scale_mapping(scale, (values(scale_mapping.models)..., status(scale_mapping)))
end

function _normalize_scale_mapping(scale::Symbol, scale_mapping::ModelMapping{SingleScale})
    return _normalize_scale_mapping(scale, scale_mapping.data)
end

function _normalize_scale_mapping(scale::Symbol, scale_mapping::Union{AbstractModel,MultiScaleModel,ModelSpec})
    return (scale_mapping,)
end

function _normalize_scale_mapping(scale::Symbol, scale_mapping::Tuple)
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

function _normalize_scale_mapping(scale::Symbol, scale_mapping)
    error(
        "Invalid mapping entry at scale `$scale`: expected a model/ModelSpec, tuple of models/Status, or ModelList, got $(typeof(scale_mapping))."
    )
end

function _check_multiscale_mapping!(mapping::Dict{Symbol,Tuple})
    _check_scales_have_models!(mapping)
    _check_scale_process_uniqueness!(mapping)
    _check_mapped_sources_exist!(mapping)
    return mapping
end

function _check_scales_have_models!(mapping::Dict{Symbol,Tuple})
    for (scale, scale_mapping) in mapping
        n_status = count(item -> item isa Status, scale_mapping)
        n_status > 1 && error("Scale `$scale` defines $n_status statuses. Only one Status is allowed per scale.")

        models = get_models(scale_mapping)
        isempty(models) && error(
            "Scale `$scale` defines no model. Add at least one model, or remove this scale from the mapping."
        )
    end
end

function _check_scale_process_uniqueness!(mapping::Dict{Symbol,Tuple})
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

function _check_mapped_sources_exist!(mapping::Dict{Symbol,Tuple})
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
                    source_scale = isnothing(source_scale_raw) ? target_scale : source_scale_raw

                    haskey(mapping, source_scale) || error(
                        "Scale `$target_scale` maps variable `$(first(mapped_var))` to missing scale `$source_scale`. ",
                        "Add `$source_scale` to ModelMapping, or fix the mapped scale name."
                    )

                    if checks_source_value && source_variable ∉ available_variables[source_scale]
                        error(
                            "Scale `$target_scale` maps variable `$(first(mapped_var))` to `$source_scale.$source_variable`, ",
                            "but `$source_variable` is not available at scale `$source_scale` ",
                            "(neither model output, Status variable, nor mapped output from another scale). ",
                            "Define a model output for `$source_variable`, initialize it in the source scale Status, ",
                            "or map this variable from another scale into `$source_scale` before using it."
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
_mapping_item_mapped_variables(::Any) = Pair{Symbol,Symbol}[]

_mapping_item_model(item::ModelSpec) = model_(item)
_mapping_item_model(item::MultiScaleModel) = model_(item)

function _as_mapping_scale(source_scale::AbstractString)
    isempty(source_scale) && return nothing
    return _normalize_scale(source_scale; warn=true, context=:ModelMapping)
end

function _as_mapping_scale(source_scale::Symbol)
    source_scale === Symbol("") && return nothing
    return _normalize_scale(source_scale; warn=false, context=:ModelMapping)
end

_as_mapping_sources(source::Pair{<:Union{AbstractString,Symbol},Symbol}) =
    (_as_mapping_scale(first(source)) => last(source),)
_as_mapping_sources(source::AbstractVector{<:Pair{<:Union{AbstractString,Symbol},Symbol}}) =
    Tuple(_as_mapping_scale(first(item)) => last(item) for item in source)

function _available_variables_by_scale(mapping::Dict{Symbol,Tuple})
    available = Dict{Symbol,Set{Symbol}}()
    for (scale, scale_mapping) in mapping
        vars = Set{Symbol}()
        for model in get_models(scale_mapping)
            union!(vars, keys(outputs_(model)))
        end
        st = get_status(scale_mapping)
        !isnothing(st) && union!(vars, keys(st))
        available[scale] = vars
    end

    # Variables produced at one scale and explicitly mapped as outputs to another
    # scale are available at the target scale as runtime references.
    for (source_scale, scale_mapping) in mapping
        for item in scale_mapping
            mapped_vars = _mapping_item_mapped_variables(item)
            isempty(mapped_vars) && continue
            base_model = _mapping_item_model(item)
            model_outputs = Set(keys(outputs_(base_model)))
            for mapped_var in mapped_vars
                mapped_variable_name = first(mapped_var) isa PreviousTimeStep ? first(mapped_var).variable : first(mapped_var)
                mapped_variable_name in model_outputs || continue
                for (target_scale_raw, target_variable) in _as_mapping_sources(last(mapped_var))
                    target_scale = isnothing(target_scale_raw) ? source_scale : target_scale_raw
                    haskey(available, target_scale) || continue
                    push!(available[target_scale], target_variable)
                end
            end
        end
    end

    return available
end

function _declared_model_rates_by_scale(mapping::Dict{Symbol,Tuple})
    rates = Dict{Symbol,Any}()
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

function _spec_declares_multirate(spec::ModelSpec)
    model = model_(spec)
    !isnothing(timestep(spec)) && return true
    # Explicit input bindings are also used for same-rate disambiguation,
    # so they must not, by themselves, force multirate runtime.
    !isnothing(meteo_window(spec)) && return true
    !isempty(keys(output_routing(spec))) && return true
    timespec(model) != ClockSpec(1.0, 0.0) && return true
    return false
end

function _mapping_declares_multirate(model_specs::Dict{Symbol,Dict{Symbol,ModelSpec}}, declared_rates::Dict{Symbol,Any})
    any(!isnothing, values(declared_rates)) && return true
    for specs_at_scale in values(model_specs), spec in values(specs_at_scale)
        _spec_declares_multirate(spec) && return true
    end
    return false
end

function _model_summary_from_mapping(mapping::Dict{Symbol,Tuple})
    models_per_scale = Dict{Symbol,Int}()
    processes_per_scale = Dict{Symbol,Vector{Symbol}}()
    for (scale, scale_mapping) in mapping
        models = get_models(scale_mapping)
        models_per_scale[scale] = length(models)
        processes_per_scale[scale] = [_process_name_for_mapping_check(model) for model in models]
    end
    return models_per_scale, processes_per_scale
end

function _parse_model_specs_from_mapping(mapping::Dict{Symbol,Tuple})
    Dict(scale => parse_model_specs(scale_mapping) for (scale, scale_mapping) in mapping)
end

function _build_model_mapping_recommendations(
    validated::Bool,
    is_multirate::Bool,
    vars_need_init
)
    recommendations = String[]
    if !validated
        push!(recommendations, "Built with `check=false`: rebuild with `check=true` to validate consistency.")
    end
    if !_isempty_vars_need_init(vars_need_init)
        push!(recommendations, "Initialize required variables listed above (see `to_initialize(mapping)`).")
    end
    if is_multirate
        push!(recommendations, "Multirate is enabled from mapping metadata; `run!(mtg, mapping, ...)` auto-detects it.")
    end
    return recommendations
end

function _build_model_mapping_info(::Type{SingleScale}, mapping::ModelList; validated::Bool)
    specs = Dict(
        :Default => Dict{Symbol,ModelSpec}(
            process(model) => as_model_spec(model) for model in values(mapping.models)
        )
    )

    declared_rates = Dict{Symbol,Any}(:Default => nothing)
    vars_need_init = try
        to_initialize(mapping)
    catch
        NamedTuple()
    end
    is_multirate = false
    recommendations = _build_model_mapping_recommendations(validated, is_multirate, vars_need_init)
    processes = [process(model) for model in values(mapping.models)]
    return ModelMappingInfo(
        validated,
        validated,
        is_multirate,
        [:Default],
        Dict(:Default => length(mapping.models)),
        Dict(:Default => processes),
        declared_rates,
        vars_need_init,
        specs,
        recommendations,
    )
end

function _build_model_mapping_info(::Type{MultiScale}, mapping::Dict{Symbol,Tuple}; validated::Bool)
    scales = collect(keys(mapping))
    models_per_scale, processes_per_scale = _model_summary_from_mapping(mapping)
    declared_rates = try
        _declared_model_rates_by_scale(mapping)
    catch
        Dict{Symbol,Any}(scale => nothing for scale in scales)
    end
    model_specs = try
        _parse_model_specs_from_mapping(mapping)
    catch
        Dict{Symbol,Dict{Symbol,ModelSpec}}()
    end
    vars_need_init = try
        to_initialize(mapping, nothing)
    catch
        Dict{Symbol,Vector{Symbol}}()
    end
    is_multirate = _mapping_declares_multirate(model_specs, declared_rates)
    recommendations = _build_model_mapping_recommendations(validated, is_multirate, vars_need_init)
    return ModelMappingInfo(
        validated,
        validated,
        is_multirate,
        scales,
        models_per_scale,
        processes_per_scale,
        declared_rates,
        vars_need_init,
        model_specs,
        recommendations,
    )
end

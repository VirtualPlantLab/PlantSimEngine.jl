"""
    ModelSpec(model; multiscale=nothing, timestep=nothing, input_bindings=NamedTuple(), output_routing=NamedTuple())

User-side model configuration wrapper for mapping/model list composition.

`ModelSpec` keeps model implementation and scenario-specific usage metadata in one place.
This allows modelers to publish reusable models while users decide how models are coupled in
their simulation setup.
"""
struct ModelSpec{M,MS,TS,IB,OR}
    model::M
    multiscale::MS
    timestep::TS
    input_bindings::IB
    output_routing::OR
end

function _normalize_multiscale_mapping(model::AbstractModel, mapped_variables)
    mapped_variables === nothing && return nothing
    mapped = MultiScaleModel(model, mapped_variables)
    return mapped_variables_(mapped)
end

function ModelSpec(
    model::AbstractModel;
    multiscale=nothing,
    timestep=nothing,
    input_bindings=NamedTuple(),
    output_routing=NamedTuple()
)
    base_model = model
    base_multiscale = multiscale

    if model isa MultiScaleModel
        base_model = model_(model)
        base_multiscale === nothing && (base_multiscale = mapped_variables_(model))
    end

    normalized_multiscale = _normalize_multiscale_mapping(base_model, base_multiscale)
    normalized_input_bindings = _normalize_input_bindings(input_bindings)
    normalized_output_routing = _normalize_output_routing(output_routing)
    return ModelSpec{typeof(base_model),typeof(normalized_multiscale),typeof(timestep),typeof(normalized_input_bindings),typeof(normalized_output_routing)}(
        base_model,
        normalized_multiscale,
        timestep,
        normalized_input_bindings,
        normalized_output_routing
    )
end

function ModelSpec(
    spec::ModelSpec;
    model=spec.model,
    multiscale=spec.multiscale,
    timestep=spec.timestep,
    input_bindings=spec.input_bindings,
    output_routing=spec.output_routing
)
    ModelSpec(model; multiscale=multiscale, timestep=timestep, input_bindings=input_bindings, output_routing=output_routing)
end

as_model_spec(spec::ModelSpec) = spec
as_model_spec(model::AbstractModel) = ModelSpec(model)
as_model_spec(model::MultiScaleModel) = ModelSpec(model_(model); multiscale=mapped_variables_(model))

"""
    with_multiscale(model_or_spec, mapped_variables)

Return a `ModelSpec` with updated multiscale mapping.
"""
function with_multiscale(model_or_spec, mapped_variables)
    spec = as_model_spec(model_or_spec)
    return ModelSpec(spec; multiscale=mapped_variables)
end

"""
    with_timestep(model_or_spec, timestep)

Return a `ModelSpec` with an explicit user-selected timestep.
"""
function with_timestep(model_or_spec, timestep)
    spec = as_model_spec(model_or_spec)
    return ModelSpec(spec; timestep=timestep)
end

"""
    with_input_bindings(model_or_spec, bindings)

Return a `ModelSpec` with explicit user-defined input-to-producer bindings.
"""
function with_input_bindings(model_or_spec, bindings)
    spec = as_model_spec(model_or_spec)
    return ModelSpec(spec; input_bindings=_normalize_input_bindings(bindings))
end

"""
    with_output_routing(model_or_spec, routing)

Return a `ModelSpec` with explicit user-defined output routing.
"""
function with_output_routing(model_or_spec, routing)
    spec = as_model_spec(model_or_spec)
    return ModelSpec(spec; output_routing=_normalize_output_routing(routing))
end

function _normalize_input_binding(binding)
    if binding isa NamedTuple
        return haskey(binding, :policy) ? binding : (; binding..., policy=HoldLast())
    elseif binding isa Pair{Symbol,Symbol}
        return (process=first(binding), var=last(binding), policy=HoldLast())
    elseif binding isa Symbol
        return (process=binding, policy=HoldLast())
    end
    return binding
end

function _normalize_input_bindings(bindings::NamedTuple)
    normalized = Pair{Symbol,Any}[]
    for (k, v) in pairs(bindings)
        push!(normalized, k => _normalize_input_binding(v))
    end
    return (; normalized...)
end

_normalize_input_bindings(bindings) = bindings

function _normalize_output_routing(routing::NamedTuple)
    normalized = Pair{Symbol,Symbol}[]
    for (k, v) in pairs(routing)
        mode = Symbol(v)
        mode in (:canonical, :stream_only) || error(
            "Unsupported output routing mode `$(mode)` for output `$(k)`. ",
            "Allowed values are `:canonical` and `:stream_only`."
        )
        push!(normalized, k => mode)
    end
    return (; normalized...)
end

_normalize_output_routing(routing) = routing

"""
    MultiScaleModel(mapped_variables)

Pipe-style transform that updates multiscale mapping on a model/spec.
"""
MultiScaleModel(mapped_variables) = x -> with_multiscale(x, mapped_variables)

"""
    TimeStepModel(timestep)

Pipe-style transform that sets a user-selected timestep on a model/spec.
"""
TimeStepModel(timestep) = x -> with_timestep(x, timestep)

"""
    InputBindings(bindings)
    InputBindings(; kwargs...)

Pipe-style transform that sets explicit input bindings on a model/spec.
"""
InputBindings(bindings) = x -> with_input_bindings(x, bindings)
InputBindings(; kwargs...) = InputBindings((; kwargs...))

"""
    OutputRouting(routing)
    OutputRouting(; kwargs...)

Pipe-style transform that sets explicit output routing on a model/spec.
Allowed modes:
- `:canonical` (default): output is considered canonical at that scale.
- `:stream_only`: output is kept in temporal streams only.
"""
OutputRouting(routing) = x -> with_output_routing(x, routing)
OutputRouting(; kwargs...) = OutputRouting((; kwargs...))

model_(m::ModelSpec) = m.model
mapped_variables_(m::ModelSpec) = isnothing(m.multiscale) ? Pair{Symbol,String}[] : m.multiscale
get_models(m::ModelSpec) = [model_(m)]
get_status(m::ModelSpec) = nothing
get_mapped_variables(m::ModelSpec) = mapped_variables_(m)
process(m::ModelSpec) = process(model_(m))
timestep(m::ModelSpec) = m.timestep

"""
    ModelSpec(model; name=nothing, applies_to=nothing, inputs=NamedTuple(),
              calls=NamedTuple(), environment=nothing, timestep=nothing,
              meteo_bindings=NamedTuple(), meteo_window=nothing,
              output_routing=NamedTuple(), updates=())

Configuration for one model application in a `Scene`.

`ModelSpec` keeps model implementation and scenario-specific usage metadata in one place.
This allows modelers to publish reusable models while users decide how models are coupled in
their simulation setup.
"""
struct ModelSpec{M,N,AT,IN,IO,CA,CO,EV,TS,MB,MW,OR,UP}
    model::M
    name::N
    applies_to::AT
    inputs::IN
    input_origins::IO
    calls::CA
    call_origins::CO
    environment::EV
    timestep::TS
    meteo_bindings::MB
    meteo_window::MW
    output_routing::OR
    updates::UP
end

"""
    Updates(vars...; after=nothing)

Scenario-level declaration that a model updates variables which may also be
computed by another model at the same scale.

`after` is intentionally scenario-level metadata: the model implementation stays
reusable, while the simulation setup can declare ordering constraints that only
exist in this coupling.
"""
struct Updates{V,A}
    variables::V
    after::A
end

function Updates(vars::Vararg{Union{Symbol,AbstractString}}; after=nothing)
    isempty(vars) && error("Updates(...) requires at least one variable.")
    return Updates(Tuple(Symbol(v) for v in vars), _normalize_update_after(after))
end

function _normalize_update_after(after)
    isnothing(after) && return ()
    after isa Union{Symbol,AbstractString} && return (Symbol(after),)
    return Tuple(Symbol(v) for v in after)
end

_normalize_updates(updates::Updates) = (updates,)

function _normalize_updates(updates::Tuple)
    all(update -> update isa Updates, updates) || error(
        "Unsupported updates tuple. Use `Updates(:var; after=:process)` entries."
    )
    return updates
end

function _normalize_updates(updates::AbstractVector)
    all(update -> update isa Updates, updates) || error(
        "Unsupported updates vector. Use `Updates(:var; after=:process)` entries."
    )
    return Tuple(updates)
end

function _normalize_updates(updates)
    updates == NamedTuple() && return ()
    updates == () && return ()
    error(
        "Unsupported updates metadata `$(updates)` of type `$(typeof(updates))`. ",
        "Use `Updates(:var; after=:process)` or a tuple/vector of `Updates`."
    )
end

function ModelSpec(
    model::AbstractModel;
    name=nothing,
    applies_to=nothing,
    inputs=NamedTuple(),
    input_origins=nothing,
    calls=NamedTuple(),
    call_origins=nothing,
    environment=nothing,
    timestep=nothing,
    meteo_bindings=NamedTuple(),
    meteo_window=nothing,
    output_routing=NamedTuple(),
    updates=()
)
    base_model = model

    normalized_name = _normalize_application_name(name)
    default_inputs = _model_default_value_inputs(base_model)
    explicit_inputs = _normalize_application_bindings(inputs)
    normalized_inputs = _merge_value_inputs(default_inputs, explicit_inputs)
    normalized_input_origins = isnothing(input_origins) ?
                               _binding_origins(default_inputs, explicit_inputs) :
                               _normalize_binding_origins(input_origins, normalized_inputs)
    default_calls = _model_default_model_calls(base_model)
    explicit_calls = _normalize_application_bindings(calls)
    normalized_calls = _merge_value_inputs(default_calls, explicit_calls)
    normalized_call_origins = isnothing(call_origins) ?
                              _binding_origins(default_calls, explicit_calls) :
                              _normalize_binding_origins(call_origins, normalized_calls)
    normalized_meteo_bindings = _normalize_meteo_bindings(meteo_bindings)
    normalized_meteo_window = _normalize_meteo_window(meteo_window)
    normalized_output_routing = _normalize_output_routing(output_routing)
    normalized_updates = _normalize_updates(updates)
    return ModelSpec{typeof(base_model),typeof(normalized_name),typeof(applies_to),typeof(normalized_inputs),typeof(normalized_input_origins),typeof(normalized_calls),typeof(normalized_call_origins),typeof(environment),typeof(timestep),typeof(normalized_meteo_bindings),typeof(normalized_meteo_window),typeof(normalized_output_routing),typeof(normalized_updates)}(
        base_model,
        normalized_name,
        applies_to,
        normalized_inputs,
        normalized_input_origins,
        normalized_calls,
        normalized_call_origins,
        environment,
        timestep,
        normalized_meteo_bindings,
        normalized_meteo_window,
        normalized_output_routing,
        normalized_updates
    )
end

function ModelSpec(
    spec::ModelSpec;
    model=spec.model,
    name=spec.name,
    applies_to=spec.applies_to,
    inputs=spec.inputs,
    input_origins=spec.input_origins,
    calls=spec.calls,
    call_origins=spec.call_origins,
    environment=spec.environment,
    timestep=spec.timestep,
    meteo_bindings=spec.meteo_bindings,
    meteo_window=spec.meteo_window,
    output_routing=spec.output_routing,
    updates=spec.updates
)
    ModelSpec(model; name=name, applies_to=applies_to, inputs=inputs, input_origins=input_origins, calls=calls, call_origins=call_origins, environment=environment, timestep=timestep, meteo_bindings=meteo_bindings, meteo_window=meteo_window, output_routing=output_routing, updates=updates)
end

as_model_spec(spec::ModelSpec) = spec
as_model_spec(model::AbstractModel) = ModelSpec(model)

function _with_spec(model_or_spec; kwargs...)
    return ModelSpec(as_model_spec(model_or_spec); kwargs...)
end

function _with_spec_bindings(model_or_spec, bindings, defaults)
    spec = as_model_spec(model_or_spec)
    explicit = _normalize_application_bindings(bindings)
    origins = _binding_origins(defaults(model_(spec)), explicit)
    return spec, explicit, origins
end

"""
    with_name(model_or_spec, name)

Return a `ModelSpec` with an explicit model-application name.
"""
function with_name(model_or_spec, name)
    return _with_spec(model_or_spec; name=_normalize_application_name(name))
end

"""
    with_applies_to(model_or_spec, selector)

Return a `ModelSpec` with an explicit model-application target selector.
"""
function with_applies_to(model_or_spec, selector)
    return _with_spec(model_or_spec; applies_to=selector)
end

"""
    with_inputs(model_or_spec, bindings)

Return a `ModelSpec` with unified scene/object value-input bindings.
"""
function with_inputs(model_or_spec, bindings)
    spec, explicit, origins =
        _with_spec_bindings(model_or_spec, bindings, _model_default_value_inputs)
    return ModelSpec(spec; inputs=explicit, input_origins=origins)
end

"""
    with_calls(model_or_spec, bindings)

Return a `ModelSpec` with unified scene/object manual model-call bindings.
"""
function with_calls(model_or_spec, bindings)
    spec, explicit, origins =
        _with_spec_bindings(model_or_spec, bindings, _model_default_model_calls)
    return ModelSpec(spec; calls=explicit, call_origins=origins)
end

"""
    with_environment(model_or_spec, environment)

Return a `ModelSpec` with scene/object environment configuration metadata.
"""
function with_environment(model_or_spec, environment)
    return _with_spec(model_or_spec; environment=environment)
end

"""
    with_timestep(model_or_spec, timestep)

Return a `ModelSpec` with an explicit user-selected timestep.
"""
function with_timestep(model_or_spec, timestep)
    return _with_spec(model_or_spec; timestep=timestep)
end

"""
    with_meteo_bindings(model_or_spec, bindings)

Return a `ModelSpec` with explicit meteo aggregation bindings.
"""
with_meteo_bindings(model_or_spec, bindings) =
    _with_spec(model_or_spec; meteo_bindings=_normalize_meteo_bindings(bindings))

"""
    with_meteo_window(model_or_spec, window)

Return a `ModelSpec` with explicit weather-window selection strategy.
"""
with_meteo_window(model_or_spec, window) =
    _with_spec(model_or_spec; meteo_window=_normalize_meteo_window(window))

"""
    with_output_routing(model_or_spec, routing)

Return a `ModelSpec` with explicit user-defined output routing.
"""
with_output_routing(model_or_spec, routing) =
    _with_spec(model_or_spec; output_routing=_normalize_output_routing(routing))

"""
    with_updates(model_or_spec, updates)

Return a `ModelSpec` with explicit variable-update metadata.
"""
function with_updates(model_or_spec, updates)
    spec = as_model_spec(model_or_spec)
    return ModelSpec(spec; updates=(spec.updates..., _normalize_updates(updates)...))
end

(updates::Updates)(model_or_spec) = with_updates(model_or_spec, updates)

function _normalize_meteo_binding(binding)
    if binding isa DataType
        binding <: PlantMeteo.AbstractTimeReducer || error(
            "Unsupported environment reducer type `$(binding)`. ",
            "Use a PlantMeteo reducer type/instance, callable, or NamedTuple(source=..., reducer=...)."
        )
        return binding
    elseif binding isa PlantMeteo.AbstractTimeReducer
        return binding
    elseif binding isa Function
        return binding
    elseif binding isa NamedTuple
        return binding
    end
    error(
        "Unsupported environment binding `$(binding)` of type `$(typeof(binding))`. ",
        "Use a PlantMeteo reducer type/instance, callable, or NamedTuple(source=..., reducer=...)."
    )
end

function _normalize_meteo_bindings(bindings::NamedTuple)
    normalized = Pair{Symbol,Any}[]
    for (k, v) in pairs(bindings)
        push!(normalized, k => _normalize_meteo_binding(v))
    end
    return (; normalized...)
end

function _normalize_meteo_bindings(bindings)
    error("Unsupported environment bindings `$(bindings)` of type `$(typeof(bindings))`.")
end

function _normalize_meteo_window(window)
    if isnothing(window)
        return nothing
    elseif window isa DataType
        window <: PlantMeteo.AbstractSamplingWindow || error(
            "Unsupported environment sampling-window type `$(window)`. ",
            "Use a PlantMeteo sampling-window type/instance."
        )
        return window()
    elseif window isa PlantMeteo.AbstractSamplingWindow
        return window
    end

    error(
        "Unsupported environment sampling window `$(window)` of type `$(typeof(window))`. ",
        "Use a PlantMeteo sampling-window type/instance."
    )
end

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

function _normalize_output_routing(routing)
    error("Unsupported OutputRouting value `$(routing)` of type `$(typeof(routing))`. Use a NamedTuple, e.g. `OutputRouting(; x=:stream_only)`.")
end

"""
    AppliesTo(selector)

Pipe-style transform that sets the object selector where a model application
runs in the unified scene/object API.
"""
AppliesTo(selector) = x -> with_applies_to(x, selector)

"""
    Inputs(bindings...)
    Inputs(; kwargs...)

Pipe-style transform that sets value-input bindings in the unified
scene/object API.
"""
Inputs(bindings::Pair...) = x -> with_inputs(x, bindings)
Inputs(bindings::NamedTuple) = x -> with_inputs(x, bindings)
Inputs(; kwargs...) = Inputs((; kwargs...))

"""
    Calls(bindings...)
    Calls(; kwargs...)

Pipe-style transform that sets manual model-call bindings in the unified
scene/object API.
"""
Calls(bindings::Pair...) = x -> with_calls(x, bindings)
Calls(bindings::NamedTuple) = x -> with_calls(x, bindings)
Calls(; kwargs...) = Calls((; kwargs...))

"""
    TimeStep(timestep)

Pipe-style transform that sets a user-selected timestep for a model
application.
"""
TimeStep(timestep) = x -> with_timestep(x, timestep)

"""
    Environment(config)
    Environment(; kwargs...)

Pipe-style transform that stores scene/object environment configuration
metadata on a `ModelSpec`.
"""
Environment(config) = x -> with_environment(x, config isa EnvironmentConfig ? config : EnvironmentConfig(config))
Environment(; kwargs...) = Environment((; kwargs...))

"""
    OutputRouting(routing)
    OutputRouting(; kwargs...)

Pipe-style transform that sets output publication mode for a model.

This is mainly used to disambiguate publishers in multi-rate runs when several
models write variables with the same name.

# Arguments
- `routing::NamedTuple`: maps output variable symbols to routing mode.
- `kwargs...`: keyword shorthand equivalent to a `NamedTuple`.

Allowed routing values:
- `:canonical` (default): output is considered canonical at that scale and can
  be auto-selected as source/export publisher.
- `:stream_only`: output is kept only in temporal streams and excluded from
  canonical publisher resolution.

# Example
```julia
ModelSpec(AltSourceModel()) |>
OutputRouting(; C=:stream_only)
```
"""
OutputRouting(routing) = x -> with_output_routing(x, routing)
OutputRouting(; kwargs...) = OutputRouting((; kwargs...))

model_(m::ModelSpec) = m.model
process(m::ModelSpec) = process(model_(m))
timestep(m::ModelSpec) = m.timestep
inputs_(m::ModelSpec) = inputs_(model_(m))
outputs_(m::ModelSpec) = outputs_(model_(m))

function dep(spec::ModelSpec)
    dependencies = dep(model_(spec))
    kept = Pair{Symbol,Any}[]
    for (name, selector) in pairs(dependencies)
        selector isa Union{Input,Call} && continue
        push!(kept, name => selector)
    end
    return (; kept...)
end
meteo_inputs_(m::ModelSpec) = meteo_inputs_(model_(m))
meteo_outputs_(m::ModelSpec) = meteo_outputs_(model_(m))

function run!(m::ModelSpec, models, status, meteo, constants=nothing, extra=nothing)
    return run!(model_(m), models, status, meteo, constants, extra)
end

"""
    ModelSpec(model; name=nothing, applies_to=nothing, inputs=NamedTuple(), calls=NamedTuple(), environment=nothing, multiscale=nothing, timestep=nothing, input_bindings=NamedTuple(), meteo_bindings=NamedTuple(), meteo_window=nothing, output_routing=NamedTuple(), scope=:global, updates=())

User-side model configuration wrapper for mapping/model list composition.

`ModelSpec` keeps model implementation and scenario-specific usage metadata in one place.
This allows modelers to publish reusable models while users decide how models are coupled in
their simulation setup.
"""
struct ModelSpec{M,N,AT,IN,IO,CA,CO,EV,MS,TS,IB,MB,MW,OR,SC,UP}
    model::M
    name::N
    applies_to::AT
    inputs::IN
    input_origins::IO
    calls::CA
    call_origins::CO
    environment::EV
    multiscale::MS
    timestep::TS
    input_bindings::IB
    meteo_bindings::MB
    meteo_window::MW
    output_routing::OR
    scope::SC
    updates::UP
end

"""
    Updates(vars...; after=nothing)

Scenario-level declaration that a model updates variables which may also be
computed by another model at the same scale.

`after` is intentionally mapping-level metadata: the model implementation stays
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

function _normalize_multiscale_mapping(model::AbstractModel, mapped_variables)
    mapped_variables === nothing && return nothing
    mapped = MultiScaleModel(model, mapped_variables)
    return mapped_variables_(mapped)
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
    multiscale=nothing,
    timestep=nothing,
    input_bindings=NamedTuple(),
    meteo_bindings=NamedTuple(),
    meteo_window=nothing,
    output_routing=NamedTuple(),
    scope=:global,
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
    derived_multiscale = _legacy_multiscale_from_value_inputs(normalized_inputs, base_model)
    combined_multiscale = _merge_legacy_multiscale(multiscale, derived_multiscale)
    normalized_multiscale = _normalize_multiscale_mapping(base_model, combined_multiscale)
    normalized_input_bindings = _normalize_input_bindings(input_bindings)
    normalized_meteo_bindings = _normalize_meteo_bindings(meteo_bindings)
    normalized_meteo_window = _normalize_meteo_window(meteo_window)
    normalized_output_routing = _normalize_output_routing(output_routing)
    normalized_scope = _normalize_scope_selector(scope)
    normalized_updates = _normalize_updates(updates)
    return ModelSpec{typeof(base_model),typeof(normalized_name),typeof(applies_to),typeof(normalized_inputs),typeof(normalized_input_origins),typeof(normalized_calls),typeof(normalized_call_origins),typeof(environment),typeof(normalized_multiscale),typeof(timestep),typeof(normalized_input_bindings),typeof(normalized_meteo_bindings),typeof(normalized_meteo_window),typeof(normalized_output_routing),typeof(normalized_scope),typeof(normalized_updates)}(
        base_model,
        normalized_name,
        applies_to,
        normalized_inputs,
        normalized_input_origins,
        normalized_calls,
        normalized_call_origins,
        environment,
        normalized_multiscale,
        timestep,
        normalized_input_bindings,
        normalized_meteo_bindings,
        normalized_meteo_window,
        normalized_output_routing,
        normalized_scope,
        normalized_updates
    )
end

function ModelSpec(
    model::MultiScaleModel;
    name=nothing,
    applies_to=nothing,
    inputs=NamedTuple(),
    input_origins=nothing,
    calls=NamedTuple(),
    call_origins=nothing,
    environment=nothing,
    multiscale=nothing,
    timestep=nothing,
    input_bindings=NamedTuple(),
    meteo_bindings=NamedTuple(),
    meteo_window=nothing,
    output_routing=NamedTuple(),
    scope=:global,
    updates=()
)
    base_multiscale = isnothing(multiscale) ? mapped_variables_(model) : multiscale
    return ModelSpec(
        model_(model);
        name=name,
        applies_to=applies_to,
        inputs=inputs,
        input_origins=input_origins,
        calls=calls,
        call_origins=call_origins,
        environment=environment,
        multiscale=base_multiscale,
        timestep=timestep,
        input_bindings=input_bindings,
        meteo_bindings=meteo_bindings,
        meteo_window=meteo_window,
        output_routing=output_routing,
        scope=scope,
        updates=updates
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
    multiscale=spec.multiscale,
    timestep=spec.timestep,
    input_bindings=spec.input_bindings,
    meteo_bindings=spec.meteo_bindings,
    meteo_window=spec.meteo_window,
    output_routing=spec.output_routing,
    scope=spec.scope,
    updates=spec.updates
)
    ModelSpec(model; name=name, applies_to=applies_to, inputs=inputs, input_origins=input_origins, calls=calls, call_origins=call_origins, environment=environment, multiscale=multiscale, timestep=timestep, input_bindings=input_bindings, meteo_bindings=meteo_bindings, meteo_window=meteo_window, output_routing=output_routing, scope=scope, updates=updates)
end

as_model_spec(spec::ModelSpec) = spec
as_model_spec(model::AbstractModel) = ModelSpec(model)
as_model_spec(model::MultiScaleModel) = ModelSpec(model_(model); multiscale=mapped_variables_(model))

"""
    with_name(model_or_spec, name)

Return a `ModelSpec` with an explicit model-application name.
"""
function with_name(model_or_spec, name)
    spec = as_model_spec(model_or_spec)
    return ModelSpec(spec; name=_normalize_application_name(name))
end

"""
    with_applies_to(model_or_spec, selector)

Return a `ModelSpec` with an explicit model-application target selector.
"""
function with_applies_to(model_or_spec, selector)
    spec = as_model_spec(model_or_spec)
    return ModelSpec(spec; applies_to=selector)
end

"""
    with_inputs(model_or_spec, bindings)

Return a `ModelSpec` with unified scene/object value-input bindings.
"""
function with_inputs(model_or_spec, bindings)
    spec = as_model_spec(model_or_spec)
    explicit = _normalize_application_bindings(bindings)
    origins = _binding_origins(_model_default_value_inputs(model_(spec)), explicit)
    return ModelSpec(spec; inputs=explicit, input_origins=origins)
end

"""
    with_calls(model_or_spec, bindings)

Return a `ModelSpec` with unified scene/object manual model-call bindings.
"""
function with_calls(model_or_spec, bindings)
    spec = as_model_spec(model_or_spec)
    explicit = _normalize_application_bindings(bindings)
    origins = _binding_origins(_model_default_model_calls(model_(spec)), explicit)
    return ModelSpec(spec; calls=explicit, call_origins=origins)
end

"""
    with_environment(model_or_spec, environment)

Return a `ModelSpec` with scene/object environment configuration metadata.
"""
function with_environment(model_or_spec, environment)
    spec = as_model_spec(model_or_spec)
    return ModelSpec(spec; environment=environment)
end

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
    with_meteo_bindings(model_or_spec, bindings)

Return a `ModelSpec` with explicit meteo aggregation bindings.
"""
function with_meteo_bindings(model_or_spec, bindings)
    spec = as_model_spec(model_or_spec)
    return ModelSpec(spec; meteo_bindings=_normalize_meteo_bindings(bindings))
end

"""
    with_meteo_window(model_or_spec, window)

Return a `ModelSpec` with explicit weather-window selection strategy.
"""
function with_meteo_window(model_or_spec, window)
    spec = as_model_spec(model_or_spec)
    return ModelSpec(spec; meteo_window=_normalize_meteo_window(window))
end

"""
    with_output_routing(model_or_spec, routing)

Return a `ModelSpec` with explicit user-defined output routing.
"""
function with_output_routing(model_or_spec, routing)
    spec = as_model_spec(model_or_spec)
    return ModelSpec(spec; output_routing=_normalize_output_routing(routing))
end

"""
    with_scope(model_or_spec, scope)

Return a `ModelSpec` with explicit scope selection for multi-rate stream keys.
"""
function with_scope(model_or_spec, scope)
    spec = as_model_spec(model_or_spec)
    return ModelSpec(spec; scope=_normalize_scope_selector(scope))
end

"""
    with_updates(model_or_spec, updates)

Return a `ModelSpec` with explicit variable-update metadata.
"""
function with_updates(model_or_spec, updates)
    spec = as_model_spec(model_or_spec)
    return ModelSpec(spec; updates=(spec.updates..., _normalize_updates(updates)...))
end

(updates::Updates)(model_or_spec) = with_updates(model_or_spec, updates)

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

function _normalize_input_bindings(bindings)
    error("Unsupported InputBindings value `$(bindings)` of type `$(typeof(bindings))`. Use a NamedTuple, e.g. `InputBindings(; x=(process=:producer, var=:y))`.")
end

function _normalize_meteo_binding(binding)
    if binding isa DataType
        binding <: PlantMeteo.AbstractTimeReducer || error(
            "Unsupported MeteoBindings reducer type `$(binding)`. ",
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
        "Unsupported MeteoBindings value `$(binding)` of type `$(typeof(binding))`. ",
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
    error("Unsupported MeteoBindings value `$(bindings)` of type `$(typeof(bindings))`. Use a NamedTuple, e.g. `MeteoBindings(; T=MeanReducer())`.")
end

function _normalize_meteo_window(window)
    if isnothing(window)
        return nothing
    elseif window isa DataType
        window <: PlantMeteo.AbstractSamplingWindow || error(
            "Unsupported MeteoWindow type `$(window)`. ",
            "Use a PlantMeteo sampling-window type/instance."
        )
        return window()
    elseif window isa PlantMeteo.AbstractSamplingWindow
        return window
    end

    error(
        "Unsupported MeteoWindow value `$(window)` of type `$(typeof(window))`. ",
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

function _normalize_scope_selector(scope)
    if scope isa AbstractString
        error("String scope selectors are not supported. Use symbols such as `:global`, `:plant`, `:scene`, or `:self`.")
    end
    return scope
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

Pipe-style transform that sets a user-selected timestep in the unified
scene/object API. This is the breaking-design name for `TimeStepModel(...)`.
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
    PlantSimEngine.MultiScaleModel(mapped_variables)

Pipe-style transform that updates multiscale mapping on a model/spec.
"""
MultiScaleModel(mapped_variables) = x -> with_multiscale(x, mapped_variables)

"""
    PlantSimEngine.TimeStepModel(timestep)

Pipe-style transform that sets a user-selected timestep on a model/spec.
"""
TimeStepModel(timestep) = x -> with_timestep(x, timestep)

"""
    PlantSimEngine.InputBindings(bindings)
    PlantSimEngine.InputBindings(; kwargs...)

Pipe-style transform that sets explicit producer bindings for model inputs.

This is used in multi-rate mappings to tell runtime where each input should be
read from (process, optional source variable, optional source scale, and policy).

# Arguments
- `bindings::NamedTuple`: maps each consumer input variable (`Symbol`) to a
  binding descriptor.
- `kwargs...`: keyword shorthand equivalent to a `NamedTuple`.

Each binding descriptor can be:
- `Symbol`: producer process (`policy=HoldLast()` and source variable inferred).
- `Pair{Symbol,Symbol}`: `producer_process => source_var`
  (`policy=HoldLast()`).
- `NamedTuple`: explicit fields:
  - `process` (`Symbol`/`String`, optional if uniquely inferable),
  - `var` (`Symbol`, optional, defaults to same-name input when inferable),
  - `scale` (`String`/`Symbol`, optional, useful for cross-scale disambiguation),
  - `policy` (`SchedulePolicy` instance/type, optional, default `HoldLast()`).

When omitted fields cannot be inferred uniquely, runtime errors and asks for an
explicit `PlantSimEngine.InputBindings(...)`.

# Example
```julia
ModelSpec(ConsumerModel()) |>
PlantSimEngine.TimeStepModel(ClockSpec(24.0, 0.0)) |>
PlantSimEngine.InputBindings(; A=(process=:assim, var=:carbon_assimilation, scale=:Leaf, policy=Integrate()))
```
"""
InputBindings(bindings) = x -> with_input_bindings(x, bindings)
InputBindings(; kwargs...) = InputBindings((; kwargs...))

"""
    PlantSimEngine.MeteoBindings(bindings)
    PlantSimEngine.MeteoBindings(; kwargs...)

Pipe-style transform that sets weather-variable aggregation rules per model.

Each key is the target weather variable name as seen by the model (for example
`:T`, `:Rh`, `:Ri_SW_q`).

# Arguments
- `bindings::NamedTuple`: per-target meteo binding rules.
- `kwargs...`: keyword shorthand equivalent to a `NamedTuple`.

Each rule value can be:
- a `PlantMeteo.AbstractTimeReducer` instance/type
  (for example `MeanWeighted()`, `MaxReducer`, `RadiationEnergy()`),
- a callable reducer (`Function`) receiving sampled values,
- a `NamedTuple` with:
  - `source` (`Symbol`/`String`, optional, defaults to target key),
  - `reducer` (reducer type/instance/callable, optional, defaults to
    `MeanWeighted()`).

# Example
```julia
ModelSpec(DailyModel()) |>
PlantSimEngine.TimeStepModel(ClockSpec(24.0, 0.0)) |>
PlantSimEngine.MeteoBindings(
    ;
    T=MeanWeighted(),
    Rh=MeanWeighted(),
    Ri_SW_q=(source=:Ri_SW_f, reducer=RadiationEnergy()),
)
```
"""
MeteoBindings(bindings) = x -> with_meteo_bindings(x, bindings)
MeteoBindings(; kwargs...) = MeteoBindings((; kwargs...))

"""
    PlantSimEngine.MeteoWindow(window)

Pipe-style transform that sets the weather row-selection window for one model.

This controls which meteo rows are sampled before
`PlantSimEngine.MeteoBindings` reducers are applied.

# Arguments
- `window`: a `PlantMeteo.AbstractSamplingWindow` instance/type.
  Typical values are:
  - `PlantMeteo.RollingWindow()` (default trailing window),
  - `PlantMeteo.CalendarWindow(...)` (calendar-aligned day/week/month windows).

# Example
```julia
ModelSpec(DailyModel()) |>
PlantSimEngine.TimeStepModel(ClockSpec(24.0, 0.0)) |>
PlantSimEngine.MeteoWindow(CalendarWindow(:day; anchor=:current_period, week_start=1, completeness=:strict))
```
"""
MeteoWindow(window) = x -> with_meteo_window(x, window)

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

"""
    PlantSimEngine.ScopeModel(scope)

Pipe-style transform that sets stream scope selection for a model.

Scope controls how temporal streams are partitioned/resolved across entities in
multi-rate simulations.

# Arguments
- `scope`: one of:
  - selector symbols: `:global`, `:plant`, `:scene`, `:self`,
  - a concrete `ScopeId`,
  - a callable returning a scope selector symbol or `ScopeId` at runtime.

# Example
```julia
ModelSpec(LeafSourceModel()) |>
PlantSimEngine.ScopeModel(:plant)
```
"""
ScopeModel(scope) = x -> with_scope(x, scope)

model_(m::ModelSpec) = m.model
mapped_variables_(m::ModelSpec) = isnothing(m.multiscale) ? Pair{Symbol,String}[] : m.multiscale
get_models(m::ModelSpec) = [model_(m)]
get_status(m::ModelSpec) = nothing
get_mapped_variables(m::ModelSpec) = mapped_variables_(m)
process(m::ModelSpec) = process(model_(m))
timestep(m::ModelSpec) = m.timestep
inputs_(m::ModelSpec) = inputs_(model_(m))
outputs_(m::ModelSpec) = outputs_(model_(m))

function _normalize_model_spec_dependencies(deps::NamedTuple)
    normalized = Pair{Symbol,Any}[]
    for (dep_name, selector) in pairs(deps)
        selector isa Union{Input,Call} && continue
        push!(normalized, dep_name => selector)
    end
    return (; normalized...)
end

function dep(m::ModelSpec)
    return _normalize_model_spec_dependencies(dep(model_(m)))
end
init_variables(m::ModelSpec; verbose::Bool=true) = init_variables(model_(m); verbose=verbose)
meteo_inputs_(m::ModelSpec) = meteo_inputs_(model_(m))
meteo_outputs_(m::ModelSpec) = meteo_outputs_(model_(m))

function run!(m::ModelSpec, models, status, meteo, constants=nothing, extra=nothing)
    return run!(model_(m), models, status, meteo, constants, extra)
end

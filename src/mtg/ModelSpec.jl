"""
    ModelSpec(model; multiscale=nothing, timestep=nothing, input_bindings=NamedTuple(), meteo_bindings=NamedTuple(), meteo_window=nothing, output_routing=NamedTuple(), scope=:global)

User-side model configuration wrapper for mapping/model list composition.

`ModelSpec` keeps model implementation and scenario-specific usage metadata in one place.
This allows modelers to publish reusable models while users decide how models are coupled in
their simulation setup.
"""
struct ModelSpec{M,MS,TS,IB,MB,MW,OR,SC}
    model::M
    multiscale::MS
    timestep::TS
    input_bindings::IB
    meteo_bindings::MB
    meteo_window::MW
    output_routing::OR
    scope::SC
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
    meteo_bindings=NamedTuple(),
    meteo_window=nothing,
    output_routing=NamedTuple(),
    scope=:global
)
    base_model = model
    base_multiscale = multiscale

    if model isa MultiScaleModel
        base_model = model_(model)
        base_multiscale === nothing && (base_multiscale = mapped_variables_(model))
    end

    normalized_multiscale = _normalize_multiscale_mapping(base_model, base_multiscale)
    normalized_input_bindings = _normalize_input_bindings(input_bindings)
    normalized_meteo_bindings = _normalize_meteo_bindings(meteo_bindings)
    normalized_meteo_window = _normalize_meteo_window(meteo_window)
    normalized_output_routing = _normalize_output_routing(output_routing)
    normalized_scope = _normalize_scope_selector(scope)
    return ModelSpec{typeof(base_model),typeof(normalized_multiscale),typeof(timestep),typeof(normalized_input_bindings),typeof(normalized_meteo_bindings),typeof(normalized_meteo_window),typeof(normalized_output_routing),typeof(normalized_scope)}(
        base_model,
        normalized_multiscale,
        timestep,
        normalized_input_bindings,
        normalized_meteo_bindings,
        normalized_meteo_window,
        normalized_output_routing,
        normalized_scope
    )
end

function ModelSpec(
    spec::ModelSpec;
    model=spec.model,
    multiscale=spec.multiscale,
    timestep=spec.timestep,
    input_bindings=spec.input_bindings,
    meteo_bindings=spec.meteo_bindings,
    meteo_window=spec.meteo_window,
    output_routing=spec.output_routing,
    scope=spec.scope
)
    ModelSpec(model; multiscale=multiscale, timestep=timestep, input_bindings=input_bindings, meteo_bindings=meteo_bindings, meteo_window=meteo_window, output_routing=output_routing, scope=scope)
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

_normalize_meteo_bindings(bindings) = bindings

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

_normalize_output_routing(routing) = routing

function _normalize_scope_selector(scope)
    if scope isa AbstractString
        return Symbol(scope)
    end
    return scope
end

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
explicit `InputBindings(...)`.

# Example
```julia
ModelSpec(ConsumerModel()) |>
TimeStepModel(ClockSpec(24.0, 0.0)) |>
InputBindings(; A=(process=:assim, var=:carbon_assimilation, scale="Leaf", policy=Integrate()))
```
"""
InputBindings(bindings) = x -> with_input_bindings(x, bindings)
InputBindings(; kwargs...) = InputBindings((; kwargs...))

"""
    MeteoBindings(bindings)
    MeteoBindings(; kwargs...)

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
TimeStepModel(ClockSpec(24.0, 0.0)) |>
MeteoBindings(
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
    MeteoWindow(window)

Pipe-style transform that sets the weather row-selection window for one model.

This controls which meteo rows are sampled before `MeteoBindings` reducers are
applied.

# Arguments
- `window`: a `PlantMeteo.AbstractSamplingWindow` instance/type.
  Typical values are:
  - `PlantMeteo.RollingWindow()` (default trailing window),
  - `PlantMeteo.CalendarWindow(...)` (calendar-aligned day/week/month windows).

# Example
```julia
ModelSpec(DailyModel()) |>
TimeStepModel(ClockSpec(24.0, 0.0)) |>
MeteoWindow(CalendarWindow(:day; anchor=:current_period, week_start=1, completeness=:strict))
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
    ScopeModel(scope)

Pipe-style transform that sets stream scope selection for a model.

Scope controls how temporal streams are partitioned/resolved across entities in
multi-rate simulations.

# Arguments
- `scope`: one of:
  - selector symbols/strings: `:global`, `:plant`, `:scene`, `:self`,
  - a concrete `ScopeId`,
  - a callable returning a scope selector/id at runtime.

# Example
```julia
ModelSpec(LeafSourceModel()) |>
ScopeModel(:plant)
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

"""
    AbstractEnvironmentBackend

Backend protocol for meteorology and mutable microclimate providers.

PlantSimEngine defines the protocol, not the spatial indexing strategy. External
packages can subtype this and implement `sample`, `commit_environment!`,
`update_index!`, `get_nsteps`, and `base_step_seconds`.
"""
abstract type AbstractEnvironmentBackend end

"""
    EnvironmentContext(application, object_id, scale, process)

Immutable model-target metadata passed to [`bind_environment`](@ref). Backends
return an opaque handle from that method and use the handle for all subsequent
sampling and commits. Runtime status and geometry are intentionally absent:
object-to-environment routing belongs to the compiled handle.
"""
struct EnvironmentContext{O}
    application::Symbol
    object_id::O
    scale::Symbol
    process::Symbol
end

"""
    GlobalConstant(meteo)

Environment backend that preserves the current PlantSimEngine behavior: every
model receives the same meteo object or meteo row at a given timestep.
"""
struct GlobalConstant{M} <: AbstractEnvironmentBackend
    meteo::M
end

environment_meteo(backend::GlobalConstant) = backend.meteo

"""
    environment_backend(meteo_or_backend)

Return an environment backend. Plain meteorology is wrapped in
`GlobalConstant`; existing environment backends are returned unchanged.
"""
environment_backend(backend::AbstractEnvironmentBackend) = backend
environment_backend(meteo) = GlobalConstant(meteo)

"""
    base_step_seconds(backend)

Return the duration of one simulation base step in seconds.
"""
function base_step_seconds(backend::AbstractEnvironmentBackend)
    error(
        "Environment backend `$(typeof(backend))` must implement ",
        "`PlantSimEngine.base_step_seconds(backend)`."
    )
end

function base_step_seconds(backend::GlobalConstant)
    return _timeline_context(environment_meteo(backend)).base_step_seconds
end

get_nsteps(backend::AbstractEnvironmentBackend) = error(
    "Environment backend `$(typeof(backend))` must implement ",
    "`PlantSimEngine.get_nsteps(backend)`."
)
get_nsteps(backend::GlobalConstant) = isnothing(environment_meteo(backend)) ? 1 : get_nsteps(environment_meteo(backend))

function _validate_meteo_duration(backend::AbstractEnvironmentBackend)
    sec = base_step_seconds(backend)
    sec isa Real && sec > 0 || error(
        "Environment backend `$(typeof(backend))` returned invalid base step seconds `$(sec)`."
    )
    return nothing
end

_validate_meteo_duration(backend::GlobalConstant) = _validate_meteo_duration(environment_meteo(backend))

_timeline_context(backend::AbstractEnvironmentBackend) = TimelineContext(float(base_step_seconds(backend)))
_timeline_context(backend::GlobalConstant) = _timeline_context(environment_meteo(backend))

function _meteo_row_at_step(meteo, i::Int)
    isnothing(meteo) && return nothing
    if meteo isa TimeStepTable || DataFormat(meteo) == TableAlike()
        return first(Iterators.drop(Tables.rows(meteo), i - 1))
    end
    return meteo
end

function _available_meteo_variables(meteo)
    row = _first_meteo_row(meteo)
    isnothing(row) && return nothing
    return Set(Symbol.(propertynames(row)))
end

"""
    environment_variables(backend)

Return a set of variable names that the backend can provide, or `nothing` when
the backend cannot enumerate them cheaply.
"""
environment_variables(::AbstractEnvironmentBackend) = nothing
function environment_variables(backend::GlobalConstant)
    meteo = environment_meteo(backend)
    isnothing(meteo) && return Set{Symbol}()
    return _available_meteo_variables(meteo)
end

function validate_meteo_inputs(model_specs::Dict{Symbol,Dict{Symbol,ModelSpec}}, backend::GlobalConstant)
    return invoke(
        validate_meteo_inputs,
        Tuple{Dict{Symbol,Dict{Symbol,ModelSpec}},AbstractEnvironmentBackend},
        model_specs,
        backend,
    )
end

function validate_meteo_inputs(model_specs::Dict{Symbol,Dict{Symbol,ModelSpec}}, backend::AbstractEnvironmentBackend)
    available = environment_variables(backend)
    isnothing(available) && return nothing

    missing_rows = _collect_missing_meteo_rows(model_specs, var -> var in available)
    return _error_missing_meteo_inputs(
        missing_rows;
        subject="Environment backend `$(typeof(backend))`",
        noun="variables",
        target="the backend"
    )
end

function _model_validation_scale(model::CompositeModel, application::CompiledModelApplication)
    scales = Set{Symbol}()
    for object_id in application.target_ids
        object = _model_object(model, object_id)
        isnothing(object.scale) || push!(scales, object.scale)
    end
    isempty(scales) && return :Scene
    length(scales) == 1 && return only(scales)
    return :Scene
end

function _model_model_specs_by_application(compiled::CompiledCompositeModel)
    specs = Dict{Symbol,Dict{Symbol,ModelSpec}}()
    for application in compiled.applications
        scale = _model_validation_scale(compiled.model, application)
        specs_at_scale = get!(specs, scale, Dict{Symbol,ModelSpec}())
        specs_at_scale[application.id] = application.spec
    end
    return specs
end

"""
    validate_meteo_inputs(model::CompositeModel)
    validate_meteo_inputs(compiled::CompiledCompositeModel)
    validate_meteo_inputs(compiled::CompiledCompositeModel, meteo_or_backend)

Validate declared composite-model/object `meteo_inputs_`.

The one-argument methods validate each application against its actual compiled
environment backend, including application-level `Environment(...)` overrides.
The two-argument method validates every compiled application against an
explicit replacement meteorology/environment backend. Diagnostics report model
application ids, so several applications for the same process can be diagnosed
independently.
"""
function validate_meteo_inputs(compiled::CompiledCompositeModel, meteo_or_backend)
    backend = environment_backend(meteo_or_backend)
    return validate_meteo_inputs(_model_model_specs_by_application(compiled), backend)
end

function validate_meteo_inputs(compiled::CompiledCompositeModel)
    refresh_environment_bindings!(compiled.model, compiled)
    return nothing
end

function validate_meteo_inputs(model::CompositeModel)
    compiled = refresh_bindings!(model)
    return validate_meteo_inputs(compiled)
end

function validate_meteo_inputs(model::CompositeModel, meteo_or_backend)
    compiled = refresh_bindings!(model)
    return validate_meteo_inputs(compiled, meteo_or_backend)
end

"""
    sample(backend, handle, variable, time)
    sample(backend, handle, state, variable, time)

Sample one environmental variable through an opaque compiled backend `handle`.
The four-argument method reads the backend's committed state. The five-argument
method reads a transient backend-specific `state` supplied through
`run_call!(extra, name; environment=state)`.
"""
function sample(backend::AbstractEnvironmentBackend, handle, variable::Symbol, time)
    error(
        "Environment backend `$(typeof(backend))` must implement ",
        "`PlantSimEngine.sample(backend, handle, variable, time)`."
    )
end

function sample(backend::AbstractEnvironmentBackend, handle, state, variable::Symbol, time)
    error(
        "Environment backend `$(typeof(backend))` must implement transient sampling with ",
        "`PlantSimEngine.sample(backend, handle, state, variable, time)` for state ",
        "`$(typeof(state))`."
    )
end

function sample(backend::GlobalConstant, handle, variable::Symbol, time)
    meteo = _meteo_row_at_step(environment_meteo(backend), Int(round(time)))
    isnothing(meteo) && return nothing
    hasproperty(meteo, variable) || error(
        "GlobalConstant meteo does not provide variable `$(variable)`."
    )
    return getproperty(meteo, variable)
end

function sample(backend::GlobalConstant, handle, state, variable::Symbol, time)
    meteo = _meteo_row_at_step(state, Int(round(time)))
    isnothing(meteo) && return nothing
    hasproperty(meteo, variable) || error(
        "Transient GlobalConstant state does not provide variable `$(variable)`."
    )
    return getproperty(meteo, variable)
end

"""
    commit_environment!(backend, handle, state, time)

Commit an accepted environment `state` through an opaque compiled backend
`handle`. Model kernels call `commit_environment!(extra, state)`; backend
authors implement this method for their concrete mutable environment.
"""
function commit_environment!(backend::AbstractEnvironmentBackend, handle, state, time)
    error(
        "Environment backend `$(typeof(backend))` does not implement ",
        "`PlantSimEngine.commit_environment!(backend, handle, state, time)`."
    )
end

commit_environment!(backend::GlobalConstant, handle, state, time) = error(
    "GlobalConstant is immutable and cannot receive an accepted environment commit."
)

"""
    update_index!(backend, entities)

Update the backend spatial/entity index after topology or geometry changes.
"""
update_index!(::AbstractEnvironmentBackend, entities) = nothing
update_index!(::GlobalConstant, entities) = nothing

"""
    sample_environment(backend, handle, time, variables)
    sample_environment(backend, handle, state, time, variables)

Sample a model-facing meteo row through a compiled backend `handle`.
`GlobalConstant` returns the original row; other backends return a `NamedTuple`
assembled from `sample` calls. The overload containing `state` preserves the
same handle while sampling a transient environment.
"""
function sample_environment(
    backend::AbstractEnvironmentBackend,
    handle,
    time,
    variables,
)
    pairs = Pair{Symbol,Any}[]
    for variable in variables
        push!(pairs, variable => sample(backend, handle, variable, time))
    end
    return (; pairs...)
end

function sample_environment(
    backend::AbstractEnvironmentBackend,
    handle,
    state,
    time,
    variables,
)
    pairs = Pair{Symbol,Any}[]
    for variable in variables
        push!(pairs, variable => sample(backend, handle, state, variable, time))
    end
    return (; pairs...)
end

function sample_environment(
    backend::GlobalConstant,
    handle,
    time,
    variables,
)
    return _meteo_row_at_step(environment_meteo(backend), Int(round(time)))
end

function sample_environment(
    backend::GlobalConstant,
    handle,
    state,
    time,
    variables,
)
    return _meteo_row_at_step(state, Int(round(time)))
end

function _environment_sampling_rules(model_spec::ModelSpec)
    bindings = meteo_bindings(model_spec)
    bindings = bindings isa NamedTuple ? bindings : NamedTuple()
    environment_sources = _environment_source_overrides(model_spec)
    rules = Pair{Symbol,Symbol}[]
    for target in keys(meteo_inputs_(model_spec))
        source = target
        if haskey(bindings, target)
            rule = bindings[target]
            rule isa NamedTuple && haskey(rule, :source) && (source = Symbol(rule.source))
        end
        if haskey(environment_sources, target)
            source = Symbol(environment_sources[target])
        end
        push!(rules, target => source)
    end
    return rules
end

function _environment_source_overrides(model_spec::ModelSpec)
    config = environment_config(model_spec)
    payload = config isa EnvironmentConfig ? config.config : config
    if payload isa NamedTuple && haskey(payload, :sources)
        sources = payload.sources
        sources isa NamedTuple || error(
            "Environment `sources` must be a NamedTuple, for example ",
            "`Environment(; sources=(CO2=:Ca,))`."
        )
        return sources
    end
    return NamedTuple()
end

function sample_environment(
    backend::AbstractEnvironmentBackend,
    handle,
    time,
    model_spec::ModelSpec
)
    pairs = Pair{Symbol,Any}[]
    for (target, source) in _environment_sampling_rules(model_spec)
        push!(pairs, target => sample(backend, handle, source, time))
    end
    return (; pairs...)
end

function sample_environment(
    backend::AbstractEnvironmentBackend,
    handle,
    state,
    time,
    model_spec::ModelSpec
)
    pairs = Pair{Symbol,Any}[]
    for (target, source) in _environment_sampling_rules(model_spec)
        push!(pairs, target => sample(backend, handle, state, source, time))
    end
    return (; pairs...)
end

function _sample_global_environment_row(row, model_spec::ModelSpec)
    bindings = meteo_bindings(model_spec)
    has_bindings = bindings isa NamedTuple && !isempty(keys(bindings))
    environment_sources = _environment_source_overrides(model_spec)
    has_environment_sources = !isempty(keys(environment_sources))
    !has_bindings && !has_environment_sources && return row

    pairs = Pair{Symbol,Any}[]
    for (target, source) in _environment_sampling_rules(model_spec)
        isnothing(row) && error(
            "GlobalConstant meteo is `nothing`, but the model requires meteo variable ",
            "`$(target)`."
        )
        hasproperty(row, source) || error(
            "GlobalConstant meteo does not provide source variable `$(source)` for model-facing variable ",
            "`$(target)`."
        )
        push!(pairs, target => getproperty(row, source))
    end
    if !isnothing(row) && hasproperty(row, :duration)
        push!(pairs, :duration => getproperty(row, :duration))
    end
    return (; pairs...)
end

function sample_environment(
    backend::GlobalConstant,
    handle,
    time,
    model_spec::ModelSpec,
)
    row = _meteo_row_at_step(environment_meteo(backend), Int(round(time)))
    return _sample_global_environment_row(row, model_spec)
end

function sample_environment(
    backend::GlobalConstant,
    handle,
    state,
    time,
    model_spec::ModelSpec,
)
    row = _meteo_row_at_step(state, Int(round(time)))
    return _sample_global_environment_row(row, model_spec)
end

"""
    explain_environment(simulation)

Return a compact description of the environment backend used by a model
simulation.
"""
function explain_environment(simulation)
    backend = simulation.environment
    return (
        backend=typeof(backend),
        variables=environment_variables(backend),
        nsteps=get_nsteps(backend),
        base_step_seconds=base_step_seconds(backend),
    )
end

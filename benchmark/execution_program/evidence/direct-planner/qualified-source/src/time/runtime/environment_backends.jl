"""
    AbstractEnvironmentBackend

Backend protocol for meteorology and mutable microclimate providers.

PlantSimEngine defines the protocol, not the spatial indexing strategy. External
packages subtype `PlantSimEngine.EnvironmentAPI.AbstractEnvironmentBackend`
and extend the functions in `PlantSimEngine.EnvironmentAPI`, including
`sample`, `commit_environment!`, `update_index!`, `get_nsteps`, and
`base_step_seconds`.
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
    GlobalConstant(source)

Environment backend that preserves the current PlantSimEngine behavior: every
model receives the same source object or source row at a given timestep.
"""
struct GlobalConstant{M} <: AbstractEnvironmentBackend
    source::M
end

environment_source(backend::GlobalConstant) = backend.source

"""
    environment_backend(environment_or_backend)

Return an environment backend. Plain environment data is wrapped in
`GlobalConstant`; existing environment backends are returned unchanged.
"""
environment_backend(backend::AbstractEnvironmentBackend) = backend
environment_backend(source) = GlobalConstant(source)

"""
    base_step_seconds(backend)

Return the duration of one simulation base step in seconds.
"""
function base_step_seconds(backend::AbstractEnvironmentBackend)
    error(
        "Environment backend `$(typeof(backend))` must implement ",
        "`PlantSimEngine.EnvironmentAPI.base_step_seconds(backend)`."
    )
end

function base_step_seconds(backend::GlobalConstant)
    return _timeline_context(environment_source(backend)).base_step_seconds
end

get_nsteps(backend::AbstractEnvironmentBackend) = error(
    "Environment backend `$(typeof(backend))` must implement ",
    "`PlantSimEngine.EnvironmentAPI.get_nsteps(backend)`."
)
get_nsteps(backend::GlobalConstant) = isnothing(environment_source(backend)) ? 1 : get_nsteps(environment_source(backend))

function _validate_environment_duration(backend::AbstractEnvironmentBackend)
    sec = base_step_seconds(backend)
    sec isa Real && isfinite(sec) && sec > 0 || error(
        "Environment backend `$(typeof(backend))` returned invalid base step seconds `$(sec)`."
    )
    return nothing
end

_validate_environment_duration(backend::GlobalConstant) = _validate_environment_duration(environment_source(backend))

_timeline_context(backend::AbstractEnvironmentBackend) = TimelineContext(float(base_step_seconds(backend)))
_timeline_context(backend::GlobalConstant) = _timeline_context(environment_source(backend))

function _environment_row_at_step(source, i::Int)
    isnothing(source) && return nothing
    if source isa TimeStepTable || DataFormat(source) == TableAlike()
        rows = Tables.rows(source)
        applicable(getindex, rows, i) && return rows[i]
        return first(Iterators.drop(rows, i - 1))
    end
    return source
end

@inline _environment_row_at_step(source::DataFrames.DataFrame, i::Int) =
    DataFrames.DataFrameRow(source, i, :)

function _available_environment_variables(source)
    row = _first_environment_row(source)
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
    source = environment_source(backend)
    isnothing(source) && return Set{Symbol}()
    return _available_environment_variables(source)
end

function validate_environment_inputs(model_specs::Dict{Symbol,Dict{Symbol,ModelSpec}}, backend::GlobalConstant)
    return invoke(
        validate_environment_inputs,
        Tuple{Dict{Symbol,Dict{Symbol,ModelSpec}},AbstractEnvironmentBackend},
        model_specs,
        backend,
    )
end

function validate_environment_inputs(model_specs::Dict{Symbol,Dict{Symbol,ModelSpec}}, backend::AbstractEnvironmentBackend)
    available = environment_variables(backend)
    isnothing(available) && return nothing

    missing_rows = _collect_missing_environment_rows(model_specs, var -> var in available)
    return _error_missing_environment_inputs(
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
    validate_environment_inputs(model::CompositeModel)
    validate_environment_inputs(compiled::CompiledCompositeModel)
    validate_environment_inputs(compiled::CompiledCompositeModel, environment_or_backend)

Validate declared composite-model/object `environment_inputs_`.

The one-argument methods validate each application against its actual compiled
environment backend, including application-level `Environment(...)` overrides.
The two-argument method validates every compiled application against an
explicit replacement environment backend. Diagnostics report model
application ids, so several applications for the same process can be diagnosed
independently.
"""
function validate_environment_inputs(compiled::CompiledCompositeModel, environment_or_backend)
    backend = environment_backend(environment_or_backend)
    return validate_environment_inputs(_model_model_specs_by_application(compiled), backend)
end

function validate_environment_inputs(compiled::CompiledCompositeModel)
    refresh_environment_bindings!(compiled.model, compiled)
    return nothing
end

function validate_environment_inputs(model::CompositeModel)
    compiled = refresh_bindings!(model)
    return validate_environment_inputs(compiled)
end

function validate_environment_inputs(model::CompositeModel, environment_or_backend)
    compiled = refresh_bindings!(model)
    return validate_environment_inputs(compiled, environment_or_backend)
end

"""
    sample(backend, handle, variable, time)
    sample(backend, handle, state, variable, time)

Sample one environmental variable through an opaque compiled backend `handle`.
The four-argument method reads the backend's committed state. The five-argument
method reads a transient backend-specific `state` supplied through
`run_call!(context, name; environment=state)`.
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
    source = _environment_row_at_step(environment_source(backend), Int(round(time)))
    isnothing(source) && return nothing
    hasproperty(source, variable) || error(
        "GlobalConstant source does not provide variable `$(variable)`."
    )
    return getproperty(source, variable)
end

function sample(backend::GlobalConstant, handle, state, variable::Symbol, time)
    source = _environment_row_at_step(state, Int(round(time)))
    isnothing(source) && return nothing
    hasproperty(source, variable) || error(
        "Transient GlobalConstant state does not provide variable `$(variable)`."
    )
    return getproperty(source, variable)
end

"""
    commit_environment!(backend, handle, state, time)

Commit an accepted environment `state` through an opaque compiled backend
`handle`. Model kernels call `commit_environment!(context, state)`; backend
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
    update_index!(backend, changed_entities, removed_object_ids)

Update the backend spatial/entity index after topology or geometry changes.
`changed_entities` contains only new or changed objects and
`removed_object_ids` contains stable [`ObjectId`](@ref)s that no longer exist.
The initial compilation supplies every entity and an empty removal vector.
"""
update_index!(
    ::AbstractEnvironmentBackend,
    changed_entities,
    removed_object_ids,
) = nothing
update_index!(::GlobalConstant, changed_entities, removed_object_ids) =
    nothing

"""
    PreparedEnvironmentInputs(targets, sources; raw_global_source=false)
    PreparedEnvironmentInputs(model_spec::ModelSpec)

Prepared model-facing environment names and their backend source names. Create
this immutable schema once; its type carries the complete remapping. `keys`
returns target names and `values` returns the aligned source names. The schema
contains no sampled values, so the same schema can sample changing mutable
backend or trial state without retaining a stale snapshot.

Backends may specialize `sample_environment(backend, handle, [state], time,
prepared::PreparedEnvironmentInputs)` to validate and sample a complete row
once. The default calls `sample` separately for every source through the same
compiled handle and constructs a concretely typed `NamedTuple`. The optional
`raw_global_source` flag preserves a `GlobalConstant` row without projecting it;
it is selected automatically for a ModelSpec without source remapping.
"""
struct PreparedEnvironmentInputs{Targets,Sources,RawGlobalSource} end

function PreparedEnvironmentInputs(targets::Tuple, sources::Tuple; raw_global_source::Bool=false)
    length(targets) == length(sources) || throw(ArgumentError(
        "Prepared environment target and source names must have the same length."))
    all(name -> name isa Symbol, targets) && all(name -> name isa Symbol, sources) ||
        throw(ArgumentError("Prepared environment target and source names must be Symbols."))
    allunique(targets) || throw(ArgumentError("Prepared environment target names must be unique."))
    return PreparedEnvironmentInputs{targets,sources,raw_global_source}()
end

Base.keys(::PreparedEnvironmentInputs{Targets}) where {Targets} = Targets
Base.values(::PreparedEnvironmentInputs{Targets,Sources}) where {Targets,Sources} = Sources

"""
    sample_environment(backend, handle, time, prepared::PreparedEnvironmentInputs)
    sample_environment(backend, handle, state, time, prepared::PreparedEnvironmentInputs)

Sample a model-facing row through a compiled backend `handle` using a prepared
schema. The `state` overload samples a transient environment without changing
the handle or committing that state. A backend batch specialization must sample
the current values on every invocation; schema reuse does not permit caching
mutable values by object identity.

A ModelSpec or iterable of variable names is also accepted for direct calls;
these convenience forms prepare a schema before invoking the same batch hook.
Simulation execution reuses its compiled schema.
"""
@generated function sample_environment(
    backend::AbstractEnvironmentBackend, handle, time,
    ::PreparedEnvironmentInputs{Targets,Sources,Raw},
) where {Targets,Sources,Raw}
    sampled = Expr(:tuple, (:(sample(backend, handle, $(QuoteNode(source)), time))
        for source in Sources)...)
    return :(NamedTuple{$(QuoteNode(Targets))}($sampled))
end

@generated function sample_environment(
    backend::AbstractEnvironmentBackend, handle, state, time,
    ::PreparedEnvironmentInputs{Targets,Sources,Raw},
) where {Targets,Sources,Raw}
    sampled = Expr(:tuple, (:(sample(backend, handle, state, $(QuoteNode(source)), time))
        for source in Sources)...)
    return :(NamedTuple{$(QuoteNode(Targets))}($sampled))
end

function sample_environment(backend::AbstractEnvironmentBackend, handle, time, variables)
    names = Tuple(Symbol(variable) for variable in variables)
    return sample_environment(backend, handle, time, PreparedEnvironmentInputs(names, names))
end

function sample_environment(backend::AbstractEnvironmentBackend, handle, state, time, variables)
    names = Tuple(Symbol(variable) for variable in variables)
    return sample_environment(backend, handle, state, time, PreparedEnvironmentInputs(names, names))
end

function sample_environment(backend::GlobalConstant, handle, time, variables)
    return _environment_row_at_step(environment_source(backend), Int(round(time)))
end

function sample_environment(backend::GlobalConstant, handle, state, time, variables)
    return _environment_row_at_step(state, Int(round(time)))
end

function _environment_sampling_rules(model_spec::ModelSpec)
    bindings = environment_bindings(model_spec)
    bindings = bindings isa NamedTuple ? bindings : NamedTuple()
    environment_sources = _environment_source_overrides(model_spec)
    rules = Pair{Symbol,Symbol}[]
    for target in keys(environment_inputs_(model_spec))
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

function PreparedEnvironmentInputs(model_spec::ModelSpec)
    rules = _environment_sampling_rules(model_spec)
    targets = Tuple(first(rule) for rule in rules)
    sources = Tuple(last(rule) for rule in rules)
    bindings = environment_bindings(model_spec)
    raw_global_source = !(bindings isa NamedTuple && !isempty(keys(bindings))) &&
                        isempty(keys(_environment_source_overrides(model_spec)))
    return PreparedEnvironmentInputs(targets, sources; raw_global_source)
end

sample_environment(backend::AbstractEnvironmentBackend, handle, time, model_spec::ModelSpec) =
    sample_environment(backend, handle, time, PreparedEnvironmentInputs(model_spec))
sample_environment(backend::AbstractEnvironmentBackend, handle, state, time, model_spec::ModelSpec) =
    sample_environment(backend, handle, state, time, PreparedEnvironmentInputs(model_spec))
sample_environment(backend::GlobalConstant, handle, time, model_spec::ModelSpec) =
    sample_environment(backend, handle, time, PreparedEnvironmentInputs(model_spec))
sample_environment(backend::GlobalConstant, handle, state, time, model_spec::ModelSpec) =
    sample_environment(backend, handle, state, time, PreparedEnvironmentInputs(model_spec))

@generated function _sample_prepared_global_environment_row(
    row::Row, ::PreparedEnvironmentInputs{Targets,Sources,Raw},
) where {Row,Targets,Sources,Raw}
    Raw && return :(row)
    checks = Expr[]
    sampled = Expr[]
    for (target, source) in zip(Targets, Sources)
        push!(checks, quote
            isnothing(row) && error(
                "GlobalConstant source is `nothing`, but the model requires source variable `",
                $(QuoteNode(target)), "`.")
            hasproperty(row, $(QuoteNode(source))) || error(
                "GlobalConstant source does not provide source variable `",
                $(QuoteNode(source)), "` for model-facing variable `", $(QuoteNode(target)), "`.")
        end)
        push!(sampled, :(getproperty(row, $(QuoteNode(source)))))
    end
    names = Targets
    if Row <: NamedTuple
        if :duration in Row.parameters[1] && !(:duration in Targets)
            names = (Targets..., :duration)
            push!(sampled, :(getproperty(row, :duration)))
        end
        return quote
            $(checks...)
            NamedTuple{$(QuoteNode(names))}($(Expr(:tuple, sampled...)))
        end
    end
    return quote
        $(checks...)
        sampled = NamedTuple{$(QuoteNode(Targets))}($(Expr(:tuple, sampled...)))
        if $(!(:duration in Targets)) && !isnothing(row) && hasproperty(row, :duration)
            return merge(sampled, (duration=getproperty(row, :duration),))
        end
        return sampled
    end
end

function sample_environment(
    backend::GlobalConstant, handle, time, prepared::PreparedEnvironmentInputs,
)
    row = _environment_row_at_step(environment_source(backend), Int(round(time)))
    return _sample_prepared_global_environment_row(row, prepared)
end

function sample_environment(
    backend::GlobalConstant, handle, state, time, prepared::PreparedEnvironmentInputs,
)
    row = _environment_row_at_step(state, Int(round(time)))
    return _sample_prepared_global_environment_row(row, prepared)
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

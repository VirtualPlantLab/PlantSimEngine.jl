"""
    AbstractEnvironmentBackend

Backend protocol for meteorology and mutable microclimate providers.

PlantSimEngine defines the protocol, not the spatial indexing strategy. External
packages can subtype this and implement `sample`, `scatter!`, `update_index!`,
`get_nsteps`, and `base_step_seconds`.
"""
abstract type AbstractEnvironmentBackend end

"""
    EnvironmentSupport(domain, scale, process, status)

Minimal support descriptor passed to environment backends when a model samples
or scatters environmental variables.
"""
struct EnvironmentSupport{S}
    domain::Symbol
    scale::Symbol
    process::Symbol
    status::S
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
    get_nsteps(meteo) == 1 && return meteo
    return first(Iterators.drop(Tables.rows(meteo), i - 1))
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

    missing_rows = NamedTuple[]
    for (scale, specs_at_scale) in model_specs
        for (process, spec) in specs_at_scale
            required = _raw_meteo_requirements_for_spec(spec)
            missing = Symbol[var for var in required if !(var in available)]
            isempty(missing) && continue
            push!(missing_rows, (scale=scale, process=process, missing=Tuple(missing)))
        end
    end

    isempty(missing_rows) && return nothing

    details = join(
        [
            string(row.scale, "/", row.process, " missing ", row.missing)
            for row in missing_rows
        ],
        "; "
    )
    error(
        "Environment backend `$(typeof(backend))` is missing variables required by model `meteo_inputs_`: ",
        details,
        ". Add the variables to the backend, declare a `MeteoBindings(source=...)` remapping, ",
        "or remove the unused meteo input from the model trait."
    )
end

"""
    sample(backend, variable, support, time)

Sample one environmental variable for a model support at a runtime time.
"""
function sample(backend::AbstractEnvironmentBackend, variable::Symbol, support::EnvironmentSupport, time)
    error(
        "Environment backend `$(typeof(backend))` must implement ",
        "`PlantSimEngine.sample(backend, variable, support, time)`."
    )
end

function sample(backend::GlobalConstant, variable::Symbol, support::EnvironmentSupport, time)
    meteo = _meteo_row_at_step(environment_meteo(backend), Int(round(time)))
    isnothing(meteo) && return nothing
    hasproperty(meteo, variable) || error(
        "GlobalConstant meteo does not provide variable `$(variable)` for `$(support.domain)/$(support.scale)/$(support.process)`."
    )
    return getproperty(meteo, variable)
end

"""
    scatter!(backend, variable, support, value, time)

Scatter one model-computed environmental value back to a mutable backend.
"""
function scatter!(backend::AbstractEnvironmentBackend, variable::Symbol, support::EnvironmentSupport, value, time)
    error(
        "Environment backend `$(typeof(backend))` does not implement ",
        "`PlantSimEngine.scatter!(backend, variable, support, value, time)`."
    )
end

scatter!(backend::GlobalConstant, variable::Symbol, support::EnvironmentSupport, value, time) = error(
    "GlobalConstant is immutable and cannot receive environment output `$(variable)` from ",
    "`$(support.domain)/$(support.scale)/$(support.process)`."
)

"""
    update_index!(backend, entities)

Update the backend spatial/entity index after topology or geometry changes.
"""
update_index!(::AbstractEnvironmentBackend, entities) = nothing
update_index!(::GlobalConstant, entities) = nothing

"""
    sample_environment(backend, support, time, variables)

Sample a meteo-like row for a model. `GlobalConstant` returns the original meteo
row; other backends return a `NamedTuple` assembled from `sample` calls.
"""
function sample_environment(backend::AbstractEnvironmentBackend, support::EnvironmentSupport, time, variables)
    pairs = Pair{Symbol,Any}[]
    for variable in variables
        push!(pairs, variable => sample(backend, variable, support, time))
    end
    return (; pairs...)
end

function sample_environment(backend::GlobalConstant, support::EnvironmentSupport, time, variables)
    return _meteo_row_at_step(environment_meteo(backend), Int(round(time)))
end

function _environment_sampling_rules(model_spec::ModelSpec)
    bindings = meteo_bindings(model_spec)
    bindings = bindings isa NamedTuple ? bindings : NamedTuple()
    rules = Pair{Symbol,Symbol}[]
    for target in keys(meteo_inputs_(model_spec))
        source = target
        if haskey(bindings, target)
            rule = bindings[target]
            rule isa NamedTuple && haskey(rule, :source) && (source = Symbol(rule.source))
        end
        push!(rules, target => source)
    end
    return rules
end

function sample_environment(
    backend::AbstractEnvironmentBackend,
    support::EnvironmentSupport,
    time,
    model_spec::ModelSpec
)
    pairs = Pair{Symbol,Any}[]
    for (target, source) in _environment_sampling_rules(model_spec)
        push!(pairs, target => sample(backend, source, support, time))
    end
    return (; pairs...)
end

function sample_environment(
    backend::GlobalConstant,
    support::EnvironmentSupport,
    time,
    model_spec::ModelSpec
)
    row = _meteo_row_at_step(environment_meteo(backend), Int(round(time)))
    bindings = meteo_bindings(model_spec)
    has_bindings = bindings isa NamedTuple && !isempty(keys(bindings))
    !has_bindings && return row

    pairs = Pair{Symbol,Any}[]
    for (target, source) in _environment_sampling_rules(model_spec)
        isnothing(row) && error(
            "GlobalConstant meteo is `nothing`, but `$(support.domain)/$(support.scale)/$(support.process)` ",
            "requires meteo variable `$(target)`."
        )
        hasproperty(row, source) || error(
            "GlobalConstant meteo does not provide source variable `$(source)` for model-facing variable ",
            "`$(target)` in `$(support.domain)/$(support.scale)/$(support.process)`."
        )
        push!(pairs, target => getproperty(row, source))
    end
    if !isnothing(row) && hasproperty(row, :duration)
        push!(pairs, :duration => getproperty(row, :duration))
    end
    return (; pairs...)
end

function _environment_output_value(status, variable::Symbol, support::EnvironmentSupport)
    hasproperty(status, variable) && return getproperty(status, variable)
    error(
        "Model `$(support.domain)/$(support.scale)/$(support.process)` declares environment output ",
        "`$(variable)` in `meteo_outputs_`, but its status does not contain `$(variable)`. ",
        "Expose the computed value as a same-named `outputs_` variable or initialize it in the status."
    )
end

"""
    scatter_environment_outputs!(backend, support, time, model_spec, status)

Scatter values declared by `meteo_outputs_(model)` from model status into a
mutable environment backend.
"""
function scatter_environment_outputs!(
    backend::AbstractEnvironmentBackend,
    support::EnvironmentSupport,
    time,
    model_spec::ModelSpec,
    status
)
    for variable in keys(meteo_outputs_(model_spec))
        value = _environment_output_value(status, variable, support)
        scatter!(backend, variable, support, value, time)
    end
    return nothing
end

"""
    explain_environment(simulation)

Return a compact description of the environment backend used by a domain
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

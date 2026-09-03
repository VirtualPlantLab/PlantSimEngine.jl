# Model-facing environment sampling backed by PlantMeteo's weather adapters.
function _has_environment_sampler_api()
    return isdefined(PlantMeteo, :prepare_weather_sampler) &&
           isdefined(PlantMeteo, :RollingWindow) &&
           isdefined(PlantMeteo, :sample_weather)
end

function _prepare_environment_sampler(environment)
    !_has_environment_sampler_api() && return nothing
    environment isa TimeStepTable{<:Atmosphere} || return nothing
    return PlantMeteo.prepare_weather_sampler(environment)
end

function _runtime_environment_window(window)
    return _normalize_environment_window(window)
end

function _environment_sampling_window(clock::ClockSpec, model_spec)
    window = _runtime_environment_window(environment_window(model_spec))
    if isnothing(window)
        return PlantMeteo.RollingWindow(float(clock.dt))
    end
    # Keep historical behavior when a plain RollingWindow marker is provided:
    # rolling width follows the model clock by default.
    if window isa PlantMeteo.RollingWindow && window.dt == 1.0
        return PlantMeteo.RollingWindow(float(clock.dt))
    end
    return window
end

_normalize_environment_reducer(reducer) = _normalize_policy_reducer(reducer)

function _normalize_environment_binding_rule(target::Symbol, rule)
    if rule isa NamedTuple
        src = haskey(rule, :source) ? Symbol(rule.source) : target
        reducer = haskey(rule, :reducer) ? _normalize_environment_reducer(rule.reducer) : PlantMeteo.MeanWeighted()
        return (source=src, reducer=reducer)
    elseif rule isa Function || rule isa PlantMeteo.AbstractTimeReducer || rule isa DataType
        return (source=target, reducer=_normalize_environment_reducer(rule))
    end

    error(
        "Unsupported environment binding value `$(rule)` for target `$(target)`. ",
        "Use a reducer type/instance, callable, or NamedTuple(source=..., reducer=...)."
    )
end

function _raw_environment_requirements_for_spec(model_spec)
    required = Set{Symbol}(keys(environment_inputs_(model_spec)))
    isempty(required) && return required

    raw_required = Set{Symbol}()
    bindings = environment_bindings(model_spec)
    bindings = bindings isa NamedTuple ? bindings : NamedTuple()
    for var in required
        if haskey(bindings, var)
            rule = bindings[var]
            if rule isa NamedTuple && haskey(rule, :source)
                push!(raw_required, Symbol(rule.source))
            else
                push!(raw_required, var)
            end
        else
            push!(raw_required, var)
        end
    end

    return raw_required
end

function _first_environment_row(environment)
    isnothing(environment) && return nothing
    is_table = DataFormat(environment) == TableAlike()
    if is_table
        rows = Tables.rows(environment)
        state = iterate(rows)
        isnothing(state) && return nothing
        return state[1]
    end
    return environment
end

_environment_has_field(row, var::Symbol) = hasproperty(row, var)
_environment_has_field(row::NamedTuple, var::Symbol) = haskey(row, var)

function _collect_missing_environment_rows(
    model_specs::Dict{Symbol,Dict{Symbol,ModelSpec}},
    has_environment_variable,
)
    missing_rows = NamedTuple[]
    for (scale, specs_at_scale) in model_specs
        for (process, spec) in specs_at_scale
            required = _raw_environment_requirements_for_spec(spec)
            missing = Symbol[
                var for var in required if !has_environment_variable(var)
            ]
            isempty(missing) && continue
            push!(missing_rows, (scale=scale, process=process, missing=Tuple(missing)))
        end
    end
    return missing_rows
end

function _format_missing_environment_rows(missing_rows)
    return join(
        [
            string(row.scale, "/", row.process, " missing ", row.missing)
            for row in missing_rows
        ],
        "; "
    )
end

function _error_missing_environment_inputs(missing_rows; subject::AbstractString, noun::AbstractString, target::AbstractString)
    isempty(missing_rows) && return nothing

    error(
        subject,
        " is missing ",
        noun,
        " required by model `environment_inputs_`: ",
        _format_missing_environment_rows(missing_rows),
        ". Add the ",
        noun,
        " to ",
        target,
        ", declare an `Environment(; sources=...)` remapping, ",
        "or remove the unused environment input from the model trait."
    )
end

"""
    validate_environment_inputs(model_specs, environment)

Validate declared `environment_inputs_` against the available environment fields.

The check is intentionally field-based and independent from units/backends. When
Environment source bindings remap a declared model input from another variable; the
source variable is checked on the raw environment object.
"""
function validate_environment_inputs(model_specs::Dict{Symbol,Dict{Symbol,ModelSpec}}, environment)
    row = _first_environment_row(environment)
    isnothing(row) && return nothing

    missing_rows = _collect_missing_environment_rows(model_specs, var -> _environment_has_field(row, var))
    return _error_missing_environment_inputs(
        missing_rows;
        subject="Environment",
        noun="fields",
        target="environment"
    )
end

function validate_environment_inputs(model_specs::AbstractDict{Symbol,<:AbstractDict}, environment)
    normalized_specs = Dict{Symbol,Dict{Symbol,ModelSpec}}()
    for (scale, specs_at_scale) in pairs(model_specs)
        normalized_specs[scale] = Dict{Symbol,ModelSpec}(
            Symbol(process) => as_model_spec(spec) for (process, spec) in pairs(specs_at_scale)
        )
    end
    return validate_environment_inputs(normalized_specs, environment)
end

function validate_environment_inputs(models::NamedTuple, environment)
    specs = Dict(
        :Default => Dict{Symbol,ModelSpec}(
            process(model) => as_model_spec(model) for model in values(models)
        )
    )
    return validate_environment_inputs(specs, environment)
end

function _environment_transforms_for_model(model_spec)
    bindings = environment_bindings(model_spec)
    isnothing(bindings) && return nothing
    bindings isa NamedTuple || return nothing
    isempty(keys(bindings)) && return nothing

    pairs_out = Pair{Symbol,Any}[]
    for (target, rule) in pairs(bindings)
        push!(pairs_out, target => _normalize_environment_binding_rule(target, rule))
    end
    return (; pairs_out...)
end

function _sample_environment_for_model(
    environment_sampler,
    environment,
    i::Int,
    model_clock::ClockSpec,
    model_spec
)
    transforms = _environment_transforms_for_model(model_spec)
    window = _runtime_environment_window(environment_window(model_spec))

    isnothing(environment_sampler) && begin
        if !isnothing(transforms) || !isnothing(window)
            @warn string(
                "Environment sampling rules were provided but the weather sampler API is unavailable or the source is not TimeStepTable{Atmosphere}. ",
                "Falling back to raw environment rows."
            ) maxlog = 1
        end
        return environment
    end

    # Fast-path: default 1:1 weather step with no custom transforms.
    if float(model_clock.dt) <= 1.0 &&
       isnothing(transforms) &&
       (isnothing(window) || window isa PlantMeteo.RollingWindow)
        return environment
    end

    window = _environment_sampling_window(model_clock, model_spec)
    return PlantMeteo.sample_weather(environment_sampler, i; window=window, transforms=transforms)
end

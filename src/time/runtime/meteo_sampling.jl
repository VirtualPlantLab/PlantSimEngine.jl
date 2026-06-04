function _has_meteo_sampler_api()
    return isdefined(PlantMeteo, :prepare_weather_sampler) &&
           isdefined(PlantMeteo, :RollingWindow) &&
           isdefined(PlantMeteo, :sample_weather)
end

function _prepare_meteo_sampler(meteo)
    !_has_meteo_sampler_api() && return nothing
    meteo isa TimeStepTable{<:Atmosphere} || return nothing
    return PlantMeteo.prepare_weather_sampler(meteo)
end

function _runtime_meteo_window(window)
    return _normalize_meteo_window(window)
end

function _meteo_sampling_window(clock::ClockSpec, model_spec)
    window = _runtime_meteo_window(meteo_window(model_spec))
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

_normalize_meteo_reducer(reducer) = _normalize_time_reducer(reducer; context="meteo reducer")

function _normalize_meteo_binding_rule(target::Symbol, rule)
    if rule isa NamedTuple
        src = haskey(rule, :source) ? Symbol(rule.source) : target
        reducer = haskey(rule, :reducer) ? _normalize_meteo_reducer(rule.reducer) : PlantMeteo.MeanWeighted()
        return (source=src, reducer=reducer)
    elseif rule isa Function || rule isa PlantMeteo.AbstractTimeReducer || rule isa DataType
        return (source=target, reducer=_normalize_meteo_reducer(rule))
    end

    error(
        "Unsupported meteo binding value `$(rule)` for target `$(target)`. ",
        "Use a reducer type/instance, callable, or NamedTuple(source=..., reducer=...)."
    )
end

function _raw_meteo_requirements_for_spec(model_spec)
    required = Set{Symbol}(keys(meteo_inputs_(model_spec)))
    isempty(required) && return required

    raw_required = Set{Symbol}()
    bindings = meteo_bindings(model_spec)
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

function _first_meteo_row(meteo)
    isnothing(meteo) && return nothing
    is_table = try
        DataFormat(meteo) == TableAlike()
    catch
        false
    end
    if is_table
        rows = Tables.rows(meteo)
        state = iterate(rows)
        isnothing(state) && return nothing
        return state[1]
    end
    return meteo
end

_meteo_has_field(row, var::Symbol) = hasproperty(row, var)
_meteo_has_field(row::NamedTuple, var::Symbol) = haskey(row, var)

function _collect_missing_meteo_rows(model_specs::Dict{Symbol,Dict{Symbol,ModelSpec}}, has_meteo_variable)
    missing_rows = NamedTuple[]
    for (scale, specs_at_scale) in model_specs
        for (process, spec) in specs_at_scale
            required = _raw_meteo_requirements_for_spec(spec)
            missing = Symbol[var for var in required if !has_meteo_variable(var)]
            isempty(missing) && continue
            push!(missing_rows, (scale=scale, process=process, missing=Tuple(missing)))
        end
    end
    return missing_rows
end

function _format_missing_meteo_rows(missing_rows)
    return join(
        [
            string(row.scale, "/", row.process, " missing ", row.missing)
            for row in missing_rows
        ],
        "; "
    )
end

function _error_missing_meteo_inputs(missing_rows; subject::AbstractString, noun::AbstractString, target::AbstractString)
    isempty(missing_rows) && return nothing

    error(
        subject,
        " is missing ",
        noun,
        " required by model `meteo_inputs_`: ",
        _format_missing_meteo_rows(missing_rows),
        ". Add the ",
        noun,
        " to ",
        target,
        ", declare a `MeteoBindings(source=...)` remapping, ",
        "or remove the unused meteo input from the model trait."
    )
end

"""
    validate_meteo_inputs(model_specs, meteo)

Validate declared `meteo_inputs_` against the available meteorological fields.

The check is intentionally field-based and independent from units/backends. When
`MeteoBindings` remap a declared model input from another source variable, the
source variable is checked on the raw meteo object.
"""
function validate_meteo_inputs(model_specs::Dict{Symbol,Dict{Symbol,ModelSpec}}, meteo)
    row = _first_meteo_row(meteo)
    isnothing(row) && return nothing

    missing_rows = _collect_missing_meteo_rows(model_specs, var -> _meteo_has_field(row, var))
    return _error_missing_meteo_inputs(
        missing_rows;
        subject="Meteorology",
        noun="fields",
        target="meteo"
    )
end

function validate_meteo_inputs(model_specs::AbstractDict{Symbol,<:AbstractDict}, meteo)
    normalized_specs = Dict{Symbol,Dict{Symbol,ModelSpec}}()
    for (scale, specs_at_scale) in pairs(model_specs)
        normalized_specs[scale] = Dict{Symbol,ModelSpec}(
            Symbol(process) => as_model_spec(spec) for (process, spec) in pairs(specs_at_scale)
        )
    end
    return validate_meteo_inputs(normalized_specs, meteo)
end

function validate_meteo_inputs(models::NamedTuple, meteo)
    specs = Dict(
        :Default => Dict{Symbol,ModelSpec}(
            process(model) => as_model_spec(model) for model in values(models)
        )
    )
    return validate_meteo_inputs(specs, meteo)
end

function validate_meteo_inputs(mapping::ModelMapping, meteo)
    specs = Dict{Symbol,Dict{Symbol,ModelSpec}}(
        scale => parse_model_specs(declarations) for (scale, declarations) in pairs(mapping)
    )
    return validate_meteo_inputs(specs, meteo)
end

function validate_meteo_inputs(mapping::AbstractDict, meteo)
    specs = Dict{Symbol,Dict{Symbol,ModelSpec}}(
        Symbol(scale) => parse_model_specs(declarations) for (scale, declarations) in pairs(mapping)
    )
    return validate_meteo_inputs(specs, meteo)
end

function _meteo_transforms_for_model(model_spec)
    bindings = meteo_bindings(model_spec)
    isnothing(bindings) && return nothing
    bindings isa NamedTuple || return nothing
    isempty(keys(bindings)) && return nothing

    pairs_out = Pair{Symbol,Any}[]
    for (target, rule) in pairs(bindings)
        push!(pairs_out, target => _normalize_meteo_binding_rule(target, rule))
    end
    return (; pairs_out...)
end

function _sample_meteo_for_model(
    meteo_sampler,
    meteo,
    i::Int,
    model_clock::ClockSpec,
    model_spec
)
    transforms = _meteo_transforms_for_model(model_spec)
    window = _runtime_meteo_window(meteo_window(model_spec))

    isnothing(meteo_sampler) && begin
        if !isnothing(transforms) || !isnothing(window)
            @warn string(
                "MeteoBindings or MeteoWindow were provided but weather sampler API is unavailable or meteo is not TimeStepTable{Atmosphere}. ",
                "Falling back to raw meteo rows."
            ) maxlog = 1
        end
        return meteo
    end

    # Fast-path: default 1:1 weather step with no custom transforms.
    if float(model_clock.dt) <= 1.0 &&
       isnothing(transforms) &&
       (isnothing(window) || window isa PlantMeteo.RollingWindow)
        return meteo
    end

    window = _meteo_sampling_window(model_clock, model_spec)
    return PlantMeteo.sample_weather(meteo_sampler, i; window=window, transforms=transforms)
end

function _has_meteo_sampler_api()
    return isdefined(PlantMeteo, :prepare_weather_sampler) &&
           isdefined(PlantMeteo, :MeteoSamplingSpec) &&
           isdefined(PlantMeteo, :sample_weather)
end

function _prepare_meteo_sampler(meteo)
    !_has_meteo_sampler_api() && return nothing
    meteo isa TimeStepTable{<:Atmosphere} || return nothing
    return PlantMeteo.prepare_weather_sampler(meteo)
end

_meteo_sampling_spec(clock::ClockSpec) = PlantMeteo.MeteoSamplingSpec(float(clock.dt), float(clock.phase))

function _normalize_meteo_reducer(reducer)
    if reducer isa DataType
        reducer <: PlantMeteo.AbstractTimeReducer || error(
            "Unsupported meteo reducer type `$(reducer)`. ",
            "Use a PlantMeteo reducer type/instance or a callable."
        )
        return reducer()
    elseif reducer isa PlantMeteo.AbstractTimeReducer
        return reducer
    elseif reducer isa Function
        return reducer
    end

    error(
        "Unsupported meteo reducer value `$(reducer)` of type `$(typeof(reducer))`. ",
        "Use a PlantMeteo reducer type/instance or a callable."
    )
end

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

    isnothing(meteo_sampler) && begin
        if !isnothing(transforms)
            @warn string(
                "MeteoBindings were provided but weather sampler API is unavailable or meteo is not TimeStepTable{Atmosphere}. ",
                "Falling back to raw meteo rows."
            ) maxlog = 1
        end
        return meteo
    end

    # Fast-path: default 1:1 weather step with no custom transforms.
    if float(model_clock.dt) <= 1.0 && isnothing(transforms)
        return meteo
    end

    spec = _meteo_sampling_spec(model_clock)
    return PlantMeteo.sample_weather(meteo_sampler, i; spec=spec, transforms=transforms)
end

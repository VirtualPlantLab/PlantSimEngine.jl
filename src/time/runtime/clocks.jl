"""Internal timing context for one scene run."""
struct TimelineContext
    base_step_seconds::Float64
end

_time_from_step(i, ::TimelineContext) = float(i)

timestep_hint(model::AbstractModel) = timestep_hint(typeof(model))
timestep_hint(::Type{<:AbstractModel}) = nothing

meteo_hint(model::AbstractModel) = meteo_hint(typeof(model))
meteo_hint(::Type{<:AbstractModel}) = nothing

struct _ResolvedTimeStepHint
    fixed::Union{Nothing,Dates.FixedPeriod}
    range::Union{Nothing,Tuple{Dates.FixedPeriod,Dates.FixedPeriod}}
    preferred::Union{Nothing,Symbol,Dates.FixedPeriod}
end

_seconds_from_period(period::Dates.FixedPeriod) =
    float(Dates.value(Dates.Millisecond(period))) * 1.0e-3

function _normalize_required_timestep_hint(scale::Symbol, process::Symbol, required)
    if required isa Dates.FixedPeriod
        _seconds_from_period(required) > 0.0 ||
            error("Invalid timestep_hint for $(scale)/$(process): period must be positive.")
        return required, nothing
    elseif required isa Tuple && length(required) == 2
        lower, upper = required
        lower isa Dates.FixedPeriod && upper isa Dates.FixedPeriod || error(
            "Invalid timestep_hint for $(scale)/$(process): expected two fixed periods."
        )
        lower_seconds = _seconds_from_period(lower)
        upper_seconds = _seconds_from_period(upper)
        0.0 < lower_seconds <= upper_seconds || error(
            "Invalid timestep_hint range for $(scale)/$(process)."
        )
        return nothing, (lower, upper)
    end
    error(
        "Invalid timestep_hint for $(scale)/$(process): expected a fixed period or period range."
    )
end

function _normalize_timestep_hint(scale::Symbol, process::Symbol, hint)
    isnothing(hint) && return _ResolvedTimeStepHint(nothing, nothing, nothing)
    if hint isa Dates.FixedPeriod || hint isa Tuple
        fixed, range = _normalize_required_timestep_hint(scale, process, hint)
        return _ResolvedTimeStepHint(fixed, range, nothing)
    elseif hint isa NamedTuple
        haskey(hint, :required) || error(
            "Invalid timestep_hint for $(scale)/$(process): `required` is mandatory."
        )
        all(key -> key in (:required, :preferred), keys(hint)) || error(
            "Invalid timestep_hint fields for $(scale)/$(process)."
        )
        fixed, range =
            _normalize_required_timestep_hint(scale, process, hint.required)
        preferred = get(hint, :preferred, nothing)
        if preferred isa Symbol
            preferred in (:finest, :coarsest) || error(
                "Invalid timestep_hint preference for $(scale)/$(process)."
            )
        elseif !(isnothing(preferred) || preferred isa Dates.FixedPeriod)
            error("Invalid timestep_hint preference for $(scale)/$(process).")
        end
        return _ResolvedTimeStepHint(fixed, range, preferred)
    end
    error("Invalid timestep_hint for $(scale)/$(process).")
end

function _normalize_meteo_hint(scale::Symbol, process::Symbol, hint)
    isnothing(hint) && return (bindings=nothing, window=nothing)
    hint isa NamedTuple || error(
        "Invalid meteo_hint for $(scale)/$(process): expected a NamedTuple."
    )
    all(key -> key in (:bindings, :window), keys(hint)) || error(
        "Invalid meteo_hint fields for $(scale)/$(process)."
    )
    bindings =
        haskey(hint, :bindings) ? _normalize_meteo_bindings(hint.bindings) : nothing
    window = haskey(hint, :window) ? _normalize_meteo_window(hint.window) : nothing
    return (bindings=bindings, window=window)
end

function _period_to_seconds(period::Dates.Period)
    period isa Dates.FixedPeriod || error(
        "Unsupported non-fixed period `$(typeof(period))`. Use Second, Minute, Hour, or Day."
    )
    seconds = float(Dates.value(Dates.Second(period)))
    seconds > 0.0 || error("Expected a positive period, got `$(period)`.")
    return seconds
end

function _duration_to_seconds(duration)
    if duration isa Dates.CompoundPeriod
        periods = Dates.periods(duration)
        isempty(periods) && error("Empty CompoundPeriod is not a valid duration.")
        seconds = sum(_period_to_seconds(period) for period in periods)
        seconds > 0.0 || error("Expected a positive duration, got `$(duration)`.")
        return seconds
    elseif duration isa Dates.Period
        return _period_to_seconds(duration)
    elseif duration isa Real
        seconds = float(duration)
        seconds > 0.0 || error("Expected a positive duration, got `$(duration)`.")
        return seconds
    end
    return nothing
end

function _is_default_clock(clock::ClockSpec)
    isapprox(float(clock.dt), 1.0; atol=1.0e-9, rtol=0.0) &&
        isapprox(float(clock.phase), 0.0; atol=1.0e-9, rtol=0.0)
end

function _timestep_to_step_count(period::Dates.Period, timeline::TimelineContext)
    steps = _period_to_seconds(period) / timeline.base_step_seconds
    steps >= 1.0 || error(
        "Model timestep `$(period)` is shorter than the simulation base step."
    )
    return steps
end

function _first_table_row(table; context::String="meteorology")
    state = iterate(Tables.rows(table))
    isnothing(state) && error("Cannot infer a timestep from an empty $(context) table.")
    return state[1]
end

function _base_step_seconds_from_meteo_row(
    row;
    require_duration::Bool=false,
    context::String="meteorology",
)
    if hasproperty(row, :duration)
        duration = getproperty(row, :duration)
        seconds = _duration_to_seconds(duration)
        !isnothing(seconds) && return seconds
        require_duration && error("Invalid duration `$(duration)` in $(context).")
    elseif require_duration
        error("Missing required `duration` in $(context).")
    end
    return 1.0
end

function _validate_meteo_duration(meteo)
    isnothing(meteo) && return nothing
    if meteo isa Atmosphere
        _base_step_seconds_from_meteo_row(meteo; require_duration=true)
    elseif meteo isa TimeStepTable || DataFormat(meteo) == TableAlike()
        for (i, row) in enumerate(Tables.rows(meteo))
            _base_step_seconds_from_meteo_row(
                row;
                require_duration=true,
                context="meteorology row $(i)",
            )
        end
    elseif DataFormat(meteo) == SingletonAlike() && hasproperty(meteo, :duration)
        _base_step_seconds_from_meteo_row(meteo; require_duration=true)
    end
    return nothing
end

function _timeline_context(meteo)
    if meteo isa TimeStepTable || (!isnothing(meteo) && DataFormat(meteo) == TableAlike())
        row = _first_table_row(meteo)
        return TimelineContext(
            _base_step_seconds_from_meteo_row(row; require_duration=true)
        )
    elseif meteo isa Atmosphere ||
           (!isnothing(meteo) && DataFormat(meteo) == SingletonAlike() &&
            hasproperty(meteo, :duration))
        return TimelineContext(
            _base_step_seconds_from_meteo_row(meteo; require_duration=true)
        )
    end
    return TimelineContext(1.0)
end

function _clock_from_spec_timestep(timestep, timeline::TimelineContext)
    timestep isa ClockSpec && return timestep
    timestep isa Real && return ClockSpec(float(timestep), 0.0)
    timestep isa Dates.Period &&
        return ClockSpec(_timestep_to_step_count(timestep, timeline), 1.0)
    return nothing
end

function _model_clock(model_spec, model, timeline::TimelineContext)
    selected = isnothing(model_spec) ? nothing : timestep(model_spec)
    clock = _clock_from_spec_timestep(selected, timeline)
    !isnothing(clock) && return clock
    declared = timespec(model)
    return _is_default_clock(declared) ? ClockSpec(1.0, 0.0) : declared
end

function _runtime_clock_source_for_spec(spec::ModelSpec)
    !isnothing(timestep(spec)) && return :modelspec
    return _is_default_clock(timespec(model_(spec))) ? :meteo_base_step :
           :model_timespec
end

function _resolve_meteo_hint_clock(
    scale::Symbol,
    process::Symbol,
    model,
    timeline::TimelineContext,
)
    base_seconds = timeline.base_step_seconds
    hint = _normalize_timestep_hint(scale, process, timestep_hint(model))
    reason = nothing
    if !isnothing(hint.fixed)
        required = _seconds_from_period(hint.fixed)
        isapprox(required, base_seconds; atol=1.0e-9, rtol=0.0) ||
            (reason = "Meteorology base step is outside `timestep_hint.required=$(hint.fixed)` for `$(scale)/$(process)`.")
    elseif !isnothing(hint.range)
        lower, upper = _seconds_from_period.(hint.range)
        lower <= base_seconds <= upper ||
            (reason = "Meteorology base step is outside `timestep_hint.required=$(hint.range)` for `$(scale)/$(process)`.")
    end
    return ClockSpec(1.0, 0.0), reason
end

function _should_run_at_time(clock::ClockSpec, time::Float64)
    dt = float(clock.dt)
    phase = float(clock.phase)
    dt > 0.0 || error("Clock interval must be positive, got $(dt).")
    dt <= 1.0 && return true
    return isapprox(mod(time - phase, dt), 0.0; atol=1.0e-8, rtol=0.0)
end

function _window_start_for_clock(clock::ClockSpec, time::Float64)
    dt = float(clock.dt)
    return dt <= 1.0 ? time : time - dt + 1.0
end

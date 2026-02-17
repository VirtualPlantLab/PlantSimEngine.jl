"""
    TimelineContext(base_step_seconds)

Internal timing context for one simulation run.
`base_step_seconds` is the duration of one simulation step in seconds.
"""
struct TimelineContext
    base_step_seconds::Float64
end

"""
    _time_from_step(i, timeline)

Convert a 1-based integer timestep index to the floating runtime time.
"""
_time_from_step(i, ::TimelineContext) = float(i)

function _period_to_seconds(p::Dates.Period)
    p isa Dates.FixedPeriod || error(
        "Unsupported non-fixed period `$(typeof(p))` in timestep specification. ",
        "Use fixed periods such as `Second`, `Minute`, `Hour`, `Day`."
    )
    sec = float(Dates.value(Dates.Second(p)))
    sec > 0.0 || error("Invalid duration `$(p)`: expected a strictly positive period.")
    return sec
end

function _duration_to_seconds(d)
    if d isa Dates.CompoundPeriod
        periods = Dates.periods(d)
        isempty(periods) && error("Unsupported empty `Dates.CompoundPeriod` in meteo duration.")
        sec = sum(_period_to_seconds(p) for p in periods)
        sec > 0.0 || error("Invalid meteo duration `$(d)`: expected a strictly positive value.")
        return sec
    elseif d isa Dates.Period
        return _period_to_seconds(d)
    elseif d isa Real
        sec = float(d)
        sec > 0.0 || error("Invalid meteo duration `$(d)`: expected a strictly positive value in seconds.")
        return sec
    end
    return nothing
end

function _is_default_clock(clock::ClockSpec)
    return isapprox(float(clock.dt), 1.0; atol=1.0e-9, rtol=0.0) &&
           isapprox(float(clock.phase), 0.0; atol=1.0e-9, rtol=0.0)
end

function _timestep_to_step_count(ts::Dates.Period, timeline::TimelineContext)
    sec = _period_to_seconds(ts)
    step = sec / timeline.base_step_seconds
    step >= 1.0 || error(
        "Model timestep `$(ts)` is shorter than simulation base step ($(timeline.base_step_seconds) seconds). ",
        "This runtime does not support sub-step execution."
    )
    return step
end

function _first_table_row(table; context::String="meteo")
    rows = Tables.rows(table)
    state = iterate(rows)
    isnothing(state) && error(
        "Cannot infer simulation timestep from empty $(context) table. ",
        "Provide at least one row with a valid `duration`."
    )
    return state[1]
end

function _base_step_seconds_from_meteo_row(row; require_duration::Bool=false, context::String="meteo")
    if hasproperty(row, :duration)
        d = getproperty(row, :duration)
        sec = _duration_to_seconds(d)
        !isnothing(sec) && return sec
        require_duration && error(
            "Invalid `duration=$(d)` (type `$(typeof(d))`) in $(context). ",
            "Expected a positive Real (seconds), `Dates.Period`, or `Dates.CompoundPeriod`."
        )
    elseif require_duration
        error(
            "Missing required `duration` in $(context). ",
            "Meteorology must define a valid per-row duration."
        )
    end
    return 1.0
end

function _validate_meteo_duration(meteo)
    isnothing(meteo) && return nothing

    if meteo isa Atmosphere
        _base_step_seconds_from_meteo_row(meteo; require_duration=true, context="meteo")
        return nothing
    end

    if meteo isa TimeStepTable || DataFormat(meteo) == TableAlike()
        for (i, row) in enumerate(Tables.rows(meteo))
            _base_step_seconds_from_meteo_row(row; require_duration=true, context="meteo row $(i)")
        end
        return nothing
    end

    # Unknown formats are validated later by run-path specific checks.
    return nothing
end

function _timeline_context(meteo)
    if meteo isa TimeStepTable
        row = _first_table_row(meteo; context="meteo")
        return TimelineContext(_base_step_seconds_from_meteo_row(row; require_duration=true, context="meteo"))
    elseif meteo isa Atmosphere
        return TimelineContext(_base_step_seconds_from_meteo_row(meteo; require_duration=true, context="meteo"))
    elseif !isnothing(meteo) && DataFormat(meteo) == TableAlike()
        row = _first_table_row(meteo; context="meteo")
        return TimelineContext(_base_step_seconds_from_meteo_row(row; require_duration=true, context="meteo"))
    end
    return TimelineContext(1.0)
end

"""
    _clock_from_spec_timestep(ts, timeline)

Normalize a `ModelSpec.timestep` value to a `ClockSpec` when possible.
Returns `nothing` when no explicit clock can be derived.
"""
function _clock_from_spec_timestep(ts, timeline::TimelineContext)
    if ts isa ClockSpec
        return ts
    elseif ts isa Real
        return ClockSpec(float(ts), 0.0)
    elseif ts isa Dates.Period
        return ClockSpec(_timestep_to_step_count(ts, timeline), 1.0)
    else
        return nothing
    end
end

"""
    _model_clock(model_spec, model)

Return the effective execution clock for `model`, using user-provided
`ModelSpec` timestep override when available, otherwise `timespec(model)`.
"""
function _model_clock(model_spec, model, timeline::TimelineContext)
    spec_ts = isnothing(model_spec) ? nothing : PlantSimEngine.timestep(model_spec)
    c = _clock_from_spec_timestep(spec_ts, timeline)
    !isnothing(c) && return c

    model_clock = timespec(model)
    _is_default_clock(model_clock) && return ClockSpec(1.0, 0.0)
    return model_clock
end

"""
    _should_run_at_time(clock, t)

Decide whether a model with `clock` should execute at simulation time `t`.
"""
function _should_run_at_time(clock::ClockSpec, t::Float64)
    dt = float(clock.dt)
    phase = float(clock.phase)
    dt <= 0 && error("Invalid model clock: `dt` must be > 0, got $(dt).")
    dt <= 1.0 && return true
    # Robust phase alignment check for floating clocks.
    return isapprox(mod(t - phase, dt), 0.0; atol=1e-8, rtol=0.0)
end

"""
    _window_start_for_clock(clock, t)

Return the left bound of the consumer window `[t_start, t]` used by windowed
policies (`Integrate`, `Aggregate`) for a given consumer clock.
"""
function _window_start_for_clock(clock::ClockSpec, t::Float64)
    dt = float(clock.dt)
    dt <= 1.0 && return t
    return t - dt + 1.0
end

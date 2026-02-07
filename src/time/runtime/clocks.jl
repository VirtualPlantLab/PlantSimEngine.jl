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
    return float(Dates.value(Dates.Second(p)))
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

function _base_step_seconds_from_meteo_row(row)
    if hasproperty(row, :duration)
        d = getproperty(row, :duration)
        if d isa Dates.Period
            return _period_to_seconds(d)
        elseif d isa Real
            return float(d)
        end
    end
    return 1.0
end

function _timeline_context(meteo)
    if meteo isa TimeStepTable
        rows = Tables.rows(meteo)
        return TimelineContext(_base_step_seconds_from_meteo_row(rows[1]))
    elseif meteo isa Atmosphere
        return TimelineContext(_base_step_seconds_from_meteo_row(meteo))
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
    !isnothing(model_spec) || return timespec(model)
    c = _clock_from_spec_timestep(PlantSimEngine.timestep(model_spec), timeline)
    return isnothing(c) ? timespec(model) : c
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

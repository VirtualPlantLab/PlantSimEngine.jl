"""
    _default_scope(sim)

Internal helper returning the default multi-rate scope identifier used by the
current runtime.
"""
# Global default scope placeholder for first multi-rate slice.
_default_scope(::GraphSimulation) = ScopeId(:global, 1)

"""
    _time_from_step(i)

Convert a 1-based integer timestep index to the floating runtime time.
"""
_time_from_step(i) = float(i)

"""
    _clock_from_spec_timestep(ts)

Normalize a `ModelSpec.timestep` value to a `ClockSpec` when possible.
Returns `nothing` when no explicit clock can be derived.
"""
function _clock_from_spec_timestep(ts)
    if ts isa ClockSpec
        return ts
    elseif ts isa Real
        return ClockSpec(float(ts), 0.0)
    else
        return nothing
    end
end

"""
    _model_clock(model_spec, model)

Return the effective execution clock for `model`, using user-provided
`ModelSpec` timestep override when available, otherwise `timespec(model)`.
"""
function _model_clock(model_spec, model)
    !isnothing(model_spec) || return timespec(model)
    c = _clock_from_spec_timestep(PlantSimEngine.timestep(model_spec))
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

"""
    ClockSpec(dt, phase=0)

Execution interval and phase, expressed in simulation steps.
"""
struct ClockSpec{T<:Real}
    dt::T
    phase::T
end

ClockSpec(dt::T) where {T<:Real} = ClockSpec{T}(dt, zero(T))

abstract type SchedulePolicy end

"""Use the latest available producer value."""
struct HoldLast <: SchedulePolicy end

function _as_schedule_policy(policy; context::AbstractString="schedule policy")
    if policy isa DataType
        policy <: SchedulePolicy || error(
            "Unsupported $(context) type `$(policy)`. Expected a SchedulePolicy type or instance."
        )
        return try
            policy()
        catch
            error("Schedule policy type `$(policy)` requires constructor arguments.")
        end
    elseif policy isa SchedulePolicy
        return policy
    end
    error("Unsupported $(context) value `$(policy)` of type `$(typeof(policy))`.")
end

const _INTERPOLATE_MODES = (:linear, :hold)

"""
    Interpolate(; mode=:linear, extrapolation=:linear)

Interpolate a slower producer stream. Both `mode` and `extrapolation` accept
`:linear` or `:hold`.
"""
struct Interpolate{M<:Symbol,E<:Symbol} <: SchedulePolicy
    mode::M
    extrapolation::E
end

Interpolate(mode::Symbol) = Interpolate(mode, :linear)
Interpolate(; mode::Symbol=:linear, extrapolation::Symbol=:linear) =
    Interpolate(mode, extrapolation)

function _normalize_policy_reducer(reducer)
    if reducer isa DataType
        reducer <: PlantMeteo.AbstractTimeReducer || error(
            "Unsupported reducer type `$(reducer)`."
        )
        return reducer()
    elseif reducer isa PlantMeteo.AbstractTimeReducer || reducer isa Function
        return reducer
    end
    error("Unsupported reducer value `$(reducer)` of type `$(typeof(reducer))`.")
end

"""Reduce a producer window, using a sum by default."""
struct Integrate{R} <: SchedulePolicy
    reducer::R
    function Integrate(reducer)
        normalized = _normalize_policy_reducer(reducer)
        return new{typeof(normalized)}(normalized)
    end
end

Integrate() = Integrate(PlantMeteo.SumReducer())

"""Reduce a producer window, using a mean by default."""
struct Aggregate{R} <: SchedulePolicy
    reducer::R
    function Aggregate(reducer)
        normalized = _normalize_policy_reducer(reducer)
        return new{typeof(normalized)}(normalized)
    end
end

Aggregate() = Aggregate(PlantMeteo.MeanReducer())

function _validate_policy_instance(
    scale::Symbol,
    process::Symbol,
    input::Symbol,
    policy::SchedulePolicy,
)
    if policy isa Interpolate
        policy.mode in _INTERPOLATE_MODES || error(
            "Invalid interpolation mode `$(policy.mode)` for $(scale)/$(process).$(input)."
        )
        policy.extrapolation in _INTERPOLATE_MODES || error(
            "Invalid extrapolation mode `$(policy.extrapolation)` for $(scale)/$(process).$(input)."
        )
    elseif policy isa Union{Integrate,Aggregate}
        reducer = policy.reducer
        values = [1.0, 2.0]
        durations = [1.0, 1.0]
        applicable(reducer, values) || applicable(reducer, values, durations) ||
            error(
                "Reducer for $(scale)/$(process).$(input) must accept values or values and durations."
            )
    end
    return nothing
end

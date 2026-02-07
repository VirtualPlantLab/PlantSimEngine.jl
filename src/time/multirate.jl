"""
    ScopeId(kind, id)

Identifier for a simulation scope (e.g. global scene or plant).
"""
struct ScopeId
    kind::Symbol
    id::Int
end

"""
    ClockSpec(dt, phase)

Clock definition for a model/process.

# Details

`dt` is the execution interval and `phase` is the offset of the execution grid.
In the current runtime, simulation steps are indexed as `t = 1, 2, 3, ...` (1-based).
A model runs when `t` is aligned with its clock.

# Examples

With `dt=24`:
- `ClockSpec(24.0, 1.0)` runs at `t = 1, 25, 49, ...`
- `ClockSpec(24.0, 0.0)` runs at `t = 24, 48, 72, ...`
"""
struct ClockSpec{T<:Real}
    dt::T
    phase::T
end

ClockSpec(dt::T) where {T<:Real} = ClockSpec{T}(dt, zero(T))

"""
    ModelKey(scope, scale, process)

Unique key for one model process in one scope and scale.
"""
struct ModelKey
    scope::ScopeId
    scale::String
    process::Symbol
end

"""
    OutputKey(scope, scale, node_id, process, var)

Unique key for one producer output stream.
"""
struct OutputKey
    scope::ScopeId
    scale::String
    node_id::Int
    process::Symbol
    var::Symbol
end

abstract type SchedulePolicy end

"""
    HoldLast()

Use the latest available producer value.
"""
struct HoldLast <: SchedulePolicy end

const _INTERPOLATE_MODES = (:linear, :hold)
const _WINDOW_REDUCER_SYMBOLS = (:sum, :mean, :max, :min, :first, :last)

"""
    Interpolate()
    Interpolate(mode)
    Interpolate(mode, extrapolation)
    Interpolate(; mode=:linear, extrapolation=:linear)

Interpolation policy for fast consumers reading slower producer streams.

Supported modes:
- `:linear`: linear interpolation between bracket points for real values
- `:hold`: left-hold (previous sample)

Supported extrapolation modes when no future sample exists:
- `:linear`: linear extrapolation from last two samples when possible
- `:hold`: keep the latest sample
"""
struct Interpolate{M<:Symbol,E<:Symbol} <: SchedulePolicy
    mode::M
    extrapolation::E
end

Interpolate(mode::Symbol) = Interpolate(mode, :linear)
Interpolate(; mode::Symbol=:linear, extrapolation::Symbol=:linear) = Interpolate(mode, extrapolation)

"""
    Integrate()
    Integrate(reducer)

Windowed policy for consumers running at coarser clocks.
Values in the consumer window are reduced with `reducer`.

Supported reducer symbols: `:sum`, `:mean`, `:max`, `:min`, `:first`, `:last`.
You can also provide a callable taking the collected window values.
"""
struct Integrate{R} <: SchedulePolicy
    reducer::R
end

Integrate() = Integrate(:sum)

"""
    Aggregate()
    Aggregate(reducer)

Windowed aggregation policy for consumers running at coarser clocks.
Values in the consumer window are reduced with `reducer`.

Supported reducer symbols: `:sum`, `:mean`, `:max`, `:min`, `:first`, `:last`.
You can also provide a callable taking the collected window values.
"""
struct Aggregate{R} <: SchedulePolicy
    reducer::R
end

Aggregate() = Aggregate(:mean)

abstract type OutputCache end

mutable struct HoldLastCache{T} <: OutputCache
    t::Float64
    v::T
end

mutable struct InterpolateCache{T} <: OutputCache
    t_prev::Float64
    v_prev::T
    t_curr::Float64
    v_curr::T
end

mutable struct IntegrateCache{T<:Real} <: OutputCache
    t_prev::Float64
    v_prev::T
    acc::T
    window_start::Float64
end

mutable struct AggregateCache{T<:Real} <: OutputCache
    acc::T
    n::Int
    window_start::Float64
end

"""
    TemporalState(caches, last_run, samples, runtime_samples, runtime_window_horizon)
    TemporalState()

Temporal storage for multi-rate simulations.
`caches` stores producer hold-last outputs.
`last_run` stores last execution time per model key.
`samples` stores full raw `(time, value)` producer samples (kept for export).
`runtime_samples` stores bounded producer samples used during runtime input
resolution.
`runtime_window_horizon` controls how many timesteps are retained in
`runtime_samples`.
"""
mutable struct TemporalState{
    C<:AbstractDict{OutputKey,OutputCache},
    L<:AbstractDict{ModelKey,Float64},
    S<:AbstractDict{OutputKey,Vector{Tuple{Float64,Any}}},
    RS<:AbstractDict{OutputKey,Vector{Tuple{Float64,Any}}},
    H<:Real
}
    caches::C
    last_run::L
    samples::S
    runtime_samples::RS
    runtime_window_horizon::H
end

TemporalState() = TemporalState(
    Dict{OutputKey,OutputCache}(),
    Dict{ModelKey,Float64}(),
    Dict{OutputKey,Vector{Tuple{Float64,Any}}}(),
    Dict{OutputKey,Vector{Tuple{Float64,Any}}}(),
    1.0
)

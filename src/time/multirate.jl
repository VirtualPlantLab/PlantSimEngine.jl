"""
    ScopeId(kind, id)

Identifier for a simulation scope (e.g. global scene, species group, plant).
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
struct HoldLast <: SchedulePolicy end
struct Interpolate <: SchedulePolicy end
struct Integrate <: SchedulePolicy end
struct Aggregate <: SchedulePolicy end

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
    TemporalState(caches, last_run)
    TemporalState()

Temporal storage for multi-rate simulations.
`caches` stores producer output streams.
`last_run` stores last execution time per model key.
"""
mutable struct TemporalState{C<:AbstractDict{OutputKey,OutputCache},L<:AbstractDict{ModelKey,Float64}}
    caches::C
    last_run::L
end

TemporalState() = TemporalState(Dict{OutputKey,OutputCache}(), Dict{ModelKey,Float64}())

# Multi-rate And Scoped Simulation Draft

This document is a concrete draft for adding:
- multiple timesteps in one simulation,
- per-output scheduling policies,
- scoped model instances (multi-plant/multi-species),
- multiscale hard-dependencies that stay manual.

It is implementation-facing and intended for maintainers.

## 1. Design principles

1. Keep `Status` as the canonical instantaneous state for each object.
2. Do not copy full `Status` per clock or per timestep.
3. Store only the minimal temporal memory required by policies (`HoldLast`, `Interpolate`, `Integrate`, `Aggregate`).
4. Schedule and execute only soft-dependency nodes.
5. Keep hard-dependencies manual (called by parent model code), including multiscale hard-dependencies.

## 2. What "now" means

`now` is the current event time on one global timeline.

Example:
- if current event is `t = 12:30`, all `Status` values represent committed state at `12:30`;
- daily variables remain unchanged between daily events (piecewise constant);
- 30-minute variables update every 30-minute event.

So `Status` is not "hourly" or "daily". It is "current committed state at time t".

## 3. Core identifiers and clocks

```julia
struct ScopeId
    kind::Symbol   # :global, :species, :plant, :custom
    id::Int        # can be generalized later if needed
end

struct ClockSpec{T<:Real}
    dt::T          # base time unit chosen by simulation (e.g. seconds)
    phase::T
end

struct ModelKey
    scope::ScopeId
    scale::String
    process::Symbol
end

struct OutputKey
    scope::ScopeId
    scale::String
    node_id::Int
    process::Symbol
    var::Symbol
end
```

## 4. Policies: per-output, not per-model

Policy is attached to each produced output variable.

```julia
abstract type SchedulePolicy end
struct HoldLast <: SchedulePolicy end
struct Interpolate <: SchedulePolicy end
struct Integrate <: SchedulePolicy end
struct Aggregate <: SchedulePolicy end
```

API:

```julia
# When a model runs
PlantSimEngine.timespec(::Type{<:AbstractModel}) = ClockSpec(1.0, 0.0)

# How each output variable is consumed across clock mismatches
PlantSimEngine.output_policy(::Type{<:AbstractModel}) = NamedTuple()
# default fallback for unspecified outputs: HoldLast()
```

## 5. Temporal storage (typed, minimal, no `Any`)

Temporal storage is per produced output stream (`OutputKey`), not full state snapshots.

```julia
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

mutable struct TemporalState
    caches::Dict{OutputKey,OutputCache}
    last_run::Dict{ModelKey,Float64}
end
```

No `Tuple{Float64,Any}` is needed.

## 6. `Status` versus temporal state

- `Status`: canonical mutable value store per object (node), shared by models at that scale.
- `TemporalState`: policy-specific memory required to resolve off-clock reads.

`TemporalState` does not replace `Status`. It complements it.

## 7. Name conflicts and canonical publication

Problem: same `(scope, scale, node, var)` can be produced by different processes or clocks.

Rule:
1. Each process writes to its own producer stream (`OutputKey` includes `process`).
2. Publication to canonical `Status[var]` is explicit via a publish rule.

Draft API:

```julia
struct OutputPublishRule
    var::Symbol
    mode::Symbol   # :canonical | :stream_only
end

PlantSimEngine.publish_rule(::Type{<:AbstractModel}) = NamedTuple()
```

Validation:
- if multiple processes publish same canonical `var` at same scope/scale without a merge rule, throw ambiguity error at build time.

## 8. Input binding and resolution

Inputs should resolve from producer stream + policy when clocks differ.

Draft API:

```julia
struct InputBinding
    input_var::Symbol
    source_process::Symbol
    source_var::Symbol
end

PlantSimEngine.input_bindings(::Type{<:AbstractModel}) = NamedTuple()
```

Resolver:

```julia
resolve_input(ts::TemporalState, key::OutputKey, t::Float64, policy::SchedulePolicy)
```

Fast path:
- if consumer and producer are on same event time and source is canonical, read directly from `Status`.

## 9. Scheduler and execution

### 9.1 Scheduler interface

```julia
abstract type AbstractScheduler end

current_time(s::AbstractScheduler)::Float64
next_time!(s::AbstractScheduler)::Float64
due_models(s::AbstractScheduler, t::Float64)::Vector{ModelKey}
```

### 9.2 Execution rules

1. Event loop advances to next event time `t`.
2. Run only due soft-dependency roots/subgraphs.
3. For each model run:
   - resolve inputs (`Status` fast path or temporal resolver),
   - execute model,
   - update producer caches for model outputs,
   - publish to canonical `Status` according to publish rules.

## 10. Hard-dependencies remain manual

Hard-dependencies are not scheduled by dependency graph traversal.

They are used for:
- dependency validation,
- excluding hard-coupled processes from soft graph roots,
- wiring model lookup metadata.

Execution remains inside parent model `run!`.

For multiscale hard-dependencies:
- parent can call hard-dependent models at other scales,
- called model writes to its own scale statuses,
- those statuses remain visible to other models at that scale.

## 11. Iterative hard-coupled loops

For iterative scene-level solvers (energy balance, hydraulics):
- inner iterations should update working state and canonical `Status`,
- temporal caches should be committed once per accepted event time (post-convergence),
- do not append every inner iteration to temporal caches.

This avoids corrupting interpolation/integration with solver internal iterations.

## 12. Mapping to the typical workflow

Example setup:
1. 30-min light interception at organ scales using daily LAI from previous day.
2. 30-min scene energy balance with manual multiscale hard-coupled organ calls + convergence loop.
3. Daily plant carbon offer from hourly leaf photosynthesis sum.
4. Daily organ carbon demand.
5. Daily carbon allocation.
6. Daily organ growth.

How draft handles it:
- scheduler triggers 30-min and daily events;
- daily LAI is held between daily updates (`HoldLast`);
- leaf hourly photosynthesis stream uses `Integrate`/`Aggregate` into daily carbon offer;
- hard-coupled scene model remains manual and convergent;
- canonical status always holds current committed state at event time.

## 13. GraphSimulation evolution (minimal shape)

Current `GraphSimulation` can evolve with additive fields:

```julia
struct GraphSimulation{T,S,U,O,V,TS}
    graph::T
    statuses::S
    status_templates::Dict{String,Dict{Symbol,Any}}
    reverse_multiscale_mapping::Dict{String,Dict{String,Dict{Symbol,Any}}}
    var_need_init::Dict{String,V}
    dependency_graph::DependencyGraph
    models::Dict{String,U}
    outputs::Dict{String,O}
    outputs_index::Dict{String,Int}
    temporal_state::TS
end
```

This keeps backward compatibility for existing single-rate paths.

## 14. Migration plan

1. Add `timespec`, `output_policy`, and typed `TemporalState` (unused by default).
2. Add scheduler abstraction and event loop for MTG run path.
3. Add input resolver and output cache update.
4. Add publish and ambiguity validation.
5. Add hard-dep helper lookup API (still manual execution only).
6. Add tests for:
   - mixed 30-min/daily coupling,
   - per-output policies,
   - multiscale hard-coupled iterative loop,
   - ambiguous canonical output conflict detection.

## 15. Non-goals for first milestone

- full generic interpolation/integration for non-numeric types,
- monthly/yearly calendars or irregular solver clocks,
- changing hard-dependency execution semantics.


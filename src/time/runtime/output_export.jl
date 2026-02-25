"""
    OutputRequest(scale, var; name=var, process=nothing, policy=HoldLast(), clock=nothing)

Describe one online-exported multi-rate output series for MTG multi-rate runs.

Use this type in `run!(...; tracked_outputs=...)` to export
resampled temporal streams while simulation is running.

# Arguments
- `scale::Symbol`: producer scale (for example `:Leaf` or `:Plant`).
- `var::Symbol`: source variable name published on `scale`.

# Keyword arguments
- `name::Symbol=var`: name of the exported series in `collect_outputs(sim)` or
  returned output dictionaries. Names must be unique across requests.
- `process=nothing`: producer process name (`Symbol`/`String`) or `nothing`.
  When `nothing`, runtime tries to use the unique canonical publisher for
  `(scale, var)` and errors on ambiguity.
- `policy::SchedulePolicy=HoldLast()`: resampling policy applied at export time.
  Common values are `HoldLast()`, `Integrate(...)`, `Aggregate(...)`,
  `Interpolate(...)`.
  `Integrate` and `Aggregate` are runtime-equivalent with the same reducer;
  they differ by default reducer (`SumReducer` vs `MeanReducer`) and intent.
- `clock=nothing`: export clock. When `nothing`, export is evaluated at each
  simulation step (`ClockSpec(1.0, 0.0)`). Accepted explicit values are the same
  as model timestep specs (`Real`, `ClockSpec`, or fixed `Dates.Period`).

# Example
```julia
req_daily = OutputRequest(
    :Leaf,
    :A;
    name=:A_daily,
    process=:toyassim,
    policy=Integrate(),
    clock=ClockSpec(24.0, 0.0),
)
```
"""
struct OutputRequest{P<:Union{Nothing,Symbol},POL<:SchedulePolicy,C}
    scale::Symbol
    var::Symbol
    name::Symbol
    process::P
    policy::POL
    clock::C
end

function OutputRequest(
    scale::Symbol,
    var::Symbol;
    name::Symbol=var,
    process=nothing,
    policy::SchedulePolicy=HoldLast(),
    clock=nothing
)
    proc = isnothing(process) ? nothing : Symbol(process)
    return OutputRequest(scale, var, name, proc, policy, clock)
end

function OutputRequest(
    scale::AbstractString,
    var::Symbol;
    name::Symbol=var,
    process=nothing,
    policy::SchedulePolicy=HoldLast(),
    clock=nothing
)
    return OutputRequest(
        _normalize_scale(scale; warn=true, context=:OutputRequest),
        var;
        name=name,
        process=process,
        policy=policy,
        clock=clock
    )
end

function _export_clock(request::OutputRequest, timeline::TimelineContext)
    isnothing(request.clock) && return ClockSpec(1.0, 0.0)
    c = _clock_from_spec_timestep(request.clock, timeline)
    isnothing(c) && error(
        "Unsupported clock specification `$(typeof(request.clock))` in OutputRequest `$(request.name)`."
    )
    return c
end

function _canonical_source_process(sim::GraphSimulation, scale::Symbol, var::Symbol)
    haskey(get_models(sim), scale) || error("Unknown scale `$(scale)` in output export request.")
    models_at_scale = get_models(sim)[scale]
    specs_at_scale = get_model_specs(sim)[scale]
    ignored_same_rate_hard_children = _same_rate_hard_dependency_children(get_model_specs(sim), dep(sim))
    ignored_at_scale = get(ignored_same_rate_hard_children, scale, Set{Symbol}())

    publishers = Symbol[]
    for (process, model) in pairs(models_at_scale)
        process in ignored_at_scale && continue
        var in keys(outputs_(model)) || continue
        spec = get(specs_at_scale, process, as_model_spec(model))
        _publish_mode_for_output(spec, var) == :stream_only && continue
        push!(publishers, process)
    end

    if isempty(publishers)
        error(
            "No canonical publisher found for variable `$(var)` at scale `$(scale)`. ",
            "Provide `process=` in OutputRequest or mark one producer as canonical."
        )
    elseif length(publishers) > 1
        error(
            "Ambiguous canonical publishers for variable `$(var)` at scale `$(scale)`: ",
            join(publishers, ", "),
            ". Provide `process=` in OutputRequest."
        )
    end

    return only(publishers)
end

function _normalize_output_requests(requests)
    isnothing(requests) && return OutputRequest[]
    requests isa OutputRequest && return OutputRequest[requests]
    requests isa AbstractVector{<:OutputRequest} || error(
        "`tracked_outputs` (for multi-rate exports) must be `nothing`, an `OutputRequest`, or a vector of `OutputRequest`."
    )
    return collect(requests)
end

"""
    prepare_output_requests!(sim, requests, timeline)

Resolve and register online export requests for the current run.
"""
function prepare_output_requests!(sim::GraphSimulation, requests, timeline::TimelineContext)
    reqs = _normalize_output_requests(requests)

    plans = Any[]
    rows = Dict{Symbol,ExportBuffer}()

    for req in reqs
        scale = req.scale
        process = isnothing(req.process) ? _canonical_source_process(sim, scale, req.var) : req.process
        model_spec = _model_spec_for_process(sim, scale, process)
        source_model = get_models(sim)[scale][process]
        source_clock = _model_clock(model_spec, source_model, timeline)
        clock = _export_clock(req, timeline)

        haskey(rows, req.name) && error(
            "Duplicate output request name `$(req.name)`. Request names must be unique."
        )

        push!(plans, (
            name=req.name,
            scale=scale,
            var=req.var,
            process=process,
            policy=req.policy,
            clock=clock,
            model_spec=model_spec,
            source_dt=float(source_clock.dt),
        ))
        rows[req.name] = ExportBuffer(scale, process, req.var)
    end

    sim.temporal_state.export_plans = plans
    sim.temporal_state.export_rows = rows
    return nothing
end

function _required_horizon_for_export_policy(policy::SchedulePolicy, clock::ClockSpec, source_dt::Float64)
    if policy isa Union{Integrate,Aggregate}
        return max(1.0, float(clock.dt))
    elseif policy isa Interpolate
        return max(2.0, source_dt + 1.0)
    end
    # HoldLast export is served from caches and does not require streams.
    return 0.0
end

"""
    export_horizon_requirements(sim)

Return additional producer horizon requirements induced by configured online
export requests.
"""
function export_horizon_requirements(sim::GraphSimulation)
    horizons = Dict{Tuple{Symbol,Symbol,Symbol},Float64}()
    for plan in sim.temporal_state.export_plans
        required = _required_horizon_for_export_policy(plan.policy, plan.clock, plan.source_dt)
        required <= 0.0 && continue
        key = (plan.scale, plan.process, plan.var)
        horizons[key] = max(get(horizons, key, 0.0), required)
    end
    return horizons
end

function _resolve_output_value_online(
    sim::GraphSimulation,
    policy::HoldLast,
    scope::ScopeId,
    scale::Symbol,
    process::Symbol,
    var::Symbol,
    nodeid::Int,
    t::Float64,
    t_start::Float64
)
    v, ok = _resolved_value_for_source(sim, scope, scale, process, var, nodeid, t)
    return ok ? v : missing
end

function _resolve_output_value_online(
    sim::GraphSimulation,
    policy::Interpolate,
    scope::ScopeId,
    scale::Symbol,
    process::Symbol,
    var::Symbol,
    nodeid::Int,
    t::Float64,
    t_start::Float64
)
    v, ok = _resolved_interpolated_value_for_source(sim, scope, scale, process, var, nodeid, t, policy)
    return ok ? v : missing
end

function _resolve_output_value_online(
    sim::GraphSimulation,
    policy::Union{Integrate,Aggregate},
    scope::ScopeId,
    scale::Symbol,
    process::Symbol,
    var::Symbol,
    nodeid::Int,
    t::Float64,
    t_start::Float64
)
    v, ok = _resolved_windowed_value_for_source(sim, scope, scale, process, var, nodeid, t_start, t, policy)
    return ok ? v : missing
end

"""
    update_requested_outputs!(sim, t)

Materialize configured output requests online at runtime time `t`.
"""
function update_requested_outputs!(sim::GraphSimulation, t::Float64)
    isempty(sim.temporal_state.export_plans) && return nothing
    timestep = Int(round(t))

    for plan in sim.temporal_state.export_plans
        _should_run_at_time(plan.clock, t) || continue
        source_statuses = get(status(sim), plan.scale, nothing)
        isnothing(source_statuses) && continue
        buf = sim.temporal_state.export_rows[plan.name]

        t_start = _window_start_for_clock(plan.clock, t)
        for st in source_statuses
            scope = _scope_for_status(sim, plan.model_spec, plan.scale, plan.process, st.node)
            nodeid = node_id(st.node)
            v = _resolve_output_value_online(
                sim,
                plan.policy,
                scope,
                plan.scale,
                plan.process,
                plan.var,
                nodeid,
                t,
                t_start,
            )

            push!(buf.timestep, timestep)
            push!(buf.node, nodeid)
            push!(buf.value, v)
        end
    end

    return nothing
end

function _materialize_output_rows(rows::ExportBuffer, sink)
    n = length(rows.timestep)
    scale_col = fill(rows.scale, n)
    process_col = fill(rows.process, n)
    var_col = fill(rows.var, n)

    if sink === DataFrames.DataFrame
        return DataFrames.DataFrame(
            timestep=rows.timestep,
            scale=scale_col,
            process=process_col,
            var=var_col,
            node=rows.node,
            value=rows.value,
        )
    end

    table = Vector{NamedTuple{(:timestep, :scale, :process, :var, :node, :value),Tuple{Int,Symbol,Symbol,Symbol,Int,Any}}}(undef, n)
    @inbounds for i in 1:n
        table[i] = (
            timestep=rows.timestep[i],
            scale=scale_col[i],
            process=process_col[i],
            var=var_col[i],
            node=rows.node[i],
            value=rows.value[i],
        )
    end

    isnothing(sink) && return table
    return sink(table)
end

"""
    collect_outputs(sim; sink=DataFrame)

Return online-exported output rows configured for the run.
"""
function collect_outputs(sim::GraphSimulation; sink=DataFrames.DataFrame)
    out = Dict{Symbol,Any}()
    for (name, rows) in sim.temporal_state.export_rows
        out[name] = _materialize_output_rows(rows, sink)
    end
    return out
end

function collect_outputs(sim::GraphSimulation, name::Symbol; sink=DataFrames.DataFrame)
    haskey(sim.temporal_state.export_rows, name) || error(
        "Unknown output request name `$(name)`."
    )
    return _materialize_output_rows(sim.temporal_state.export_rows[name], sink)
end

"""
    OutputRequest(scale, var; name=var, process=nothing, policy=HoldLast(), clock=nothing)

Describe one exported multi-rate output series from temporal producer streams.

# Fields

- `scale`: source scale (e.g. `"Leaf"`).
- `var`: source variable name.
- `name`: output series key in the returned dictionary.
- `process`: optional source process. If omitted, canonical source resolution is used.
- `policy`: resampling policy used at export time (`HoldLast`, `Interpolate`, `Integrate`, `Aggregate`).
- `clock`: optional target export clock (`Real`, `ClockSpec`, `Dates.Period`).
"""
struct OutputRequest{S<:AbstractString,P<:Union{Nothing,Symbol},POL<:SchedulePolicy,C}
    scale::S
    var::Symbol
    name::Symbol
    process::P
    policy::POL
    clock::C
end

function OutputRequest(
    scale::AbstractString,
    var::Symbol;
    name::Symbol=var,
    process=nothing,
    policy::SchedulePolicy=HoldLast(),
    clock=nothing
)
    proc = isnothing(process) ? nothing : Symbol(process)
    return OutputRequest(scale, var, name, proc, policy, clock)
end

function _export_clock(request::OutputRequest, timeline::TimelineContext)
    isnothing(request.clock) && return ClockSpec(1.0, 0.0)
    c = _clock_from_spec_timestep(request.clock, timeline)
    isnothing(c) && error(
        "Unsupported clock specification `$(typeof(request.clock))` in OutputRequest `$(request.name)`."
    )
    return c
end

function _max_export_time(sim::GraphSimulation, nsteps)
    !isnothing(nsteps) && return Int(nsteps)
    isempty(sim.temporal_state.last_run) && error(
        "No temporal samples available. Run simulation with `multirate=true` before calling `collect_outputs`."
    )
    return Int(floor(maximum(values(sim.temporal_state.last_run))))
end

function _canonical_source_process(sim::GraphSimulation, scale::String, var::Symbol)
    haskey(get_models(sim), scale) || error("Unknown scale `$(scale)` in output export request.")
    models_at_scale = get_models(sim)[scale]
    specs_at_scale = get_model_specs(sim)[scale]

    publishers = Symbol[]
    for (process, model) in pairs(models_at_scale)
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

function _resolve_output_value(
    sim::GraphSimulation,
    policy::HoldLast,
    scope::ScopeId,
    scale::String,
    process::Symbol,
    var::Symbol,
    nodeid::Int,
    t::Float64,
    t_start::Float64
)
    key = OutputKey(scope, scale, nodeid, process, var)
    samples = get(sim.temporal_state.samples, key, nothing)
    isnothing(samples) && return missing
    isempty(samples) && return missing
    idx = findlast(s -> s[1] <= t + 1e-8, samples)
    if isnothing(idx)
        v = samples[1][2]
        return v
    end
    v = samples[idx][2]
    return v
end

function _resolve_output_value(
    sim::GraphSimulation,
    policy::Interpolate,
    scope::ScopeId,
    scale::String,
    process::Symbol,
    var::Symbol,
    nodeid::Int,
    t::Float64,
    t_start::Float64
)
    v, ok = _resolved_interpolated_value_for_source(sim, scope, scale, process, var, nodeid, t, policy)
    return ok ? v : missing
end

function _resolve_output_value(
    sim::GraphSimulation,
    policy::Union{Integrate,Aggregate},
    scope::ScopeId,
    scale::String,
    process::Symbol,
    var::Symbol,
    nodeid::Int,
    t::Float64,
    t_start::Float64
)
    v, ok = _resolved_windowed_value_for_source(sim, scope, scale, process, var, nodeid, t_start, t, policy)
    return ok ? v : missing
end

function _collect_one_output_request(
    sim::GraphSimulation,
    request::OutputRequest,
    timeline::TimelineContext,
    max_t::Int
)
    scale = String(request.scale)
    process = isnothing(request.process) ? _canonical_source_process(sim, scale, request.var) : request.process
    model_spec = _model_spec_for_process(sim, scale, process)
    source_statuses = get(status(sim), scale, nothing)
    isnothing(source_statuses) && error("No statuses found at scale `$(scale)` for OutputRequest `$(request.name)`.")

    clock = _export_clock(request, timeline)
    times = Int[t for t in 1:max_t if _should_run_at_time(clock, float(t))]
    rows = NamedTuple[]

    for st in source_statuses
        scope = _scope_for_status(sim, model_spec, scale, process, st.node)
        nodeid = node_id(st.node)
        for ti in times
            t = float(ti)
            t_start = _window_start_for_clock(clock, t)
            v = _resolve_output_value(sim, request.policy, scope, scale, process, request.var, nodeid, t, t_start)
            push!(rows, (
                timestep=ti,
                scale=scale,
                process=process,
                var=request.var,
                node=nodeid,
                value=v,
            ))
        end
    end

    return rows
end

function _materialize_output_rows(rows, sink)
    isnothing(sink) && return rows
    return sink(rows)
end

"""
    collect_outputs(sim, requests; nsteps=nothing, meteo=nothing, sink=DataFrame)

Export selected multi-rate output series from producer temporal streams.

Returns a dictionary keyed by request `name`.
Each value is materialized with `sink` (default: `DataFrame`).
"""
function collect_outputs(
    sim::GraphSimulation,
    requests::AbstractVector{<:OutputRequest};
    nsteps=nothing,
    meteo=nothing,
    sink=DataFrames.DataFrame
)
    timeline = _timeline_context(meteo)
    max_t = _max_export_time(sim, nsteps)
    out = Dict{Symbol,Any}()
    for req in requests
        rows = _collect_one_output_request(sim, req, timeline, max_t)
        out[req.name] = _materialize_output_rows(rows, sink)
    end
    return out
end

function collect_outputs(
    sim::GraphSimulation,
    request::OutputRequest;
    nsteps=nothing,
    meteo=nothing,
    sink=DataFrames.DataFrame
)
    return collect_outputs(sim, [request]; nsteps=nsteps, meteo=meteo, sink=sink)[request.name]
end

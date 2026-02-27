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

    if DataFormat(meteo) == SingletonAlike() && hasproperty(meteo, :duration)
        _base_step_seconds_from_meteo_row(meteo; require_duration=true, context="meteo")
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
    elseif !isnothing(meteo) && DataFormat(meteo) == SingletonAlike() && hasproperty(meteo, :duration)
        return TimelineContext(_base_step_seconds_from_meteo_row(meteo; require_duration=true, context="meteo"))
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

_effective_multirate(mapping::ModelMapping) = is_multirate(mapping)
_effective_multirate(mapping::ModelMapping, meteo) = is_multirate(mapping)
_effective_multirate(sim::GraphSimulation) = is_multirate(sim)

function _format_seconds_label(sec::Float64)
    ms = round(Int, sec * 1000.0)
    if ms % 3_600_000 == 0
        return string(Dates.Hour(ms ÷ 3_600_000))
    elseif ms % 60_000 == 0
        return string(Dates.Minute(ms ÷ 60_000))
    elseif ms % 1000 == 0
        return string(Dates.Second(ms ÷ 1000))
    end
    return string(Dates.Millisecond(ms))
end

struct EffectiveRateSummary
    base_step_seconds::Float64
    rates::Dict{Float64,Vector{NamedTuple}}
end

function Base.show(io::IO, ::MIME"text/plain", summary::EffectiveRateSummary)
    println(io, "Effective model rates (base step: ", _format_seconds_label(summary.base_step_seconds), ")")
    for rate_sec in sort!(collect(keys(summary.rates)))
        entries = summary.rates[rate_sec]
        println(io, "  - ", _format_seconds_label(rate_sec), " (", length(entries), " model(s))")
        for row in sort!(collect(entries); by=x -> (string(x.scale), string(x.process)))
            println(io, "    • ", row.scale, "/", row.process, " [", row.source, "]")
        end
    end
end

"""
    effective_rate_summary(mapping::ModelMapping{MultiScale}, meteo)

Summarize the effective model execution rates implied by `mapping` and `meteo`.
Returns an `EffectiveRateSummary` struct with details on the effective rates and their sources.

To get the value of the base step used for the simulation, use `summary.base_step_seconds`.
To get the effective rates and their sources, use `summary.rates`, which is a dictionary 
mapping each effective rate (in seconds) to a vector of named tuples with keys `:scale`,
`:process`, `:source`, and `:model` describing the models running at that rate and their 
source of timing.
"""
function effective_rate_summary(mapping::ModelMapping{MultiScale}, meteo)
    _validate_meteo_duration(meteo)
    timeline = _timeline_context(meteo)
    rows = _runtime_clock_rows(mapping, timeline)
    grouped = Dict{Float64,Vector{NamedTuple}}()

    for row in rows
        rate_sec = float(row.clock.dt) * timeline.base_step_seconds
        entry = (scale=row.scale, process=row.process, source=row.source, model=typeof(row.model))
        push!(get!(grouped, rate_sec, NamedTuple[]), entry)
    end

    return EffectiveRateSummary(timeline.base_step_seconds, grouped)
end

function _resolve_meteo_hint_clock(scale::Symbol, process::Symbol, model, timeline::TimelineContext)
    base_sec = timeline.base_step_seconds
    hint = _normalize_timestep_hint(scale, process, timestep_hint(model))
    desired_sec = base_sec
    reason = nothing

    if !isnothing(hint.fixed)
        desired_sec = _seconds_from_period(hint.fixed)
        if !isapprox(desired_sec, base_sec; atol=1.0e-9, rtol=0.0)
            reason = string(
                "`timestep_hint.required=", hint.fixed,
                "` differs from meteo base step ", _format_seconds_label(base_sec), "."
            )
        end
    elseif !isnothing(hint.range)
        lo, hi = hint.range
        lo_sec = _seconds_from_period(lo)
        hi_sec = _seconds_from_period(hi)
        if base_sec < lo_sec
            desired_sec = lo_sec
            reason = string(
                "meteo base step ", _format_seconds_label(base_sec),
                " is finer than required lower bound ", lo,
                "; using ", lo, "."
            )
        elseif base_sec > hi_sec
            desired_sec = hi_sec
            reason = string(
                "meteo base step ", _format_seconds_label(base_sec),
                " is coarser than required upper bound ", hi,
                "; attempting ", hi, "."
            )
        end
    end

    if desired_sec < base_sec
        reason = isnothing(reason) ?
                 string("required timestep ", _format_seconds_label(desired_sec), " is shorter than meteo; using meteo base step.") :
                 string(reason, " Runtime does not support sub-step execution; using meteo base step.")
        desired_sec = base_sec
    end

    dt = desired_sec / base_sec
    return ClockSpec(dt, 0.0), reason
end

function _runtime_clock_rows(mapping::ModelMapping{MultiScale}, timeline::TimelineContext)
    specs_by_scale = !isempty(mapping.info.model_specs) ?
                     mapping.info.model_specs :
                     Dict(scale => parse_model_specs(scale_mapping) for (scale, scale_mapping) in pairs(mapping))

    rows = NamedTuple[]
    for (scale, specs_at_scale) in pairs(specs_by_scale)
        for (process, spec) in pairs(specs_at_scale)
            model = model_(spec)
            source = _runtime_clock_source_for_spec(spec)
            clock = _model_clock(spec, model, timeline)
            hint_reason = nothing
            if source == :meteo_base_step
                clock, hint_reason = _resolve_meteo_hint_clock(scale, process, model, timeline)
            end
            push!(rows, (
                scale=scale,
                process=process,
                source=source,
                clock=clock,
                model=model,
                hint_reason=hint_reason,
            ))
        end
    end

    return rows
end

function _mapping_requires_runtime_multirate(mapping::ModelMapping{MultiScale}, meteo)
    isnothing(meteo) && return false
    timeline = _timeline_context(meteo)
    rows = _runtime_clock_rows(mapping, timeline)
    return any(!isapprox(float(row.clock.dt), 1.0; atol=1.0e-9, rtol=0.0) for row in rows)
end

function _effective_multirate(mapping::ModelMapping{MultiScale}, meteo)
    is_multirate(mapping) && return true
    return _mapping_requires_runtime_multirate(mapping, meteo)
end



function _runtime_clock_source_for_spec(spec::ModelSpec)
    !isnothing(timestep(spec)) && return :modelspec
    return _is_default_clock(timespec(model_(spec))) ? :meteo_base_step : :model_timespec
end

function _runtime_clock_rows(object::GraphSimulation, timeline::TimelineContext, dep_graph::DependencyGraph)
    active = _active_dependency_processes(dep_graph)
    rows = NamedTuple[]

    for (scale, specs_at_scale) in pairs(get_model_specs(object))
        for (process, spec) in pairs(specs_at_scale)
            (scale, process) in active || continue
            model = model_(spec)
            source = _runtime_clock_source_for_spec(spec)
            clock = _model_clock(spec, model, timeline)
            hint_reason = nothing
            if source == :meteo_base_step
                clock, hint_reason = _resolve_meteo_hint_clock(scale, process, model, timeline)
            end
            push!(rows, (
                scale=scale,
                process=process,
                source=source,
                clock=clock,
                model=model,
                hint_reason=hint_reason,
            ))
        end
    end

    return rows
end


function _warn_if_no_model_runs_at_base_timestep(rows, timeline::TimelineContext)
    isempty(rows) && return nothing
    any(isapprox(float(row.clock.dt), 1.0; atol=1.0e-9, rtol=0.0) for row in rows) && return nothing

    source_label(source) = source == :modelspec ? "ModelSpec" : (source == :model_timespec ? "timespec(model)" : "meteo")
    details = sort([
        string(
            row.scale,
            "/",
            row.process,
            "=",
            round(float(row.clock.dt) * timeline.base_step_seconds; digits=6),
            "s (",
            source_label(row.source),
            ")"
        ) for row in rows
    ])

    @warn string(
        "No model runs at the meteo base timestep (",
        timeline.base_step_seconds,
        " s). Resolved model timesteps: ",
        join(details, ", "),
        "."
    ) maxlog = 1
    return nothing
end


function _validate_meteo_derived_timestep_requirements!(rows, timeline::TimelineContext)
    for row in rows
        row.source == :meteo_base_step || continue

        if !isnothing(row.hint_reason)
            @warn string(
                "Adjusted runtime timestep for `",
                row.scale,
                "/",
                row.process,
                "` from meteo-derived default: ",
                row.hint_reason,
                " Effective timestep is ",
                _format_seconds_label(float(row.clock.dt) * timeline.base_step_seconds),
                "."
            ) maxlog = 1
        end
    end

    return nothing
end
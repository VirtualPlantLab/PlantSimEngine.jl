"""
    _policy_for_output(model, var)

Return the per-output schedule policy for `var`, defaulting to `HoldLast()`.
"""
function _policy_for_output(model, var::Symbol)
    pol = output_policy(model)
    var in keys(pol) || return HoldLast()
    return _as_schedule_policy(pol[var]; context="output_policy for output `$(var)` in model `$(typeof(model))`")
end

"""
    _publish_mode_for_output(model_spec, var)

Return output routing mode for `var` (`:canonical` or `:stream_only`), with
validation and default `:canonical`.
"""
function _publish_mode_for_output(model_spec, var::Symbol)
    modes = output_routing(model_spec)
    mode = var in keys(modes) ? modes[var] : :canonical
    mode in (:canonical, :stream_only) || error(
        "Unsupported output routing mode `$(mode)` for output `$(var)`. ",
        "Allowed values are `:canonical` and `:stream_only`."
    )
    return mode
end

"""
    validate_canonical_publishers(sim)

Ensure that each `(scale, variable)` has at most one canonical publisher.
Throws when multiple producers publish the same canonical output.
"""
function validate_canonical_publishers(sim::GraphSimulation)
    ignored_same_rate_hard_children = _same_rate_hard_dependency_children(get_model_specs(sim), dep(sim))
    for (scale, models_at_scale) in get_models(sim)
        specs_at_scale = get_model_specs(sim)[scale]
        ignored_at_scale = get(ignored_same_rate_hard_children, scale, Set{Symbol}())
        publishers = Dict{Symbol,Vector{Symbol}}()
        for (process, model) in pairs(models_at_scale)
            process in ignored_at_scale && continue
            model_spec = get(specs_at_scale, process, as_model_spec(model))
            for var in keys(outputs_(model))
                _publish_mode_for_output(model_spec, var) == :stream_only && continue
                if !haskey(publishers, var)
                    publishers[var] = Symbol[process]
                else
                    push!(publishers[var], process)
                end
            end
        end

        for (var, procs) in publishers
            if length(procs) > 1
                error(
                    "Ambiguous canonical publishers for variable `$(var)` at scale `$(scale)`: ",
                    join(procs, ", "),
                    ". Declare `OutputRouting(; $(var)=:stream_only)` for non-canonical producers."
                )
            end
        end
    end
    return nothing
end

_producer_signature(scale::Symbol, process::Symbol, var::Symbol) = (scale, process, var)

function _max_horizon!(horizons::Dict{Tuple{Symbol,Symbol,Symbol},Float64}, key::Tuple{Symbol,Symbol,Symbol}, required::Float64)
    horizons[key] = max(get(horizons, key, 0.0), required)
    return nothing
end

function _required_horizon_for_policy(policy::SchedulePolicy, consumer_dt::Float64, source_dt::Float64)
    if policy isa Union{Integrate,Aggregate}
        return max(1.0, consumer_dt)
    elseif policy isa Interpolate
        # Keep at least two source samples for interpolation/extrapolation.
        return max(2.0, source_dt + 1.0)
    end
    return 0.0
end

function _consumer_horizon_requirements(sim::GraphSimulation, timeline::TimelineContext)
    horizons = Dict{Tuple{Symbol,Symbol,Symbol},Float64}()

    dep_nodes = traverse_dependency_graph(dep(sim), false)
    for node in dep_nodes
        model_spec = _model_spec_for_process(sim, node.scale, node.process)
        consumer_clock = _model_clock(model_spec, node.value, timeline)
        consumer_dt = float(consumer_clock.dt)

        for (input_var, raw_binding) in pairs(input_bindings(model_spec))
            parsed = _parse_input_binding(raw_binding)
            isnothing(parsed) && continue
            isnothing(parsed.process) && continue
            source_process = parsed.process
            source_var = isnothing(parsed.var) ? input_var : parsed.var
            source_scale = isnothing(parsed.scale) ? _source_scale_for_process(node, source_process) : parsed.scale
            source_scale = source_scale isa AbstractString ?
                           _normalize_scale(source_scale; warn=true, context=:ModelSpec) :
                           source_scale
            source_model_spec = _model_spec_for_process(sim, source_scale, source_process)
            source_model = get_models(sim)[source_scale][source_process]
            source_clock = _model_clock(source_model_spec, source_model, timeline)
            source_dt = float(source_clock.dt)
            required = _required_horizon_for_policy(parsed.policy, consumer_dt, source_dt)
            required <= 0.0 && continue
            key = _producer_signature(source_scale, source_process, source_var)
            _max_horizon!(horizons, key, required)
        end
    end

    return horizons
end

"""
    configure_temporal_buffers!(sim, timeline)

Prepare bounded producer streams used at runtime and online export.
"""
function configure_temporal_buffers!(sim::GraphSimulation, timeline::TimelineContext)
    horizons = _consumer_horizon_requirements(sim, timeline)
    for (key, required) in export_horizon_requirements(sim)
        _max_horizon!(horizons, key, required)
    end
    sim.temporal_state.producer_horizons = horizons
    empty!(sim.temporal_state.streams)
    empty!(sim.temporal_state.caches)
    empty!(sim.temporal_state.last_run)
    return nothing
end

function _trim_stream!(samples::Vector{Tuple{Float64,Any}}, t::Float64, horizon::Float64)
    horizon <= 0.0 && (empty!(samples); return nothing)
    t_min = t - horizon + 1.0 - 1e-8
    first_keep = findfirst(s -> s[1] >= t_min, samples)
    isnothing(first_keep) && (empty!(samples); return nothing)
    first_keep > 1 && deleteat!(samples, 1:first_keep-1)
    return nothing
end

"""
    update_temporal_state_outputs!(sim, node, model_spec, st, t)

Store producer outputs at time `t` into temporal streams and hold-last caches.
Also updates `last_run` for the emitting model key.
"""
function update_temporal_state_outputs!(sim::GraphSimulation, node::SoftDependencyNode, model_spec, st::Status, t::Float64)
    model = node.value
    outs = keys(outputs_(model))
    length(outs) == 0 && return nothing

    scope = _scope_for_status(sim, model_spec, node.scale, node.process, st.node)
    nodeid = node_id(st.node)
    mkey = ModelKey(scope, node.scale, node.process)
    sim.temporal_state.last_run[mkey] = t

    for out_var in outs
        val = st[out_var]
        key = OutputKey(scope, node.scale, nodeid, node.process, out_var)
        producer_key = _producer_signature(node.scale, node.process, out_var)

        if haskey(sim.temporal_state.producer_horizons, producer_key)
            samples = get!(sim.temporal_state.streams, key, Vector{Tuple{Float64,Any}}())
            push!(samples, (t, val))
            _trim_stream!(samples, t, sim.temporal_state.producer_horizons[producer_key])
        end

        policy = _policy_for_output(model, out_var)
        policy isa HoldLast || continue
        sim.temporal_state.caches[key] = HoldLastCache(t, val)
    end

    return nothing
end

"""
    _policy_for_output(model, var)

Return the per-output schedule policy for `var`, defaulting to `HoldLast()`.
"""
function _policy_for_output(model, var::Symbol)
    pol = output_policy(model)
    var in keys(pol) ? pol[var] : HoldLast()
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
    for (scale, models_at_scale) in get_models(sim)
        specs_at_scale = get_model_specs(sim)[scale]
        publishers = Dict{Symbol,Vector{Symbol}}()
        for (process, model) in pairs(models_at_scale)
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

function _runtime_window_horizon(sim::GraphSimulation, timeline::TimelineContext)
    max_dt = 1.0
    for (scale, models_at_scale) in get_models(sim)
        specs_at_scale = get_model_specs(sim)[scale]
        for (process, model) in pairs(models_at_scale)
            model_spec = get(specs_at_scale, process, as_model_spec(model))
            consumer_clock = _model_clock(model_spec, model, timeline)
            consumer_dt = float(consumer_clock.dt)
            for (_, raw_binding) in pairs(input_bindings(model_spec))
                parsed = _parse_input_binding(raw_binding)
                isnothing(parsed) && continue
                policy = parsed.policy
                if policy isa Union{Integrate,Aggregate}
                    max_dt = max(max_dt, consumer_dt)
                end
            end
        end
    end
    return max_dt
end

"""
    configure_runtime_temporal_buffers!(sim, timeline)

Prepare bounded runtime temporal buffers used by input resolution.
Full sample history used by export stays in `temporal_state.samples`.
"""
function configure_runtime_temporal_buffers!(sim::GraphSimulation, timeline::TimelineContext)
    sim.temporal_state.runtime_window_horizon = _runtime_window_horizon(sim, timeline)
    empty!(sim.temporal_state.runtime_samples)
    return nothing
end

function _trim_runtime_samples!(samples::Vector{Tuple{Float64,Any}}, t::Float64, horizon::Float64)
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

        # Keep a full sample stream for windowed policies.
        samples = get!(sim.temporal_state.samples, key, Vector{Tuple{Float64,Any}}())
        push!(samples, (t, val))
        runtime_samples = get!(sim.temporal_state.runtime_samples, key, Vector{Tuple{Float64,Any}}())
        push!(runtime_samples, (t, val))
        _trim_runtime_samples!(runtime_samples, t, sim.temporal_state.runtime_window_horizon)

        policy = _policy_for_output(model, out_var)
        policy isa HoldLast || continue
        sim.temporal_state.caches[key] = HoldLastCache(t, val)
    end

    return nothing
end

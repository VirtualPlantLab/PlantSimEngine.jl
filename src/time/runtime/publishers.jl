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

        policy = _policy_for_output(model, out_var)
        policy isa HoldLast || continue
        sim.temporal_state.caches[key] = HoldLastCache(t, val)
    end

    return nothing
end

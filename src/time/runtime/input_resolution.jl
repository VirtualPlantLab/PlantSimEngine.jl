"""
    _resolved_value_for_source(sim, source_scope, source_scale, source_process, source_var, source_node_id, t)

Resolve one producer value through hold-last cache lookup.
Returns `(value, found::Bool)`.
"""
function _resolved_value_for_source(sim::GraphSimulation, source_scope::ScopeId, source_scale::Symbol, source_process::Symbol, source_var::Symbol, source_node_id::Int, t::Float64)
    key = OutputKey(source_scope, source_scale, source_node_id, source_process, source_var)
    cache = get(sim.temporal_state.caches, key, nothing)
    if cache isa HoldLastCache
        return cache.v, true
    end
    return nothing, false
end

_resolution_samples(sim::GraphSimulation, key::OutputKey) = get(sim.temporal_state.streams, key, nothing)

"""
    _resolved_windowed_value_for_source(sim, source_scope, source_scale, source_process, source_var, source_node_id, t_start, t_end, policy)

Resolve one producer value over `[t_start, t_end]` for windowed policies.
Returns `(value, found::Bool)`.
"""
function _resolved_windowed_value_for_source(
    sim::GraphSimulation,
    source_scope::ScopeId,
    source_scale::Symbol,
    source_process::Symbol,
    source_var::Symbol,
    source_node_id::Int,
    t_start::Float64,
    t_end::Float64,
    policy::SchedulePolicy
)
    key = OutputKey(source_scope, source_scale, source_node_id, source_process, source_var)
    samples = _resolution_samples(sim, key)
    isnothing(samples) && return nothing, false

    if policy isa Union{Integrate,Aggregate}
        vals_real = Float64[]
        for (ts, v) in samples
            ts < t_start - 1e-8 && continue
            ts > t_end + 1e-8 && continue
            v isa Real || return nothing, false
            push!(vals_real, float(v))
        end
        isempty(vals_real) && return nothing, false
        return _window_reduce(vals_real, policy), true
    end

    return nothing, false
end

"""
    _resolved_interpolated_value_for_source(sim, source_scope, source_scale, source_process, source_var, source_node_id, t, policy)

Resolve one producer value at time `t` using interpolation/extrapolation over
stored temporal samples.
Returns `(value, found::Bool)`.
"""
function _resolved_interpolated_value_for_source(
    sim::GraphSimulation,
    source_scope::ScopeId,
    source_scale::Symbol,
    source_process::Symbol,
    source_var::Symbol,
    source_node_id::Int,
    t::Float64,
    policy::Interpolate
)
    key = OutputKey(source_scope, source_scale, source_node_id, source_process, source_var)
    samples = _resolution_samples(sim, key)
    isnothing(samples) && return nothing, false
    isempty(samples) && return nothing, false

    prev_idx = findlast(s -> s[1] <= t + 1e-8, samples)
    next_idx = findfirst(s -> s[1] >= t - 1e-8, samples)

    # Interpolate between known bracketing points when available.
    if !isnothing(prev_idx) && !isnothing(next_idx)
        t_prev, v_prev = samples[prev_idx]
        t_next, v_next = samples[next_idx]
        if isapprox(t_prev, t_next; atol=1e-8, rtol=0.0)
            return v_prev, true
        end
        if policy.mode == :linear && v_prev isa Real && v_next isa Real
            α = (t - t_prev) / (t_next - t_prev)
            return v_prev + α * (v_next - v_prev), true
        end
        return v_prev, true
    end

    # Real-time fallback when no future sample exists yet:
    # use linear extrapolation from last two samples if possible, else hold-last.
    if !isnothing(prev_idx)
        t_last, v_last = samples[prev_idx]
        if policy.extrapolation == :linear && prev_idx >= 2
            t_prev, v_prev = samples[prev_idx - 1]
            if v_prev isa Real && v_last isa Real && !isapprox(t_last, t_prev; atol=1e-8, rtol=0.0)
                α = (t - t_last) / (t_last - t_prev)
                return v_last + α * (v_last - v_prev), true
            end
        end
        return v_last, true
    end

    # If only future data exists, use the earliest known value.
    return samples[1][2], true
end

function _resolve_window_reducer(reducer)
    if reducer isa DataType
        reducer <: PlantMeteo.AbstractTimeReducer || error(
            "Unsupported reducer type `$(reducer)`. Use a PlantMeteo reducer type/instance or a callable."
        )
        return reducer()
    elseif reducer isa PlantMeteo.AbstractTimeReducer
        return reducer
    elseif reducer isa Function
        return reducer
    end

    error(
        "Unsupported reducer value `$(reducer)` of type `$(typeof(reducer))`. ",
        "Use a PlantMeteo reducer type/instance or a callable."
    )
end

function _window_reduce(vals::AbstractVector{<:Real}, policy::SchedulePolicy)
    reducer = policy isa Integrate ? policy.reducer : (policy isa Aggregate ? policy.reducer : PlantMeteo.SumReducer())
    f = _resolve_window_reducer(reducer)

    applicable(f, vals) || error(
        "Reducer `$(reducer)` is not callable on collected window values for policy `$(typeof(policy))`."
    )

    return f(vals)
end

"""
    _assign_input_value!(st, input_var, value)

Assign an input value into `Status`, preserving in-place updates for `RefVector`
inputs when both sides are vectors.
"""
function _assign_input_value!(st::Status, input_var::Symbol, value)
    current = st[input_var]
    if current isa RefVector && value isa AbstractVector
        length(current) != length(value) && resize!(current, length(value))
        for i in eachindex(value)
            current[i] = value[i]
        end
        return nothing
    end
    st[input_var] = value
    return nothing
end

function _same_scale_status_value(source_statuses, target_node_id::Int, source_var::Symbol)
    for src_st in source_statuses
        node_id(src_st.node) == target_node_id || continue
        source_var in keys(src_st) || continue
        return src_st[source_var], true
    end
    return nothing, false
end

function _ancestor_node_id_for_scale(node, source_scale::Symbol)
    ancestor = parent(node)
    while !isnothing(ancestor)
        if symbol(ancestor) == source_scale
            return node_id(ancestor)
        end
        ancestor = parent(ancestor)
    end
    return nothing
end

function _status_for_node_id(source_statuses, target_node_id::Int)
    for src_st in source_statuses
        node_id(src_st.node) == target_node_id && return src_st
    end
    return nothing
end

"""
    _resolve_input_windowed(sim, node, st, input_var, source_scale, source_process, source_var, t_start, t_end, policy)

Resolve one consumer input from producer temporal streams using a windowed
policy (`Integrate` or `Aggregate`) and write it into `st`.
"""
function _resolve_input_windowed(
    sim::GraphSimulation,
    node::SoftDependencyNode,
    st::Status,
    consumer_scope::ScopeId,
    source_model_spec,
    input_var::Symbol,
    source_scale::Symbol,
    source_process::Symbol,
    source_var::Symbol,
    t_start::Float64,
    t_end::Float64,
    policy::SchedulePolicy
)
    source_statuses = get(status(sim), source_scale, nothing)
    isnothing(source_statuses) && return nothing

    current_value = st[input_var]
    if current_value isa AbstractVector
        vals = Any[]
        for src_st in source_statuses
            src_node_id = node_id(src_st.node)
            source_scope = _scope_for_status(sim, source_model_spec, source_scale, source_process, src_st.node)
            source_scope == consumer_scope || continue
            v, ok = _resolved_windowed_value_for_source(
                sim, source_scope, source_scale, source_process, source_var, src_node_id, t_start, t_end, policy
            )
            if ok
                push!(vals, v)
            elseif policy isa Integrate || policy isa Aggregate
                push!(vals, 0.0)
            elseif source_var in keys(src_st)
                push!(vals, src_st[source_var])
            end
        end
        length(vals) > 0 && _assign_input_value!(st, input_var, vals)
        return nothing
    end

    consumer_node_id = node_id(st.node)
    v, ok = _resolved_windowed_value_for_source(
        sim, consumer_scope, source_scale, source_process, source_var, consumer_node_id, t_start, t_end, policy
    )
    if ok
        _assign_input_value!(st, input_var, v)
        return nothing
    end

    # Same-scale scalar fallback: prefer the value attached to the consumer node
    # before scanning all source nodes (which can be ambiguous in dense scales).
    if source_scale == node.scale
        vv, found = _same_scale_status_value(source_statuses, consumer_node_id, source_var)
        if found
            _assign_input_value!(st, input_var, vv)
            return nothing
        end
    else
        ancestor_node_id = _ancestor_node_id_for_scale(st.node, source_scale)
        if !isnothing(ancestor_node_id)
            src_st = _status_for_node_id(source_statuses, ancestor_node_id)
            if !isnothing(src_st)
                source_scope = _scope_for_status(sim, source_model_spec, source_scale, source_process, src_st.node)
                if source_scope == consumer_scope
                    vv, found = _resolved_windowed_value_for_source(
                        sim, source_scope, source_scale, source_process, source_var, ancestor_node_id, t_start, t_end, policy
                    )
                    if found
                        _assign_input_value!(st, input_var, vv)
                        return nothing
                    elseif source_var in keys(src_st)
                        _assign_input_value!(st, input_var, src_st[source_var])
                        return nothing
                    end
                end
            end
        end
    end

    # Cross-scale scalar fallback: allow unique producer value at source scale.
    candidates = Any[]
    for src_st in source_statuses
        src_node_id = node_id(src_st.node)
        source_scope = _scope_for_status(sim, source_model_spec, source_scale, source_process, src_st.node)
        source_scope == consumer_scope || continue
        vv, found = _resolved_windowed_value_for_source(
            sim, source_scope, source_scale, source_process, source_var, src_node_id, t_start, t_end, policy
        )
        found && push!(candidates, vv)
    end
    if length(candidates) == 1
        _assign_input_value!(st, input_var, only(candidates))
    elseif length(candidates) > 1
        error(
            "Ambiguous cross-scale source values for input `$(input_var)` in process `$(node.process)` at scale `$(node.scale)`. ",
            "Please provide `InputBindings(...)` with explicit `scale`/source disambiguation."
        )
    elseif policy isa Integrate || policy isa Aggregate
        _assign_input_value!(st, input_var, 0.0)
    end

    return nothing
end

"""
    _resolve_input_interpolate(sim, node, st, input_var, source_scale, source_process, source_var, t, policy)

Resolve one consumer input from producer temporal streams using interpolation
policy and write it into `st`.
"""
function _resolve_input_interpolate(
    sim::GraphSimulation,
    node::SoftDependencyNode,
    st::Status,
    consumer_scope::ScopeId,
    source_model_spec,
    input_var::Symbol,
    source_scale::Symbol,
    source_process::Symbol,
    source_var::Symbol,
    t::Float64,
    policy::Interpolate
)
    source_statuses = get(status(sim), source_scale, nothing)
    isnothing(source_statuses) && return nothing

    current_value = st[input_var]
    if current_value isa AbstractVector
        vals = Any[]
        for src_st in source_statuses
            src_node_id = node_id(src_st.node)
            source_scope = _scope_for_status(sim, source_model_spec, source_scale, source_process, src_st.node)
            source_scope == consumer_scope || continue
            v, ok = _resolved_interpolated_value_for_source(
                sim, source_scope, source_scale, source_process, source_var, src_node_id, t, policy
            )
            if ok
                push!(vals, v)
            elseif source_var in keys(src_st)
                push!(vals, src_st[source_var])
            end
        end
        length(vals) > 0 && _assign_input_value!(st, input_var, vals)
        return nothing
    end

    consumer_node_id = node_id(st.node)
    v, ok = _resolved_interpolated_value_for_source(
        sim, consumer_scope, source_scale, source_process, source_var, consumer_node_id, t, policy
    )
    if ok
        _assign_input_value!(st, input_var, v)
        return nothing
    end

    # Cross-scale scalar fallback: allow unique producer value at source scale.
    candidates = Any[]
    for src_st in source_statuses
        src_node_id = node_id(src_st.node)
        source_scope = _scope_for_status(sim, source_model_spec, source_scale, source_process, src_st.node)
        source_scope == consumer_scope || continue
        vv, found = _resolved_interpolated_value_for_source(
            sim, source_scope, source_scale, source_process, source_var, src_node_id, t, policy
        )
        found && push!(candidates, vv)
    end
    if length(candidates) == 1
        _assign_input_value!(st, input_var, only(candidates))
    elseif length(candidates) > 1
        error(
            "Ambiguous cross-scale source values for input `$(input_var)` in process `$(node.process)` at scale `$(node.scale)`. ",
            "Please provide `InputBindings(...)` with explicit `scale`/source disambiguation."
        )
    end

    return nothing
end

"""
    _resolve_input_holdlast(sim, node, st, input_var, source_scale, source_process, source_var, t)

Resolve one consumer input from producer hold-last values and write it into
`st`.
"""
function _resolve_input_holdlast(
    sim::GraphSimulation,
    node::SoftDependencyNode,
    st::Status,
    consumer_scope::ScopeId,
    source_model_spec,
    input_var::Symbol,
    source_scale::Symbol,
    source_process::Symbol,
    source_var::Symbol,
    t::Float64
)
    source_statuses = get(status(sim), source_scale, nothing)
    isnothing(source_statuses) && return nothing

    current_value = st[input_var]
    if current_value isa AbstractVector
        vals = Any[]
        for src_st in source_statuses
            src_node_id = node_id(src_st.node)
            source_scope = _scope_for_status(sim, source_model_spec, source_scale, source_process, src_st.node)
            source_scope == consumer_scope || continue
            v, ok = _resolved_value_for_source(sim, source_scope, source_scale, source_process, source_var, src_node_id, t)
            if ok
                push!(vals, v)
            else
                if source_var in keys(src_st)
                    push!(vals, src_st[source_var])
                end
            end
        end
        length(vals) > 0 && _assign_input_value!(st, input_var, vals)
        return nothing
    end

    consumer_node_id = node_id(st.node)
    v, ok = _resolved_value_for_source(sim, consumer_scope, source_scale, source_process, source_var, consumer_node_id, t)
    if ok
        _assign_input_value!(st, input_var, v)
        return nothing
    end

    # Same-scale scalar fallback: prefer the value attached to the consumer node
    # before scanning all source nodes (which can be ambiguous in dense scales).
    if source_scale == node.scale
        vv, found = _same_scale_status_value(source_statuses, consumer_node_id, source_var)
        if found
            _assign_input_value!(st, input_var, vv)
            return nothing
        end
    else
        ancestor_node_id = _ancestor_node_id_for_scale(st.node, source_scale)
        if !isnothing(ancestor_node_id)
            src_st = _status_for_node_id(source_statuses, ancestor_node_id)
            if !isnothing(src_st)
                source_scope = _scope_for_status(sim, source_model_spec, source_scale, source_process, src_st.node)
                if source_scope == consumer_scope
                    vv, found = _resolved_value_for_source(sim, source_scope, source_scale, source_process, source_var, ancestor_node_id, t)
                    if found
                        _assign_input_value!(st, input_var, vv)
                        return nothing
                    elseif source_var in keys(src_st)
                        _assign_input_value!(st, input_var, src_st[source_var])
                        return nothing
                    end
                end
            end
        end
    end

    # Cross-scale scalar fallback: allow unique producer value at source scale.
    candidates = Any[]
    for src_st in source_statuses
        src_node_id = node_id(src_st.node)
        source_scope = _scope_for_status(sim, source_model_spec, source_scale, source_process, src_st.node)
        source_scope == consumer_scope || continue
        vv, found = _resolved_value_for_source(sim, source_scope, source_scale, source_process, source_var, src_node_id, t)
        found && push!(candidates, vv)
    end
    if length(candidates) == 1
        _assign_input_value!(st, input_var, only(candidates))
    elseif length(candidates) > 1
        error(
            "Ambiguous cross-scale source values for input `$(input_var)` in process `$(node.process)` at scale `$(node.scale)`. ",
            "Please provide `InputBindings(...)` with explicit `scale`/source disambiguation."
        )
    end

    return nothing
end

"""
    resolve_inputs_from_temporal_state!(sim, node, st, t, model_spec, timeline)

Resolve all model inputs for `node` at time `t` using declared
`InputBindings(...)` and schedule policies, then mutate `st` in place.
"""
function resolve_inputs_from_temporal_state!(sim::GraphSimulation, node::SoftDependencyNode, st::Status, t::Float64, model_spec, timeline::TimelineContext)
    model = node.value
    ins = keys(inputs_(model))
    length(ins) == 0 && return nothing
    consumer_clock = _model_clock(model_spec, model, timeline)
    t_start = _window_start_for_clock(consumer_clock, t)
    consumer_scope = _scope_for_status(sim, model_spec, node.scale, node.process, st.node)

    bindings = input_bindings(model_spec)

    for input_var in ins
        binding = input_var in keys(bindings) ? _parse_input_binding(bindings[input_var]) : nothing

        source_process = nothing
        source_var = input_var
        policy = HoldLast()
        policy_is_explicit = false

        if !isnothing(binding) && !isnothing(binding.process)
            source_process = binding.process
            source_var = isnothing(binding.var) ? input_var : binding.var
            source_scale = isnothing(binding.scale) ? _source_scale_for_process(node, source_process) : binding.scale
            policy = binding.policy
            policy_is_explicit = true
        else
            candidates = _candidate_producers(node, input_var)
            if length(candidates) == 1
                source_process, source_var = only(candidates)
                source_scale = _source_scale_for_process(node, source_process)
            elseif length(candidates) > 1
                error(
                    "Ambiguous producer for input `$(input_var)` in process `$(node.process)` at scale `$(node.scale)`. ",
                    "Please define explicit `InputBindings(...)` for this model in your mapping."
                )
            else
                continue
            end
        end
        source_model_spec = _model_spec_for_process(sim, source_scale, source_process)
        if !policy_is_explicit
            policy = _policy_for_output(model_(source_model_spec), source_var)
        end

        if policy isa HoldLast
            _resolve_input_holdlast(sim, node, st, consumer_scope, source_model_spec, input_var, source_scale, source_process, source_var, t)
        elseif policy isa Interpolate
            _resolve_input_interpolate(sim, node, st, consumer_scope, source_model_spec, input_var, source_scale, source_process, source_var, t, policy)
        elseif policy isa Integrate || policy isa Aggregate
            _resolve_input_windowed(sim, node, st, consumer_scope, source_model_spec, input_var, source_scale, source_process, source_var, t_start, t, policy)
        end
    end

    return nothing
end

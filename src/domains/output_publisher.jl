function _publish_domain_model_outputs!(
    simulation::DomainSimulation,
    domain::Domain,
    node::AbstractDependencyNode,
    status,
    step::Int
)
    key = DomainModelKey(domain.name, node.scale, node.process)
    haskey(simulation.model_specs, key) || return nothing
    spec = simulation.model_specs[key]
    for out_var in keys(outputs_(spec))
        stream_key = (key, out_var)
        value = status[out_var]
        push!(get!(simulation.streams, stream_key, Pair{Int,Any}[]), step => value)
        push!(get!(simulation.outputs, stream_key, Any[]), value)
    end
    return nothing
end

function _publish_domain_hard_dependency_outputs!(
    simulation::DomainSimulation,
    domain::Domain,
    node::HardDependencyNode,
    status,
    step::Int
)
    _publish_domain_model_outputs!(simulation, domain, node, status, step)
    for child in node.children
        _publish_domain_hard_dependency_outputs!(simulation, domain, child, status, step)
    end
    return nothing
end

function _publish_graph_domain_step_outputs!(
    simulation::DomainSimulation,
    domain::Domain,
    graph_state::DomainGraphState,
    step::Int;
    effective_multirate::Bool=false,
    phase::Symbol=:normal,
)
    graph_statuses = status(graph_state)
    for (key, spec) in simulation.model_specs
        key.domain == domain.name || continue
        _should_publish_domain_key(simulation, domain, key; phase=phase) || continue
        if effective_multirate
            clock = simulation.model_clocks[key]
            _should_run_at_time(clock, float(step)) || continue
        end
        haskey(graph_statuses, key.scale) || continue
        for out_var in keys(outputs_(spec))
            stream_key = (key, out_var)
            ids = Int[]
            values = Any[]
            for st in graph_statuses[key.scale]
                out_var in propertynames(st) || continue
                push!(ids, node_id(st.node))
                push!(values, st[out_var])
            end
            push!(get!(simulation.streams, stream_key, Pair{Int,Any}[]), step => DomainNodeValues(ids, values))
            push!(get!(simulation.outputs, stream_key, Any[]), values)
        end
    end
    return nothing
end

function _publish_graph_target!(target::ModelTarget)
    spec = target.simulation.model_specs[target.key]
    domain = _domain_for_name(target.simulation.mapping, target.key.domain)
    t = _time_from_step(target.step, target.simulation.timeline)
    _scatter_graph_domain_environment_outputs!(target.simulation, domain, target.node, spec, target.status, t)
    for hard_child in target.node.hard_dependency
        _scatter_graph_domain_hard_dependency_environment_outputs!(target.simulation, domain, hard_child, target.status, t)
    end
    for out_var in keys(outputs_(spec))
        out_var in propertynames(target.status) || continue
        stream_key = (target.key, out_var)
        value = target.status[out_var]
        push!(get!(target.simulation.streams, stream_key, Pair{Int,Any}[]), target.step => value)
        push!(get!(target.simulation.outputs, stream_key, Any[]), value)
    end
    for hard_child in target.node.hard_dependency
        _publish_domain_hard_dependency_outputs!(target.simulation, domain, hard_child, target.status, target.step)
    end
    return nothing
end

function _publish_target!(target::ModelTarget)
    isnothing(target.simulation) && error(
        "`publish=true` requires a target created by `dependency_targets(extra, name)` in a domain simulation."
    )
    target.extra isa GraphSimulation && return _publish_graph_target!(target)
    domain = _domain_for_name(target.simulation.mapping, target.key.domain)
    spec = target.simulation.model_specs[target.key]
    _scatter_domain_environment_outputs!(target.simulation, domain, target.node, spec, target.status, target.step)
    for hard_child in target.node.hard_dependency
        _scatter_domain_hard_dependency_environment_outputs!(target.simulation, domain, hard_child, target.status, target.step)
    end
    _publish_domain_model_outputs!(target.simulation, domain, target.node, target.status, target.step)
    for hard_child in target.node.hard_dependency
        _publish_domain_hard_dependency_outputs!(target.simulation, domain, hard_child, target.status, target.step)
    end
    return nothing
end

function _domain_order_edges(mapping::SimulationMapping, route_bindings=nothing)
    edges = Dict(domain.name => Set{Symbol}() for domain in mapping.domains)
    non_scene_domains = [domain.name for domain in mapping.domains if domain.kind != :scene]
    scene_domains = [domain.name for domain in mapping.domains if domain.kind == :scene]
    for source in non_scene_domains, target in scene_domains
        source == target || push!(edges[source], target)
    end

    if !isnothing(route_bindings)
        for (i, route) in enumerate(mapping.routes)
            target = route.to.domain
            for producer in route_bindings[i]
                producer.domain == target && continue
                push!(edges[producer.domain], target)
            end
        end
    end

    return edges
end

function _domain_run_order(mapping::SimulationMapping, route_bindings=nothing)
    domains_by_name = Dict(domain.name => domain for domain in mapping.domains)
    declaration_index = Dict(domain.name => i for (i, domain) in enumerate(mapping.domains))
    edges = _domain_order_edges(mapping, route_bindings)
    indegree = Dict(domain.name => 0 for domain in mapping.domains)
    for targets in values(edges), target in targets
        indegree[target] = get(indegree, target, 0) + 1
    end

    ready = sort!(
        [name for (name, degree) in indegree if degree == 0];
        by=name -> declaration_index[name],
    )
    ordered = Symbol[]
    while !isempty(ready)
        current = popfirst!(ready)
        push!(ordered, current)
        for target in sort!(collect(edges[current]); by=name -> declaration_index[name])
            indegree[target] -= 1
            if indegree[target] == 0
                push!(ready, target)
                sort!(ready; by=name -> declaration_index[name])
            end
        end
    end

    if length(ordered) != length(mapping.domains)
        cyclic = sort!(
            [name for (name, degree) in indegree if degree > 0];
            by=name -> declaration_index[name],
        )
        error(
            "Cyclic domain run-order constraints detected among domains: ",
            join((":" * string(name) for name in cyclic), ", "),
            ". Check route sources/targets and `kind=:scene` phase constraints."
        )
    end

    return [domains_by_name[name] for name in ordered]
end

function _domain_run_order(simulation::DomainSimulation)
    return _domain_run_order(simulation.mapping, simulation.route_bindings)
end

function _domain_node_due(simulation::DomainSimulation, domain::Domain, node::SoftDependencyNode, step::Int)
    key = DomainModelKey(domain.name, node.scale, node.process)
    clock = simulation.model_clocks[key]
    return _should_run_at_time(clock, float(step))
end

function _hard_domain_dependency_keys(simulation::DomainSimulation)
    keys = Set{DomainModelKey}()
    for producers in values(simulation.hard_domain_dependency_bindings)
        union!(keys, producers)
    end
    return keys
end

function _is_hard_domain_dependency(simulation::DomainSimulation, key::DomainModelKey)
    key in _hard_domain_dependency_keys(simulation)
end

function _has_hard_domain_parent(simulation::DomainSimulation, domain::Domain, node::SoftDependencyNode)
    AbstractTrees.isroot(node) && return false
    hard_keys = _hard_domain_dependency_keys(simulation)
    for parent in node.parent
        parent_key = DomainModelKey(domain.name, parent.scale, parent.process)
        parent_key in hard_keys && return true
    end
    return false
end

function _phase_allows_hard_parent(phase::Symbol, has_hard_parent::Bool)
    phase == :normal && return !has_hard_parent
    phase == :post_scene && return has_hard_parent
    error("Unknown domain scheduling phase `$(phase)`.")
end

function _should_visit_domain_node(
    simulation::DomainSimulation,
    domain::Domain,
    node::SoftDependencyNode;
    phase::Symbol,
)
    key = DomainModelKey(domain.name, node.scale, node.process)
    _is_hard_domain_dependency(simulation, key) && return false
    has_hard_parent = _has_hard_domain_parent(simulation, domain, node)
    return _phase_allows_hard_parent(phase, has_hard_parent)
end

function _has_hard_domain_parent(simulation::DomainSimulation, domain::Domain, key::DomainModelKey)
    node = try
        _find_dependency_node(simulation.dependency_graphs[domain.name], key)
    catch
        return false
    end
    return _has_hard_domain_parent(simulation, domain, node)
end

function _has_domain_soft_node(simulation::DomainSimulation, domain::Domain, key::DomainModelKey)
    try
        _find_dependency_node(simulation.dependency_graphs[domain.name], key)
        return true
    catch
        return false
    end
end

function _should_publish_domain_key(
    simulation::DomainSimulation,
    domain::Domain,
    key::DomainModelKey;
    phase::Symbol,
)
    _has_domain_soft_node(simulation, domain, key) || return false
    _is_hard_domain_dependency(simulation, key) && return false
    has_hard_parent = _has_hard_domain_parent(simulation, domain, key)
    return _phase_allows_hard_parent(phase, has_hard_parent)
end

function _domain_has_post_scene_work(simulation::DomainSimulation, domain::Domain)
    for key in keys(simulation.model_specs)
        key.domain == domain.name || continue
        _is_hard_domain_dependency(simulation, key) && continue
        _has_hard_domain_parent(simulation, domain, key) && return true
    end
    return false
end

function _domain_parents_ready(
    simulation::DomainSimulation,
    domain::Domain,
    node::SoftDependencyNode,
    step::Int,
    ran::Set{DomainModelKey}
)
    AbstractTrees.isroot(node) && return true
    for parent in node.parent
        _domain_node_due(simulation, domain, parent, step) || continue
        parent_key = DomainModelKey(domain.name, parent.scale, parent.process)
        _is_hard_domain_dependency(simulation, parent_key) && continue
        parent_key in ran || return false
    end
    return true
end

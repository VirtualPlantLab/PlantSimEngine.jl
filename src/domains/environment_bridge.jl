function _domain_environment_entities(simulation::DomainSimulation, domain::Domain)
    state = get(simulation.domain_states, domain.name, nothing)
    entities = NamedTuple[]
    if state isa DomainGraphState
        for (scale, statuses_at_scale) in status(state)
            push!(entities, (
                domain=domain.name,
                kind=domain.kind,
                scale=scale,
                statuses=statuses_at_scale,
                state=state,
            ))
        end
    elseif state isa ModelMapping{SingleScale}
        push!(entities, (
            domain=domain.name,
            kind=domain.kind,
            scale=:Default,
            statuses=Status[status(state)],
            state=state,
        ))
    end
    return entities
end

function _update_domain_environment_index!(simulation::DomainSimulation, domain::Domain)
    return update_index!(simulation.environment, _domain_environment_entities(simulation, domain))
end

_domain_environment_support(domain::Domain, node::AbstractDependencyNode, status) =
    EnvironmentSupport(domain.name, node.scale, node.process, status)

_domain_environment_support(key::DomainModelKey, status) =
    EnvironmentSupport(key.domain, key.scale, key.process, status)

function _sample_domain_environment_at_time(simulation::DomainSimulation, support::EnvironmentSupport, t, model_spec::ModelSpec)
    return sample_environment(simulation.environment, support, t, model_spec)
end

function _sample_domain_environment_at_step(simulation::DomainSimulation, support::EnvironmentSupport, step::Int, model_spec::ModelSpec)
    t = _time_from_step(step, simulation.timeline)
    return _sample_domain_environment_at_time(simulation, support, t, model_spec)
end

function _dependency_target_meteo(simulation::DomainSimulation, key::DomainModelKey, st, step::Int)
    spec = simulation.model_specs[key]
    support = _domain_environment_support(key, st)
    return _sample_domain_environment_at_step(simulation, support, step, spec)
end

function _domain_environment_for_model(
    simulation::DomainSimulation,
    domain::Domain,
    node::SoftDependencyNode,
    model_spec::ModelSpec,
    status,
    step::Int
)
    support = _domain_environment_support(domain, node, status)
    return _sample_domain_environment_at_step(simulation, support, step, model_spec)
end

function _scatter_domain_environment_outputs_at_time!(
    simulation::DomainSimulation,
    domain::Domain,
    node::AbstractDependencyNode,
    model_spec::ModelSpec,
    status,
    t
)
    isempty(keys(meteo_outputs_(model_spec))) && return nothing
    support = _domain_environment_support(domain, node, status)
    return scatter_environment_outputs!(simulation.environment, support, t, model_spec, status)
end

function _scatter_domain_environment_outputs!(
    simulation::DomainSimulation,
    domain::Domain,
    node::AbstractDependencyNode,
    model_spec::ModelSpec,
    status,
    step::Int
)
    t = _time_from_step(step, simulation.timeline)
    return _scatter_domain_environment_outputs_at_time!(simulation, domain, node, model_spec, status, t)
end

function _scatter_domain_hard_dependency_environment_outputs_at_time!(
    simulation::DomainSimulation,
    domain::Domain,
    node::HardDependencyNode,
    status,
    t
)
    key = DomainModelKey(domain.name, node.scale, node.process)
    if haskey(simulation.model_specs, key)
        spec = simulation.model_specs[key]
        _scatter_domain_environment_outputs_at_time!(simulation, domain, node, spec, status, t)
    end
    for child in node.children
        _scatter_domain_hard_dependency_environment_outputs_at_time!(simulation, domain, child, status, t)
    end
    return nothing
end

function _scatter_domain_hard_dependency_environment_outputs!(
    simulation::DomainSimulation,
    domain::Domain,
    node::HardDependencyNode,
    status,
    step::Int
)
    t = _time_from_step(step, simulation.timeline)
    return _scatter_domain_hard_dependency_environment_outputs_at_time!(simulation, domain, node, status, t)
end

function _raw_meteo_for_staged_graph_domains(environment::GlobalConstant)
    return environment_meteo(environment)
end

function _raw_meteo_for_staged_graph_domains(environment::AbstractEnvironmentBackend)
    return environment
end

function _graph_domain_environment_for_model(
    simulation::DomainSimulation,
    domain::Domain,
    node::SoftDependencyNode,
    status,
    t,
    model_clock::ClockSpec,
    model_spec::ModelSpec,
    meteo,
    meteo_sampler,
    multirate::Bool
)
    if simulation.environment isa GlobalConstant
        return multirate ? _sample_meteo_for_model(meteo_sampler, meteo, round(Int, t), model_clock, model_spec) : meteo
    end
    support = _domain_environment_support(domain, node, status)
    return _sample_domain_environment_at_time(simulation, support, t, model_spec)
end

function _meteo_for_graph_step(meteo, step::Int, nsteps::Int)
    return _meteo_row_at_step(meteo, step)
end

function _meteo_for_graph_step(backend::AbstractEnvironmentBackend, step::Int, nsteps::Int)
    return backend
end

function _scatter_graph_domain_environment_outputs!(
    simulation::DomainSimulation,
    domain::Domain,
    node::AbstractDependencyNode,
    model_spec::ModelSpec,
    status,
    t
)
    return _scatter_domain_environment_outputs_at_time!(simulation, domain, node, model_spec, status, t)
end

function _scatter_graph_domain_hard_dependency_environment_outputs!(
    simulation::DomainSimulation,
    domain::Domain,
    node::HardDependencyNode,
    status,
    t
)
    return _scatter_domain_hard_dependency_environment_outputs_at_time!(simulation, domain, node, status, t)
end

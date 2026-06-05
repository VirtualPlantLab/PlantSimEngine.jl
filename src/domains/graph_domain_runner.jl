function _prepare_graph_domain_runtime!(
    simulation::DomainSimulation,
    domain::Domain,
    object,
    meteo,
    constants,
    nsteps::Int;
    check=true,
    executor=SequentialEx(),
    type_promotion=_type_promotion(_domain_mapping(domain)),
)
    roots = _domain_graph_roots(object, domain)
    graph_simulations = GraphSimulation[]
    for root in roots
        _materialize_graph_route_attributes_for_domain!(simulation, domain, root, 1)
        push!(
            graph_simulations,
            GraphSimulation(
                root,
                _domain_mapping(domain);
                nsteps=nsteps,
                check=check,
                outputs=nothing,
                type_promotion=type_promotion,
            ),
        )
    end
    graph_state = DomainGraphState(graph_simulations)
    simulation.domain_states[domain.name] = graph_state
    representative_simulation = first(graph_simulations)
    effective_multirate = _effective_multirate(representative_simulation)
    dep_graph = dep(representative_simulation)
    timeline = _timeline_context(meteo)
    meteo_sampler = effective_multirate ? _prepare_meteo_sampler(meteo) : nothing
    runtime_clock_rows = _runtime_clock_rows(representative_simulation, timeline, dep_graph)
    effective_executor = executor
    validate_meteo_inputs(get_model_specs(representative_simulation), meteo)
    _validate_meteo_derived_timestep_requirements!(runtime_clock_rows, timeline)
    if effective_multirate
        if executor != SequentialEx()
            @warn string(
                "Multi-rate MTG domain `$(domain.name)` currently executes sequentially. ",
                "Provided `executor=$(executor)` is ignored in this mode. ",
                "Use `executor=SequentialEx()` to silence this warning."
            ) maxlog = 1
            effective_executor = SequentialEx()
        end
        _warn_if_no_model_runs_at_base_timestep(runtime_clock_rows, timeline)
        for graph_simulation in graph_simulations
            validate_canonical_publishers(graph_simulation)
            configure_temporal_buffers!(graph_simulation, timeline)
        end
    end
    return DomainGraphRuntime(graph_state, meteo, constants, effective_multirate, timeline, meteo_sampler, effective_executor)
end

function _run_graph_domain_step!(
    simulation::DomainSimulation,
    domain::Domain,
    runtime::DomainGraphRuntime,
    step::Int,
    nsteps::Int;
    check=true,
    phase::Symbol=:normal,
)
    meteo_i = _meteo_for_graph_step(runtime.meteo, step, nsteps)
    meteo_provider = (node, status, i, t, model_clock, model_spec, meteo, meteo_sampler, multirate) ->
        _graph_domain_environment_for_model(
            simulation,
            domain,
            node,
            status,
            t,
            model_clock,
            model_spec,
            meteo,
            meteo_sampler,
            multirate,
        )
    after_model_run = (node, model_spec, status, i, t) -> begin
        _scatter_graph_domain_environment_outputs!(simulation, domain, node, model_spec, status, t)
        for hard_child in node.hard_dependency
            _scatter_graph_domain_hard_dependency_environment_outputs!(simulation, domain, hard_child, status, t)
        end
        nothing
    end
    skip_model_run = node -> !_should_visit_domain_node(simulation, domain, node; phase=phase)
    for graph_simulation in runtime.state.simulations
        _materialize_graph_routes_for_domain!(simulation, domain, graph_simulation, step)
        roots = collect(dep(graph_simulation).roots)
        models = get_models(graph_simulation)
        for (_, dependency_node) in roots
            run_node_multiscale!(
                graph_simulation,
                dependency_node,
                step,
                models,
                meteo_i,
                runtime.constants,
                graph_simulation,
                check,
                runtime.executor,
                runtime.effective_multirate,
                runtime.timeline,
                runtime.meteo_sampler;
                meteo_provider=meteo_provider,
                after_model_run=after_model_run,
                skip_model_run=skip_model_run,
            )
        end
        if phase == :normal
            runtime.effective_multirate && update_requested_outputs!(graph_simulation, _time_from_step(step, runtime.timeline))
            save_results!(graph_simulation, step)
        end
    end
    _publish_graph_domain_step_outputs!(
        simulation,
        domain,
        runtime.state,
        step;
        effective_multirate=runtime.effective_multirate,
        phase=phase,
    )
    _update_domain_environment_index!(simulation, domain)
    return runtime.state
end

function _finalize_graph_domain_runtime!(runtime::DomainGraphRuntime)
    for graph_simulation in runtime.state.simulations
        for (organ, index) in graph_simulation.outputs_index
            resize!(outputs(graph_simulation)[organ], index - 1)
        end
    end
    return runtime.state
end

function _run_single_status_domain_simulation!(
    simulation::DomainSimulation,
    constants,
    nsteps::Int
)
    run_order = _domain_run_order(simulation)
    for i in 1:nsteps
        for domain in run_order
            _materialize_routes_for_domain!(simulation, domain, i)
            _run_domain_models!(simulation, domain, constants, i)
            _update_domain_environment_index!(simulation, domain)
        end
        for domain in run_order
            domain.kind == :scene && continue
            _domain_has_post_scene_work(simulation, domain) || continue
            _materialize_routes_for_domain!(simulation, domain, i)
            _run_domain_models!(simulation, domain, constants, i; phase=:post_scene)
            _update_domain_environment_index!(simulation, domain)
        end
    end
    return simulation
end

function _run_staged_graph_domain_simulation!(
    simulation::DomainSimulation,
    object,
    raw_meteo,
    constants,
    nsteps::Int;
    check=true,
    executor=SequentialEx(),
    type_promotion=nothing,
)
    run_order = _domain_run_order(simulation)
    graph_runtimes = Dict{Symbol,DomainGraphRuntime}()

    for step in 1:nsteps
        for scene_phase in (false, true)
            for domain in run_order
                (domain.kind == :scene) == scene_phase || continue
                if _is_graph_domain(domain)
                    domain.kind == :scene && error(
                        "Scene domain `$(domain.name)` is MTG-backed. The MTG-domain runner currently supports ",
                        "single-status scene domains only."
                    )
                    runtime = get(graph_runtimes, domain.name, nothing)
                    if isnothing(runtime)
                        domain_type_promotion = isnothing(type_promotion) ? _type_promotion(_domain_mapping(domain)) : type_promotion
                        runtime = _prepare_graph_domain_runtime!(
                            simulation,
                            domain,
                            object,
                            raw_meteo,
                            constants,
                            nsteps;
                            check=check,
                            executor=executor,
                            type_promotion=domain_type_promotion,
                        )
                        graph_runtimes[domain.name] = runtime
                    end
                    _run_graph_domain_step!(simulation, domain, runtime, step, nsteps; check=check)
                else
                    _materialize_routes_for_domain!(simulation, domain, step)
                    _run_domain_models!(simulation, domain, constants, step)
                    _update_domain_environment_index!(simulation, domain)
                end
            end
        end
        for domain in run_order
            domain.kind == :scene && continue
            _domain_has_post_scene_work(simulation, domain) || continue
            if _is_graph_domain(domain)
                runtime = graph_runtimes[domain.name]
                _run_graph_domain_step!(simulation, domain, runtime, step, nsteps; check=check, phase=:post_scene)
            else
                _materialize_routes_for_domain!(simulation, domain, step)
                _run_domain_models!(simulation, domain, constants, step; phase=:post_scene)
                _update_domain_environment_index!(simulation, domain)
            end
        end
    end

    for runtime in values(graph_runtimes)
        _finalize_graph_domain_runtime!(runtime)
    end

    return simulation
end

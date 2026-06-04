function _resolve_selector_matches(
    mapping::SimulationMapping,
    specs::Dict{DomainModelKey,ModelSpec},
    selector::Union{AllDomains,HardDomains};
    context::String,
)
    resolved = DomainModelKey[]
    keys_by_domain = _keys_by_domain(specs)
    for domain in mapping.domains
        for producer_key in get(keys_by_domain, domain.name, DomainModelKey[])
            producer_spec = specs[producer_key]
            _matches(selector, domain, producer_key, producer_spec) && push!(resolved, producer_key)
        end
    end
    isempty(resolved) && error(
        _selector_match_error(mapping, specs, selector; context=context)
    )
    return resolved
end

function _resolve_route_bindings(mapping::SimulationMapping, specs::Dict{DomainModelKey,ModelSpec})
    bindings = Vector{DomainModelKey}[]
    for (i, route) in enumerate(mapping.routes)
        push!(
            bindings,
            _resolve_selector_matches(
                mapping,
                specs,
                route.from;
                context="Route $(i) from `$(route.from)`",
            ),
        )
    end
    return bindings
end

function _route_target_input_default(route::Route, specs::Dict{DomainModelKey,ModelSpec})
    consumer_key = _route_target_consumer_key(route, specs)
    isnothing(consumer_key) && return nothing
    consumer_inputs = inputs_(specs[consumer_key])
    target_var = route.to.var
    target_var in keys(consumer_inputs) || return nothing
    return getproperty(consumer_inputs, target_var)
end

function _route_target_status_defaults(mapping::SimulationMapping, domain::Domain, specs::Dict{DomainModelKey,ModelSpec})
    defaults = NamedTuple()
    target_mapping = _domain_mapping(domain)
    target_mapping isa ModelMapping{SingleScale} || return defaults
    target_status = status(target_mapping)

    for route in mapping.routes
        target = route.to
        target.domain == domain.name || continue
        target.scale == :Default || continue
        target.var in propertynames(target_status) && continue
        target.var in keys(defaults) && continue

        default = _route_target_input_default(route, specs)
        isnothing(default) && continue
        defaults = merge(defaults, NamedTuple{(target.var,)}((default,)))
    end

    return defaults
end

function _add_route_target_status_defaults(mapping::SimulationMapping, specs::Dict{DomainModelKey,ModelSpec})
    domains = Domain[]
    changed = false

    for domain in mapping.domains
        target_mapping = _domain_mapping(domain)
        defaults = _route_target_status_defaults(mapping, domain, specs)
        if target_mapping isa ModelMapping{SingleScale} && !isempty(keys(defaults))
            augmented_status = Status(merge(defaults, NamedTuple(status(target_mapping))))
            target_mapping = copy(target_mapping, augmented_status)
            changed = true
        end
        push!(domains, Domain(domain.name, domain.kind, target_mapping, domain.selector))
    end

    changed || return mapping
    return SimulationMapping(domains...; routes=mapping.routes)
end

function _route_target_consumer_key(route::Route, specs::Dict{DomainModelKey,ModelSpec})
    target = route.to
    if !isnothing(target.process)
        key = DomainModelKey(target.domain, target.scale, target.process)
        haskey(specs, key) || error(
            "Route target process `$(key)` does not exist."
        )
        target.var in keys(inputs_(specs[key])) || error(
            "Route target process `$(key)` does not consume variable `$(target.var)`. ",
            "Use a process that declares `$(target.var)` in `inputs_`, or omit `process=...` ",
            "if the route should only materialize a domain status variable."
        )
        return key
    end

    consumers = DomainModelKey[]
    for (key, spec) in specs
        key.domain == target.domain || continue
        key.scale == target.scale || continue
        target.var in keys(inputs_(spec)) || continue
        push!(consumers, key)
    end

    isempty(consumers) && return nothing
    length(consumers) == 1 || error(
        "Route target `$(target.domain)/$(target.scale)/$(target.var)` is consumed by several models: ",
        join(consumers, ", "),
        ". Specify `process=...` in `DomainRouteTarget` so the route clock is unambiguous."
    )
    return only(consumers)
end

function _validate_route_targets(mapping::SimulationMapping, routes::Vector{Route}, specs::Dict{DomainModelKey,ModelSpec}; staged_graph_domains=false)
    for (i, route) in enumerate(routes)
        target = route.to
        domain = _domain_for_name(mapping, target.domain)
        target_mapping = _domain_mapping(domain)
        if target_mapping isa ModelMapping{MultiScale}
            staged_graph_domains || error(
                "Route $(i) targets MTG-backed domain `$(target.domain)`, but this runner only supports single-status domains."
            )
            route.cardinality isa OneToManyBroadcast || error(
                "Route $(i) targets MTG-backed domain `$(target.domain)`. ",
                "The MTG-domain runner only supports `OneToManyBroadcast()` routes into graph domains."
            )
            target.scale == :Default && error(
                "Route $(i) targets MTG-backed domain `$(target.domain)` but uses `scale=:Default`. ",
                "Specify the target graph scale, for example `scale=:Leaf`."
            )
            isnothing(_route_target_consumer_key(route, specs)) && error(
                "Route $(i) targets graph variable `$(target.var)` in `$(target.domain)/$(target.scale)`, ",
                "but no target process consumes that variable. Specify `process=...` or add the variable to one model's `inputs_`."
            )
            continue
        end
        target.scale == :Default || error(
            "Route $(i) target `$(target.domain)/$(target.scale)/$(target.var)` is not supported by the single-status domain runner. ",
            "Use `scale=:Default` for single-status targets, or target an MTG-backed domain with a supported graph route cardinality."
        )
        st = status(target_mapping)
        target.var in propertynames(st) || error(
            "Route $(i) target status `$(target.domain)/$(target.scale)` does not contain variable `$(target.var)`. ",
            "Initialize it in the target domain status so the route can materialize its value."
        )
        _route_target_consumer_key(route, specs)
    end
    return nothing
end

function _validate_graph_route_order(
    mapping::SimulationMapping,
    routes::Vector{Route},
    route_bindings::Vector{Vector{DomainModelKey}},
)
    _domain_run_order(mapping, route_bindings)
    return nothing
end

function _route_clocks(routes::Vector{Route}, specs::Dict{DomainModelKey,ModelSpec}, model_clocks)
    clocks = ClockSpec[]
    for route in routes
        consumer_key = _route_target_consumer_key(route, specs)
        if isnothing(consumer_key)
            push!(clocks, ClockSpec(1.0, 0.0))
        else
            push!(clocks, model_clocks[consumer_key])
        end
    end
    return clocks
end

function _route_due(simulation::DomainSimulation, route_index::Int, step::Int)
    clock = simulation.route_clocks[route_index]
    return _should_run_at_time(clock, float(step))
end

function _route_producer_values(simulation::DomainSimulation, route_index::Int, step::Int)
    route = simulation.mapping.routes[route_index]
    source_var = route.from.var
    steps = _window_steps(step, simulation.route_clocks[route_index])
    return Any[
        _apply_dependency_policy(_resolve_stream_values(simulation, producer, source_var, steps), route.policy)
        for producer in simulation.route_bindings[route_index]
    ]
end

function _route_value_items(values::Vector{Any})
    items = Any[]
    for value in values
        isnothing(value) && continue
        if value isa DomainNodeValues
            append!(items, value.values)
        else
            push!(items, value)
        end
    end
    return items
end

function _materialize_route_value(values::Vector{Any}, cardinality::ManyToOneVector)
    return _route_value_items(values)
end

function _materialize_route_value(values::Vector{Any}, cardinality::ManyToOneAggregate)
    return cardinality.reducer(_route_value_items(values))
end

function _materialize_graph_broadcast_value(values::Vector{Any}, route_index::Int)
    items = _route_value_items(values)
    length(items) == 1 || error(
        "Route $(route_index) uses `OneToManyBroadcast()` into an MTG-backed domain and resolved $(length(items)) values. ",
        "Use a selector that resolves one source value, or aggregate upstream before broadcasting."
    )
    return only(items)
end

function _materialize_route_value(values::Vector{Any}, cardinality::RouteCardinality)
    error(
        "Route cardinality `$(typeof(cardinality))` is declared but not implemented in the single-status domain runner. ",
        "Use `ManyToOneVector()` or `ManyToOneAggregate(...)` for single-status targets. ",
        "`OneToManyBroadcast()` is supported for MTG-backed target domains."
    )
end

function _set_route_target_value!(simulation::DomainSimulation, route::Route, value)
    target = route.to
    domain = _domain_for_name(simulation.mapping, target.domain)
    target.scale == :Default || error(
        "Route target `$(target.domain)/$(target.scale)/$(target.var)` is not supported by the single-status domain runner. ",
        "Use `scale=:Default` for single-status targets, or target an MTG-backed domain with a supported graph route cardinality."
    )
    st = status(simulation, domain.name)
    target.var in propertynames(st) || error(
        "Route target status `$(target.domain)/$(target.scale)` does not contain variable `$(target.var)`. ",
        "Initialize it in the target domain status so the route can materialize its value."
    )
    st[target.var] = value
    return nothing
end

function _materialize_routes_for_domain!(simulation::DomainSimulation, domain::Domain, step::Int)
    for (i, route) in enumerate(simulation.mapping.routes)
        route.to.domain == domain.name || continue
        _route_due(simulation, i, step) || continue
        values = _route_producer_values(simulation, i, step)
        value = _materialize_route_value(values, route.cardinality)
        _set_route_target_value!(simulation, route, value)
    end
    return nothing
end

function _materialize_graph_routes_for_domain!(
    simulation::DomainSimulation,
    domain::Domain,
    graph_simulation::GraphSimulation,
    step::Int,
)
    for (i, route) in enumerate(simulation.mapping.routes)
        route.to.domain == domain.name || continue
        route.cardinality isa OneToManyBroadcast || continue
        _route_due(simulation, i, step) || continue
        target = route.to
        graph_statuses = status(graph_simulation)
        haskey(graph_statuses, target.scale) || error(
            "Route $(i) targets `$(target.domain)/$(target.scale)/$(target.var)`, ",
            "but the selected graph domain has no statuses at scale `$(target.scale)`."
        )
        values = _route_producer_values(simulation, i, step)
        value = _materialize_graph_broadcast_value(values, i)
        for st in graph_statuses[target.scale]
            target.var in propertynames(st) || error(
                "Route $(i) targets `$(target.domain)/$(target.scale)/$(target.var)`, ",
                "but one target status does not contain variable `$(target.var)`."
            )
            st[target.var] = value
        end
    end
    return nothing
end

function _materialize_graph_route_attributes_for_domain!(
    simulation::DomainSimulation,
    domain::Domain,
    root,
    step::Int,
)
    for (i, route) in enumerate(simulation.mapping.routes)
        route.to.domain == domain.name || continue
        route.cardinality isa OneToManyBroadcast || continue
        target = route.to
        values = _route_producer_values(simulation, i, step)
        value = _materialize_graph_broadcast_value(values, i)
        matched = 0
        MultiScaleTreeGraph.traverse!(root) do node
            symbol(node) == target.scale || return
            node[target.var] = value
            matched += 1
        end
        matched > 0 || error(
            "Route $(i) targets `$(target.domain)/$(target.scale)/$(target.var)`, ",
            "but the selected graph domain has no nodes at scale `$(target.scale)`."
        )
    end
    return nothing
end

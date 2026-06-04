"""
    Domain(name, mapping; kind=:generic, selector=nothing)
    Domain(name; kind, mapping, selector=nothing)

Reusable model domain used by [`SimulationMapping`](@ref).

Domains can wrap either a single-status `ModelMapping` or a scale-keyed
multiscale `ModelMapping` backed by an MTG subtree selected with `selector`.
The domain identity is kept alongside scale/process identity so multi-plant,
soil, scene, and environment domains can be compiled into one simulation
without renaming scales.
"""
struct Domain{M,S}
    name::Symbol
    kind::Symbol
    mapping::M
    selector::S
end

function _normalize_domain_mapping(mapping)
    mapping isa ModelMapping && return mapping
    if mapping isa Tuple
        status_index = findlast(x -> x isa Status, mapping)
        if !isnothing(status_index)
            status_index == length(mapping) || error(
                "Raw tuple domain mappings may contain a positional Status only as the last element."
            )
            return ModelMapping(mapping[begin:(end - 1)]...; status=last(mapping))
        end
        return ModelMapping(mapping...)
    end
    return ModelMapping(mapping)
end

function Domain(name::Union{Symbol,AbstractString}, mapping; kind::Union{Symbol,AbstractString}=:generic, selector=nothing)
    normalized_mapping = copy(_normalize_domain_mapping(mapping))
    return Domain(Symbol(name), Symbol(kind), normalized_mapping, selector)
end

function Domain(name::Union{Symbol,AbstractString}; kind::Union{Symbol,AbstractString}=:generic, mapping, selector=nothing)
    return Domain(name, mapping; kind=kind, selector=selector)
end

_domain_mapping(domain::Domain) = _normalize_domain_mapping(domain.mapping)

"""
    DomainModelKey(domain, scale, process)

Stable key for one model process inside one domain and scale.
"""
struct DomainModelKey
    domain::Symbol
    scale::Symbol
    process::Symbol
end

Base.show(io::IO, key::DomainModelKey) = print(io, key.domain, "/", key.scale, "/", key.process)

"""
    AllDomains(; kind=nothing, domain=nothing, scale=nothing, process=nothing, var=nothing, policy=HoldLast())
    AllDomains(process; kwargs...)

Value selector for scene-level models that intentionally consume output streams
from matching models in several domains.

`policy` controls how producer streams are sampled when the consumer runs at a
different rate. `AllDomains` does not provide hard-dependency call-stack
control; use [`HardDomains`](@ref) when the parent model must manually run
the selected models.
"""
struct AllDomains{P<:SchedulePolicy} <: AbstractDomainDependencySelector
    kind::Union{Nothing,Symbol}
    domain::Union{Nothing,Symbol}
    scale::Union{Nothing,Symbol}
    process::Union{Nothing,Symbol}
    var::Union{Nothing,Symbol}
    policy::P
end

function AllDomains(; kind=nothing, domain=nothing, scale=nothing, process=nothing, var=nothing, policy::SchedulePolicy=HoldLast())
    return AllDomains(
        isnothing(kind) ? nothing : Symbol(kind),
        isnothing(domain) ? nothing : Symbol(domain),
        isnothing(scale) ? nothing : Symbol(scale),
        isnothing(process) ? nothing : Symbol(process),
        isnothing(var) ? nothing : Symbol(var),
        policy,
    )
end

AllDomains(process::Union{Symbol,AbstractString}; kwargs...) = AllDomains(; process=Symbol(process), kwargs...)

"""
    HardDomains(; kind=nothing, domain=nothing, scale=nothing, process=nothing)
    HardDomains(process; kwargs...)

Selector for models that are cross-domain hard dependencies. A model declaring
`dep(model) = (; name=HardDomains(...))`
can retrieve executable targets with [`dependency_targets`](@ref) and manually
execute them with [`run_target!`](@ref).
"""
struct HardDomains <: AbstractDomainDependencySelector
    kind::Union{Nothing,Symbol}
    domain::Union{Nothing,Symbol}
    scale::Union{Nothing,Symbol}
    process::Union{Nothing,Symbol}
end

function HardDomains(; kind=nothing, domain=nothing, scale=nothing, process=nothing)
    return HardDomains(
        isnothing(kind) ? nothing : Symbol(kind),
        isnothing(domain) ? nothing : Symbol(domain),
        isnothing(scale) ? nothing : Symbol(scale),
        isnothing(process) ? nothing : Symbol(process),
    )
end

HardDomains(process::Union{Symbol,AbstractString}; kwargs...) = HardDomains(; process=Symbol(process), kwargs...)

function _push_selector_term!(terms::Vector{String}, name::Symbol, value)
    isnothing(value) || push!(terms, "$(name)=:$(value)")
    return terms
end

function _policy_display(policy::SchedulePolicy)
    return string(nameof(typeof(policy)), "()")
end

function Base.show(io::IO, selector::AllDomains)
    terms = String[]
    _push_selector_term!(terms, :kind, selector.kind)
    _push_selector_term!(terms, :domain, selector.domain)
    _push_selector_term!(terms, :scale, selector.scale)
    _push_selector_term!(terms, :process, selector.process)
    _push_selector_term!(terms, :var, selector.var)
    selector.policy isa HoldLast || push!(terms, "policy=$(_policy_display(selector.policy))")
    print(io, "AllDomains(", join(terms, ", "), ")")
end

function Base.show(io::IO, selector::HardDomains)
    terms = String[]
    _push_selector_term!(terms, :kind, selector.kind)
    _push_selector_term!(terms, :domain, selector.domain)
    _push_selector_term!(terms, :scale, selector.scale)
    _push_selector_term!(terms, :process, selector.process)
    print(io, "HardDomains(", join(terms, ", "), ")")
end

abstract type RouteCardinality end

"""
    ManyToOneVector()

Route cardinality that materializes one value per resolved producer.
"""
struct ManyToOneVector <: RouteCardinality end

"""
    ManyToOneAggregate(reducer=sum)

Route cardinality that reduces resolved producer values to one scalar.
"""
struct ManyToOneAggregate{F} <: RouteCardinality
    reducer::F
end

ManyToOneAggregate() = ManyToOneAggregate(sum)

"""
    OneToManyBroadcast()
    SpatialSample()
    SpatialScatterAdd()

Reserved route cardinalities for the MTG/spatial domain runner.
"""
struct OneToManyBroadcast <: RouteCardinality end
struct SpatialSample <: RouteCardinality end
struct SpatialScatterAdd <: RouteCardinality end

"""
    DomainRouteTarget(domain; scale=:Default, var, process=nothing)

Target of an explicit cross-domain route.
"""
struct DomainRouteTarget
    domain::Symbol
    scale::Symbol
    var::Symbol
    process::Union{Nothing,Symbol}
end

function Base.show(io::IO, target::DomainRouteTarget)
    terms = ["domain=:$(target.domain)"]
    target.scale == :Default || push!(terms, "scale=:$(target.scale)")
    push!(terms, "var=:$(target.var)")
    isnothing(target.process) || push!(terms, "process=:$(target.process)")
    print(io, "DomainRouteTarget(", join(terms, ", "), ")")
end

function DomainRouteTarget(
    domain::Union{Symbol,AbstractString};
    scale::Union{Symbol,AbstractString}=:Default,
    var,
    process=nothing,
)
    return DomainRouteTarget(
        Symbol(domain),
        Symbol(scale),
        Symbol(var),
        isnothing(process) ? nothing : Symbol(process),
    )
end

"""
    Route(from, to; cardinality=ManyToOneVector(), policy=nothing)
    Route(; from, to, cardinality=ManyToOneVector(), policy=nothing)

Explicit cross-domain route materialized into a target domain status before
that domain runs.
"""
struct Route{F,T,C<:RouteCardinality,P<:SchedulePolicy}
    from::F
    to::T
    cardinality::C
    policy::P
end

function Route(from::AllDomains, to::DomainRouteTarget; cardinality::RouteCardinality=ManyToOneVector(), policy=nothing)
    route_policy = isnothing(policy) ? from.policy : _as_schedule_policy(policy; context="Route policy")
    isnothing(from.var) && error(
        "Route source `AllDomains(...)` must declare `var=:source_variable` so the runtime knows what to materialize."
    )
    return Route(from, to, cardinality, route_policy)
end

Route(; from, to, cardinality::RouteCardinality=ManyToOneVector(), policy=nothing) =
    Route(from, to; cardinality=cardinality, policy=policy)

"""
    SimulationMapping(domains...)

Top-level composition of reusable domains. This is the incremental entry point
for multi-plant/soil/scene simulations.
"""
struct SimulationMapping
    domains::Vector{Domain}
    routes::Vector{Route}
end

function SimulationMapping(domains::Domain...; routes=())
    names = [domain.name for domain in domains]
    duplicates = unique(filter(name -> count(==(name), names) > 1, names))
    isempty(duplicates) || error("Duplicate domain name(s) in SimulationMapping: $(join(duplicates, ", ")).")
    normalized_routes = Route[]
    for route in routes
        route isa Route || error("SimulationMapping routes must be `Route` objects, got `$(typeof(route))`.")
        push!(normalized_routes, route)
    end
    return SimulationMapping(collect(domains), normalized_routes)
end

"""
    DomainRunContext

Runtime context passed as `extra` to models run by [`SimulationMapping`](@ref).
Scene models can call [`dependency_values`](@ref) to consume resolved
`AllDomains` value dependencies, or [`dependency_targets`](@ref) to manually
run resolved `HardDomains` dependencies.
"""
struct DomainRunContext
    simulation
    consumer::DomainModelKey
    step::Int
    clock::ClockSpec
    constants
end

struct ModelTarget
    simulation
    key
    node
    step::Int
    model
    models
    status
    meteo
    constants
    extra
end

struct DomainNodeValues{I,T<:AbstractVector}
    ids::I
    values::T
end

DomainNodeValues(values::AbstractVector) = DomainNodeValues(nothing, values)

"""
    model_target(model, models, status, meteo=nothing, constants=nothing, extra=nothing; kwargs...)

Build one executable model target. This is the low-level representation used by
hard-domain dependencies and can also be used by ordinary same-status hard
dependencies.
"""
function model_target(
    model,
    models,
    status,
    meteo=nothing,
    constants=nothing,
    extra=nothing;
    simulation=nothing,
    key=nothing,
    node=nothing,
    step::Integer=1,
)
    return ModelTarget(simulation, key, node, Int(step), model, models, status, meteo, constants, extra)
end

function dependency_targets(
    models,
    status,
    dependency_name::Symbol;
    meteo=nothing,
    constants=nothing,
    extra=nothing,
)
    hasproperty(models, dependency_name) || error(
        "No model named `$(dependency_name)` is available in `models`. ",
        "Declare the hard dependency with `dep(model)` and include a model for that process in the mapping."
    )
    return ModelTarget[
        model_target(getproperty(models, dependency_name), models, status, meteo, constants, extra),
    ]
end

dependency_targets(models, status, dependency_name::AbstractString; kwargs...) =
    dependency_targets(models, status, Symbol(dependency_name); kwargs...)

dependency_target(args...; kwargs...) = only(dependency_targets(args...; kwargs...))

struct DomainGraphState{S<:AbstractVector}
    simulations::S
end

struct DomainGraphRuntime
    state::DomainGraphState
    meteo
    constants
    effective_multirate::Bool
    timeline::TimelineContext
    meteo_sampler
    executor
end

"""
    DomainSimulation

Result and mutable runtime state for a [`SimulationMapping`](@ref) run.
"""
mutable struct DomainSimulation
    mapping::SimulationMapping
    environment::AbstractEnvironmentBackend
    model_specs::Dict{DomainModelKey,ModelSpec}
    model_clocks::Dict{DomainModelKey,ClockSpec}
    dependency_graphs::Dict{Symbol,DependencyGraph}
    dependency_bindings::Dict{Tuple{DomainModelKey,Symbol},Vector{DomainModelKey}}
    dependency_variables::Dict{Tuple{DomainModelKey,Symbol},Union{Nothing,Symbol}}
    dependency_policies::Dict{Tuple{DomainModelKey,Symbol},SchedulePolicy}
    hard_domain_dependency_bindings::Dict{Tuple{DomainModelKey,Symbol},Vector{DomainModelKey}}
    route_bindings::Vector{Vector{DomainModelKey}}
    route_clocks::Vector{ClockSpec}
    streams::Dict{Tuple{DomainModelKey,Symbol},Vector{Pair{Int,Any}}}
    outputs::Dict{Tuple{DomainModelKey,Symbol},Vector{Any}}
    domain_states::Dict{Symbol,Any}
    timeline::TimelineContext
end

outputs(simulation::DomainSimulation) = simulation.outputs

function status(state::DomainGraphState)
    statuses = Dict{Symbol,Vector{Status}}()
    for graph_simulation in state.simulations
        for (scale, statuses_at_scale) in status(graph_simulation)
            append!(get!(statuses, scale, Status[]), statuses_at_scale)
        end
    end
    return statuses
end

function _global_scale_statuses(simulation::DomainSimulation, scale::Symbol)
    statuses = Status[]
    for state in values(simulation.domain_states)
        if state isa DomainGraphState
            graph_statuses = status(state)
            haskey(graph_statuses, scale) || continue
            append!(statuses, graph_statuses[scale])
        elseif state isa ModelMapping{SingleScale} && scale == :Default
            push!(statuses, status(state))
        end
    end
    return statuses
end

function _domain_declares_scale(domain::Domain, scale::Symbol)
    mapping = _domain_mapping(domain)
    mapping isa ModelMapping{MultiScale} || return false
    return any(entry -> first(entry) == scale, pairs(mapping))
end

function _simulation_declares_graph_scale(simulation::DomainSimulation, scale::Symbol)
    return any(domain -> _domain_declares_scale(domain, scale), simulation.mapping.domains)
end

function status(simulation::DomainSimulation, domain_name::Symbol)
    state = get(simulation.domain_states, domain_name, nothing)
    if isnothing(state)
        statuses = _global_scale_statuses(simulation, domain_name)
        isempty(statuses) && _simulation_declares_graph_scale(simulation, domain_name) && return statuses
        isempty(statuses) && error(
            "No domain named `$(domain_name)` and no global scale `$(domain_name)` exists in this DomainSimulation."
        )
        return statuses
    end
    state isa ModelMapping{SingleScale} || error(
        "Domain `$(domain_name)` is MTG-backed. Use `status(simulation, domain, scale)` to inspect statuses at one scale."
    )
    return status(state)
end

status(simulation::DomainSimulation, domain_name::AbstractString) = status(simulation, Symbol(domain_name))

function status(simulation::DomainSimulation, domain_name::Symbol, scale::Symbol)
    state = get(simulation.domain_states, domain_name, nothing)
    isnothing(state) && error("Domain `$(domain_name)` has no runtime state.")
    state isa DomainGraphState || error(
        "Domain `$(domain_name)` is single-status. Use `status(simulation, domain)` without a scale."
    )
    graph_statuses = status(state)
    haskey(graph_statuses, scale) && return graph_statuses[scale]
    domain = _domain_for_name(simulation.mapping, domain_name)
    _domain_declares_scale(domain, scale) && return Status[]
    error("Domain `$(domain_name)` has no runtime statuses and no declared mapping at scale `$(scale)`.")
end

status(simulation::DomainSimulation, domain_name::AbstractString, scale::Union{Symbol,AbstractString}) =
    status(simulation, Symbol(domain_name), Symbol(scale))

function _domain_entries(domain::Domain)
    mapping = _domain_mapping(domain)
    return collect(pairs(mapping))
end

function _validate_initial_domain_mapping(domain::Domain)
    mapping = _domain_mapping(domain)
    mapping isa ModelMapping{SingleScale} || error(
        "Domain `$(domain.name)` uses a multiscale ModelMapping. ",
        "The initial SimulationMapping runner only supports single-status domains; ",
        "the MTG/domain runner will handle nested multiscale plant domains."
    )
    return nothing
end

_is_single_status_domain(domain::Domain) = _domain_mapping(domain) isa ModelMapping{SingleScale}
_is_graph_domain(domain::Domain) = _domain_mapping(domain) isa ModelMapping{MultiScale}

function _validate_staged_domain_mapping(domain::Domain)
    mapping = _domain_mapping(domain)
    mapping isa ModelMapping || error("Domain `$(domain.name)` does not wrap a valid ModelMapping.")
    if mapping isa ModelMapping{SingleScale} && !isnothing(domain.selector)
        error(
            "Domain `$(domain.name)` has a selector but uses a single-status ModelMapping. ",
            "Selectors are only supported for MTG-backed, scale-keyed domain mappings in the MTG-domain runner."
        )
    end
    return nothing
end

function _collect_matching_nodes(root, predicate)
    matches = Any[]
    MultiScaleTreeGraph.traverse!(root) do node
        predicate(node) && push!(matches, node)
    end
    return matches
end

function _is_ancestor_node(ancestor, node)
    current = parent(node)
    while !isnothing(current)
        current === ancestor && return true
        current = parent(current)
    end
    return false
end

function _validate_domain_graph_roots!(domain::Domain, roots)
    for i in eachindex(roots), j in (i + 1):lastindex(roots)
        left = roots[i]
        right = roots[j]
        if _is_ancestor_node(left, right) || _is_ancestor_node(right, left)
            error(
                "Selector for MTG-backed domain `$(domain.name)` matched overlapping MTG roots ",
                "`$(node_id(left))` and `$(node_id(right))`. ",
                "Select non-overlapping domain roots, for example plant roots rather than both plants and organs."
            )
        end
    end
    return roots
end

function _domain_graph_roots(object, domain::Domain)
    selector = domain.selector
    isnothing(selector) && return Any[object]
    selector isa MultiScaleTreeGraph.Node && return Any[selector]
    if selector isa Symbol
        matches = _collect_matching_nodes(object, node -> symbol(node) == selector)
    elseif selector isa Function
        matches = _collect_matching_nodes(object, selector)
    else
        error(
            "Unsupported selector for MTG-backed domain `$(domain.name)`: `$(typeof(selector))`. ",
            "Use `selector=nothing`, a `MultiScaleTreeGraph.Node`, a scale `Symbol`, or a predicate function."
        )
    end
    isempty(matches) && error(
        "Selector for MTG-backed domain `$(domain.name)` matched $(length(matches)) nodes. ",
        "Use a selector that identifies at least one domain root for this MTG-domain runner."
    )
    return _validate_domain_graph_roots!(domain, matches)
end

function _domain_model_specs(domain::Domain)
    specs = Dict{DomainModelKey,ModelSpec}()
    for (scale, declarations) in _domain_entries(domain)
        for (process, spec) in pairs(parse_model_specs(declarations))
            specs[DomainModelKey(domain.name, scale, process)] = spec
        end
    end
    return specs
end

function _domain_model_clocks(specs::Dict{DomainModelKey,ModelSpec}, timeline::TimelineContext)
    clocks = Dict{DomainModelKey,ClockSpec}()
    for (key, spec) in specs
        clocks[key] = _model_clock(spec, model_(spec), timeline)
    end
    return clocks
end

function _domain_dependency_graphs(mapping::SimulationMapping)
    graphs = Dict{Symbol,DependencyGraph}()
    for domain in mapping.domains
        graph = dep(_domain_mapping(domain))
        if !isempty(graph.not_found)
            error("Domain `$(domain.name)` has unresolved dependencies: $(graph.not_found).")
        end
        graphs[domain.name] = graph
    end
    return graphs
end

function _domain_for_name(mapping::SimulationMapping, name::Symbol)
    for domain in mapping.domains
        domain.name == name && return domain
    end
    error("Unknown domain `$(name)`.")
end

function _matches(selector::AllDomains, domain::Domain, key::DomainModelKey, spec::ModelSpec; check_var=true)
    isnothing(selector.kind) || selector.kind == domain.kind || return false
    isnothing(selector.domain) || selector.domain == domain.name || return false
    isnothing(selector.scale) || selector.scale == key.scale || return false
    isnothing(selector.process) || selector.process == key.process || return false
    !check_var || isnothing(selector.var) || selector.var in keys(outputs_(spec)) || return false
    return true
end

function _matches(selector::HardDomains, domain::Domain, key::DomainModelKey, spec::ModelSpec; check_var=false)
    isnothing(selector.kind) || selector.kind == domain.kind || return false
    isnothing(selector.domain) || selector.domain == domain.name || return false
    isnothing(selector.scale) || selector.scale == key.scale || return false
    isnothing(selector.process) || selector.process == key.process || return false
    return true
end

function _format_symbol_keys(keys_iter)
    syms = sort!(collect(Symbol.(keys_iter)); by=string)
    isempty(syms) && return "none"
    return join((":" * string(sym) for sym in syms), ", ")
end

function _domain_candidate_rows(
    mapping::SimulationMapping,
    specs::Dict{DomainModelKey,ModelSpec};
    selector=nothing,
    check_var=true,
    max_rows=12,
)
    rows = String[]
    keys_by_domain = _keys_by_domain(specs)
    for domain in mapping.domains
        producer_keys = sort!(
            copy(get(keys_by_domain, domain.name, DomainModelKey[]));
            by=key -> (string(key.scale), string(key.process)),
        )
        for producer_key in producer_keys
            producer_spec = specs[producer_key]
            if selector isa Union{AllDomains,HardDomains}
                _matches(selector, domain, producer_key, producer_spec; check_var=check_var) || continue
            end
            push!(
                rows,
                "$(producer_key) outputs=($(_format_symbol_keys(keys(outputs_(producer_spec)))))",
            )
        end
    end

    length(rows) <= max_rows && return join(rows, "\n  ")
    shown = rows[1:max_rows]
    push!(shown, "... and $(length(rows) - max_rows) more")
    return join(shown, "\n  ")
end

function _selector_match_error(
    mapping::SimulationMapping,
    specs::Dict{DomainModelKey,ModelSpec},
    selector::Union{AllDomains,HardDomains};
    context::String,
)
    candidates = _domain_candidate_rows(mapping, specs)
    message = string(
        context,
        " did not match any model for selector `",
        selector,
        "`. Suggested fixes: check `kind`, `domain`, `scale`, and `process`; ",
        "if `var` is set, use one of the producer outputs listed below.\n",
        "Available producers:\n  ",
        isempty(candidates) ? "none" : candidates,
    )
    if selector isa AllDomains && !isnothing(selector.var)
        near_matches = _domain_candidate_rows(mapping, specs; selector=selector, check_var=false)
        if !isempty(near_matches)
            message = string(
                message,
                "\nModels matching all selector fields except `var=:",
                selector.var,
                "`:\n  ",
                near_matches,
            )
        end
    end
    return message
end

function _resolve_domain_dependencies(mapping::SimulationMapping, specs::Dict{DomainModelKey,ModelSpec})
    bindings = Dict{Tuple{DomainModelKey,Symbol},Vector{DomainModelKey}}()
    policies = Dict{Tuple{DomainModelKey,Symbol},SchedulePolicy}()
    variables = Dict{Tuple{DomainModelKey,Symbol},Union{Nothing,Symbol}}()
    keys_by_domain = _keys_by_domain(specs)

    for (consumer_key, spec) in specs
        model_deps = dep(model_(spec))
        for (dep_name, selector) in pairs(model_deps)
            selector isa AllDomains || continue
            resolved = DomainModelKey[]
            for domain in mapping.domains
                for producer_key in get(keys_by_domain, domain.name, DomainModelKey[])
                    producer_key == consumer_key && continue
                    producer_spec = specs[producer_key]
                    _matches(selector, domain, producer_key, producer_spec) && push!(resolved, producer_key)
                end
            end
            isempty(resolved) && error(
                _selector_match_error(
                    mapping,
                    specs,
                    selector;
                    context="Domain dependency `$(dep_name)` for consumer `$(consumer_key)`",
                )
            )
            binding_key = (consumer_key, dep_name)
            bindings[binding_key] = resolved
            policies[binding_key] = selector.policy
            variables[binding_key] = selector.var
        end
    end

    return bindings, policies, variables
end

function _resolve_hard_domain_dependencies(mapping::SimulationMapping, specs::Dict{DomainModelKey,ModelSpec})
    bindings = Dict{Tuple{DomainModelKey,Symbol},Vector{DomainModelKey}}()
    keys_by_domain = _keys_by_domain(specs)

    for (consumer_key, spec) in specs
        model_deps = dep(model_(spec))
        for (dep_name, selector) in pairs(model_deps)
            selector isa HardDomains || continue
            resolved = DomainModelKey[]
            for domain in mapping.domains
                for producer_key in get(keys_by_domain, domain.name, DomainModelKey[])
                    producer_key == consumer_key && continue
                    producer_spec = specs[producer_key]
                    _matches(selector, domain, producer_key, producer_spec) && push!(resolved, producer_key)
                end
            end
            isempty(resolved) && error(
                _selector_match_error(
                    mapping,
                    specs,
                    selector;
                    context="Hard domain dependency `$(dep_name)` for consumer `$(consumer_key)`",
                )
            )
            bindings[(consumer_key, dep_name)] = resolved
        end
    end

    return bindings
end

function _keys_by_domain(specs::Dict{DomainModelKey,ModelSpec})
    keys_by_domain = Dict{Symbol,Vector{DomainModelKey}}()
    for key in keys(specs)
        push!(get!(keys_by_domain, key.domain, DomainModelKey[]), key)
    end
    return keys_by_domain
end

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

function _build_domain_simulation(mapping::SimulationMapping, meteo; staged_graph_domains=false)
    environment = environment_backend(meteo)
    _validate_meteo_duration(environment)
    timeline = _timeline_context(environment)
    foreach(staged_graph_domains ? _validate_staged_domain_mapping : _validate_initial_domain_mapping, mapping.domains)
    specs = Dict{DomainModelKey,ModelSpec}()
    for domain in mapping.domains
        merge!(specs, _domain_model_specs(domain))
    end
    mapping = _add_route_target_status_defaults(mapping, specs)

    model_clocks = _domain_model_clocks(specs, timeline)
    graphs = _domain_dependency_graphs(mapping)
    bindings, policies, variables = _resolve_domain_dependencies(mapping, specs)
    hard_domain_bindings = _resolve_hard_domain_dependencies(mapping, specs)
    route_bindings = _resolve_route_bindings(mapping, specs)
    _validate_route_targets(mapping, mapping.routes, specs; staged_graph_domains=staged_graph_domains)
    staged_graph_domains && _validate_graph_route_order(mapping, mapping.routes, route_bindings)
    route_clocks = _route_clocks(mapping.routes, specs, model_clocks)
    validate_meteo_inputs(_domain_model_specs_by_scale(specs), environment)
    return DomainSimulation(
        mapping,
        environment,
        specs,
        model_clocks,
        graphs,
        bindings,
        variables,
        policies,
        hard_domain_bindings,
        route_bindings,
        route_clocks,
        Dict{Tuple{DomainModelKey,Symbol},Vector{Pair{Int,Any}}}(),
        Dict{Tuple{DomainModelKey,Symbol},Vector{Any}}(),
        Dict{Symbol,Any}(domain.name => _domain_mapping(domain) for domain in mapping.domains if _domain_mapping(domain) isa ModelMapping{SingleScale}),
        timeline,
    )
end

function _domain_model_specs_by_scale(specs::Dict{DomainModelKey,ModelSpec})
    by_scale = Dict{Symbol,Dict{Symbol,ModelSpec}}()
    for (key, spec) in specs
        scale_key = Symbol(string(key.domain), "/", string(key.scale))
        scale_specs = get!(by_scale, scale_key, Dict{Symbol,ModelSpec}())
        scale_specs[key.process] = spec
    end
    return by_scale
end

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

function _resolve_stream_values(simulation::DomainSimulation, producer::DomainModelKey, var::Symbol, steps)
    stream = get(simulation.streams, (producer, var), Pair{Int,Any}[])
    vals = Any[]
    for (step, value) in stream
        step in steps && push!(vals, value)
    end
    return vals
end

function _domain_node_values(values::Vector{Any})
    return DomainNodeValues[value for value in values if value isa DomainNodeValues]
end

function _domain_node_values_have_ids(values::Vector{DomainNodeValues})
    return all(value -> !isnothing(value.ids) && length(value.ids) == length(value.values), values)
end

function _combine_domain_node_values_by_position(values::Vector{DomainNodeValues}, reducer)
    lengths = unique(length(value.values) for value in values)
    length(lengths) == 1 || error(
        "Cannot aggregate graph-domain values with changing vector lengths because node ids are unavailable. ",
        "Publish graph-domain outputs through PlantSimEngine's graph-domain runtime so values can be aligned by node id."
    )
    n = only(lengths)
    return DomainNodeValues(Any[reducer(Any[value.values[i] for value in values]) for i in 1:n])
end

function _combine_domain_node_values_by_id(values::Vector{DomainNodeValues}, reducer)
    grouped = Dict{Int,Vector{Any}}()
    order = Int[]
    for node_values in values
        for (id, value) in zip(node_values.ids, node_values.values)
            bucket = get!(grouped, id) do
                push!(order, id)
                Any[]
            end
            push!(bucket, value)
        end
    end
    return DomainNodeValues(order, Any[reducer(grouped[id]) for id in order])
end

function _combine_domain_node_values(values::Vector{Any}, reducer)
    node_values = _domain_node_values(values)
    _domain_node_values_have_ids(node_values) && return _combine_domain_node_values_by_id(node_values, reducer)
    return _combine_domain_node_values_by_position(node_values, reducer)
end

function _apply_dependency_policy(values::Vector{Any}, policy::SchedulePolicy)
    isempty(values) && return nothing
    if policy isa HoldLast || policy isa Interpolate
        return last(values)
    elseif policy isa Integrate
        if any(value -> value isa DomainNodeValues, values)
            return _combine_domain_node_values(values, sum)
        end
        return sum(values)
    elseif policy isa Aggregate
        if any(value -> value isa DomainNodeValues, values)
            return _combine_domain_node_values(values, vals -> sum(vals) / length(vals))
        end
        return sum(values) / length(values)
    end
    return last(values)
end

_public_dependency_value(value) = value isa DomainNodeValues ? value.values : value

function _push_public_dependency_value!(dest::Vector{Any}, value, flatten::Bool)
    isnothing(value) && return dest
    if flatten && value isa DomainNodeValues
        append!(dest, value.values)
    else
        push!(dest, _public_dependency_value(value))
    end
    return dest
end

function _window_steps(step::Int, clock::ClockSpec)
    start = _window_start_for_clock(clock, float(step))
    return ceil(Int, start):step
end

"""
    dependency_values(ctx, dependency_name, variable)
    dependency_values(ctx, dependency_name)

Return one value per resolved producer for a scene-level `AllDomains`
dependency, applying the selector's temporal policy over the consumer window.
When `AllDomains(...; var=:x)` declares a variable, the two-argument form uses
that variable.
"""
function dependency_values(ctx::DomainRunContext, dependency_name::Symbol, variable=nothing; flatten=false)
    sim = ctx.simulation
    binding_key = (ctx.consumer, dependency_name)
    producers = get(sim.dependency_bindings, binding_key, nothing)
    isnothing(producers) && error(
        "No resolved dependency named `$(dependency_name)` for `$(ctx.consumer)`. ",
        "Declare it with `dep(model) = (; $(dependency_name)=AllDomains(...))`."
    )
    declared_var = sim.dependency_variables[binding_key]
    resolved_var = isnothing(variable) ? declared_var : Symbol(variable)
    isnothing(resolved_var) && error(
        "No variable was provided for domain dependency `$(dependency_name)` in `$(ctx.consumer)`. ",
        "Call `dependency_values(extra, :$(dependency_name), :variable)` or declare ",
        "`AllDomains(...; var=:variable)`."
    )
    if !isnothing(declared_var) && !isnothing(variable) && Symbol(variable) != declared_var
        error(
            "Domain dependency `$(dependency_name)` in `$(ctx.consumer)` was declared with `var=:$(declared_var)`, ",
            "but `dependency_values` was called for variable `$(Symbol(variable))`."
        )
    end
    for producer in producers
        producer_spec = sim.model_specs[producer]
        resolved_var in keys(outputs_(producer_spec)) || error(
            "Domain dependency `$(dependency_name)` resolved producer `$(producer)`, ",
            "but that producer does not output variable `$(resolved_var)`."
        )
    end
    policy = sim.dependency_policies[binding_key]
    steps = _window_steps(ctx.step, ctx.clock)
    values = Any[]
    for producer in producers
        value = _apply_dependency_policy(_resolve_stream_values(sim, producer, resolved_var, steps), policy)
        _push_public_dependency_value!(values, value, flatten)
    end
    return values
end

dependency_values(ctx::DomainRunContext, dependency_name::AbstractString, variable=nothing; flatten=false) =
    dependency_values(ctx, Symbol(dependency_name), variable; flatten=flatten)

function _find_dependency_node(node::SoftDependencyNode, key::DomainModelKey)
    node.scale == key.scale && node.process == key.process && return node
    for child in node.children
        found = _find_dependency_node(child, key)
        isnothing(found) || return found
    end
    return nothing
end

function _find_dependency_node(graph::DependencyGraph, key::DomainModelKey)
    for (_, root) in graph.roots
        found = _find_dependency_node(root, key)
        isnothing(found) || return found
    end
    error("No dependency node found for domain model `$(key)`.")
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

function _single_status_dependency_targets(ctx::DomainRunContext, producer::DomainModelKey)
    sim = ctx.simulation
    domain = _domain_for_name(sim.mapping, producer.domain)
    model_list = _modellist_from_model_mapping(_domain_mapping(domain))
    node = _find_dependency_node(sim.dependency_graphs[producer.domain], producer)
    st = status(model_list)
    producer_context = DomainRunContext(sim, producer, ctx.step, sim.model_clocks[producer], ctx.constants)
    return ModelTarget[
        ModelTarget(
            sim,
            producer,
            node,
            ctx.step,
            node.value,
            model_list.models,
            st,
            _dependency_target_meteo(sim, producer, st, ctx.step),
            ctx.constants,
            producer_context,
        ),
    ]
end

function _graph_dependency_targets(ctx::DomainRunContext, producer::DomainModelKey)
    sim = ctx.simulation
    graph_state = sim.domain_states[producer.domain]
    targets = ModelTarget[]
    for graph_simulation in graph_state.simulations
        graph_statuses = status(graph_simulation)
        haskey(graph_statuses, producer.scale) || continue
        node = _find_dependency_node(dep(graph_simulation), producer)
        models_at_scale = get_models(graph_simulation)[producer.scale]
        for st in graph_statuses[producer.scale]
            push!(
                targets,
                ModelTarget(
                    sim,
                    producer,
                    node,
                    ctx.step,
                    node.value,
                    models_at_scale,
                    st,
                    _dependency_target_meteo(sim, producer, st, ctx.step),
                    ctx.constants,
                    graph_simulation,
                ),
            )
        end
    end
    return targets
end

function _dependency_targets_for_producer(ctx::DomainRunContext, producer::DomainModelKey)
    state = ctx.simulation.domain_states[producer.domain]
    state isa ModelMapping{SingleScale} && return _single_status_dependency_targets(ctx, producer)
    state isa DomainGraphState && return _graph_dependency_targets(ctx, producer)
    error("Unsupported runtime state for domain `$(producer.domain)`: `$(typeof(state))`.")
end

"""
    dependency_targets(ctx, dependency_name)

Return executable targets for a resolved `HardDomains` dependency. The parent
model controls when, how often, and in which order targets are executed by
calling [`run_target!`](@ref).
"""
function dependency_targets(ctx::DomainRunContext, dependency_name::Symbol)
    sim = ctx.simulation
    binding_key = (ctx.consumer, dependency_name)
    producers = get(sim.hard_domain_dependency_bindings, binding_key, nothing)
    isnothing(producers) && error(
        "No hard-domain dependency named `$(dependency_name)` for `$(ctx.consumer)`. ",
        "Declare it with `dep(model) = (; $(dependency_name)=HardDomains(...))`."
    )
    targets = ModelTarget[]
    for producer in producers
        append!(targets, _dependency_targets_for_producer(ctx, producer))
    end
    return targets
end

dependency_targets(ctx::DomainRunContext, dependency_name::AbstractString) =
    dependency_targets(ctx, Symbol(dependency_name))

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

"""
    run_target!(target; meteo=target.meteo, constants=target.constants, extra=target.extra, publish=false)

Run one executable model target. The call mutates the target's
status, just like a normal hard dependency call. It does not append to domain
streams or outputs unless `publish=true`.
"""
function run_target!(
    target::ModelTarget;
    meteo=target.meteo,
    constants=target.constants,
    extra=target.extra,
    publish::Bool=false,
)
    run!(target.model, target.models, target.status, meteo, constants, extra)
    publish && _publish_target!(target)
    return target.status
end

function run_target!(
    models,
    status,
    dependency_name::Symbol;
    meteo=nothing,
    constants=nothing,
    extra=nothing,
    publish::Bool=false,
)
    target = dependency_target(models, status, dependency_name; meteo=meteo, constants=constants, extra=extra)
    return run_target!(target; publish=publish)
end

run_target!(models, status, dependency_name::AbstractString; kwargs...) =
    run_target!(models, status, Symbol(dependency_name); kwargs...)

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

function _domain_context_for(simulation::DomainSimulation, domain::Domain, node::SoftDependencyNode, step::Int, constants=nothing)
    key = DomainModelKey(domain.name, node.scale, node.process)
    return DomainRunContext(simulation, key, step, simulation.model_clocks[key], constants)
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

function _run_domain_node!(
    simulation::DomainSimulation,
    domain::Domain,
    node::SoftDependencyNode,
    model_list::ModelList,
    constants,
    step::Int,
    ran::Set{DomainModelKey};
    phase::Symbol=:normal,
)
    key = DomainModelKey(domain.name, node.scale, node.process)
    if _domain_node_due(simulation, domain, node, step) &&
       _domain_parents_ready(simulation, domain, node, step, ran) &&
       _should_visit_domain_node(simulation, domain, node; phase=phase) &&
       !(key in ran)
        ctx = _domain_context_for(simulation, domain, node, step, constants)
        model_spec = simulation.model_specs[key]
        meteo_for_model = _domain_environment_for_model(
            simulation,
            domain,
            node,
            model_spec,
            status(model_list),
            step,
        )
        run!(node.value, model_list.models, status(model_list), meteo_for_model, constants, ctx)
        _scatter_domain_environment_outputs!(simulation, domain, node, model_spec, status(model_list), step)
        push!(ran, key)
        _publish_domain_model_outputs!(simulation, domain, node, status(model_list), step)
        for hard_child in node.hard_dependency
            _scatter_domain_hard_dependency_environment_outputs!(simulation, domain, hard_child, status(model_list), step)
            _publish_domain_hard_dependency_outputs!(simulation, domain, hard_child, status(model_list), step)
        end
    end

    for child in node.children
        _run_domain_node!(simulation, domain, child, model_list, constants, step, ran; phase=phase)
    end
    return nothing
end

function _run_domain_models!(
    simulation::DomainSimulation,
    domain::Domain,
    constants,
    step::Int;
    phase::Symbol=:normal,
)
    mapping = _domain_mapping(domain)
    model_list = _modellist_from_model_mapping(mapping)
    ran = Set{DomainModelKey}()
    for (_, root) in simulation.dependency_graphs[domain.name].roots
        _run_domain_node!(simulation, domain, root, model_list, constants, step, ran; phase=phase)
    end
    return ran
end

"""
    run!(mapping::SimulationMapping, meteo=nothing, constants=PlantMeteo.Constants(); check=true)

Run the initial domain-aware simulation path. This runner is deliberately
limited to single-status domains, but it schedules each model with its own
effective timestep. It is intended to make the multi-domain API executable
while the full MTG path is implemented.
"""
function run!(
    mapping::SimulationMapping,
    meteo=nothing,
    constants=PlantMeteo.Constants();
    check=true
)
    simulation = _build_domain_simulation(mapping, meteo)
    nsteps = get_nsteps(simulation.environment)
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

function _raw_meteo_for_staged_graph_domains(environment::GlobalConstant)
    return environment_meteo(environment)
end

function _raw_meteo_for_staged_graph_domains(environment::AbstractEnvironmentBackend)
    return environment
end

function _run_single_status_domain_all_steps!(
    simulation::DomainSimulation,
    domain::Domain,
    constants,
    nsteps::Int
)
    for step in 1:nsteps
        _run_domain_models!(simulation, domain, constants, step)
    end
    return nothing
end

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

function _meteo_for_graph_step(meteo, step::Int, nsteps::Int)
    return _meteo_row_at_step(meteo, step)
end

function _meteo_for_graph_step(backend::AbstractEnvironmentBackend, step::Int, nsteps::Int)
    return backend
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

"""
    run!(mtg, mapping::SimulationMapping, meteo=nothing, constants=PlantMeteo.Constants(); ...)

Run a multi-domain simulation where MTG-backed domains are selected from `mtg`
and executed with the existing `GraphSimulation` engine.

The runner advances all domains one base timestep at a time. Domains whose
`kind` is not `:scene` run first in mapping order, then `:scene` domains run so
they can consume plant, soil, and graph-domain streams from the same timestep.
Routes into graph domains are supported for `OneToManyBroadcast()` when the
source domain runs earlier in the timestep.
"""
function run!(
    object::MultiScaleTreeGraph.Node,
    mapping::SimulationMapping,
    meteo=nothing,
    constants=PlantMeteo.Constants();
    nsteps=nothing,
    check=true,
    executor=SequentialEx(),
    type_promotion=nothing,
)
    simulation = _build_domain_simulation(mapping, meteo; staged_graph_domains=true)
    raw_meteo = _raw_meteo_for_staged_graph_domains(simulation.environment)
    isnothing(nsteps) && (nsteps = get_nsteps(simulation.environment))
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

"""
    explain_domains(mapping_or_simulation)

Return structured rows describing domains in a simulation mapping.
"""
function explain_domains(mapping::SimulationMapping)
    return [
        (domain=domain.name, kind=domain.kind, mapping=typeof(domain.mapping), selector=domain.selector)
        for domain in mapping.domains
    ]
end

explain_domains(simulation::DomainSimulation) = explain_domains(simulation.mapping)

function _domain_model_rows(mapping::SimulationMapping)
    rows = NamedTuple[]
    for domain in mapping.domains
        for (scale, declarations) in _domain_entries(domain)
            for (process, spec) in pairs(parse_model_specs(declarations))
                key = DomainModelKey(domain.name, scale, process)
                push!(rows, (
                    key=key,
                    domain=domain.name,
                    kind=domain.kind,
                    scale=scale,
                    process=process,
                    model=typeof(model_(spec)),
                    timestep=timestep(spec),
                    inputs=inputs_(spec),
                    outputs=outputs_(spec),
                    meteo_inputs=meteo_inputs_(spec),
                    meteo_outputs=meteo_outputs_(spec),
                    updates=updates(spec),
                ))
            end
        end
    end
    return rows
end

"""
    explain_domain_models(mapping_or_simulation)

Return structured rows for every model process inside every domain.
"""
explain_domain_models(mapping::SimulationMapping) = _domain_model_rows(mapping)
explain_domain_models(simulation::DomainSimulation) = explain_domain_models(simulation.mapping)

"""
    explain_domain_statuses(simulation)

Return structured rows describing runtime status counts by domain and scale.
For graph domains, one row is returned per scale. For single-status domains,
the scale is `:Default`.
"""
function explain_domain_statuses(simulation::DomainSimulation)
    rows = NamedTuple[]
    for domain in simulation.mapping.domains
        state = get(simulation.domain_states, domain.name, nothing)
        if state isa DomainGraphState
            graph_statuses = status(state)
            declared_scales = Symbol[first(entry) for entry in _domain_entries(domain)]
            runtime_scales = collect(keys(graph_statuses))
            for scale in sort!(unique!(vcat(declared_scales, runtime_scales)); by=string)
                statuses_at_scale = get(graph_statuses, scale, Status[])
                push!(rows, (
                    domain=domain.name,
                    kind=domain.kind,
                    scale=scale,
                    nstatuses=length(statuses_at_scale),
                    state=typeof(state),
                ))
            end
        elseif state isa ModelMapping{SingleScale}
            push!(rows, (
                domain=domain.name,
                kind=domain.kind,
                scale=:Default,
                nstatuses=1,
                state=typeof(state),
            ))
        end
    end
    return rows
end

"""
    explain_schedule(simulation)

Return structured rows describing effective per-domain schedules.
"""
function explain_schedule(simulation::DomainSimulation)
    rows = NamedTuple[]
    for domain in simulation.mapping.domains, (key, clock) in simulation.model_clocks
        key.domain == domain.name || continue
        push!(rows, (
            domain=domain.name,
            kind=domain.kind,
            scale=key.scale,
            process=key.process,
            dt_steps=clock.dt,
            phase=clock.phase,
            dt_seconds=clock.dt * simulation.timeline.base_step_seconds,
        ))
    end
    return rows
end

"""
    explain_domain_dependencies(simulation)

Return structured rows describing resolved cross-domain dependencies.
"""
function explain_domain_dependencies(simulation::DomainSimulation)
    rows = NamedTuple[]
    for ((consumer, name), producers) in simulation.dependency_bindings
        policy = simulation.dependency_policies[(consumer, name)]
        variable = simulation.dependency_variables[(consumer, name)]
        for producer in producers
            push!(rows, (
                mode=:value,
                consumer=consumer,
                dependency=name,
                producer=producer,
                variable=variable,
                policy=typeof(policy),
            ))
        end
    end
    for ((consumer, name), producers) in simulation.hard_domain_dependency_bindings
        for producer in producers
            push!(rows, (
                mode=:hard_domain,
                consumer=consumer,
                dependency=name,
                producer=producer,
                variable=nothing,
                policy=nothing,
            ))
        end
    end
    return rows
end

"""
    explain_routes(simulation)

Return structured rows describing resolved explicit cross-domain routes.
"""
function explain_routes(simulation::DomainSimulation)
    rows = NamedTuple[]
    for (i, route) in enumerate(simulation.mapping.routes)
        clock = simulation.route_clocks[i]
        for producer in simulation.route_bindings[i]
            push!(rows, (
                route=i,
                from=route.from,
                to=route.to,
                producer=producer,
                source_var=route.from.var,
                target_var=route.to.var,
                cardinality=typeof(route.cardinality),
                policy=typeof(route.policy),
                dt_steps=clock.dt,
                phase=clock.phase,
                dt_seconds=clock.dt * simulation.timeline.base_step_seconds,
            ))
        end
    end
    return rows
end

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

function _hard_domains_from_call_selector(selector::AbstractObjectMultiplicity)
    c = criteria(selector)
    unsupported = (:species, :name, :var, :relation, :within, :policy, :window)
    any(key -> haskey(c, key) && !isnothing(getproperty(c, key)), unsupported) && error(
        "Current `Calls(...)` hard-domain bridge only supports `kind`, `domain`, `scale`, and `process` selectors. ",
        "Unsupported selector criteria: $(filter(key -> haskey(c, key), unsupported))."
    )
    return HardDomains(
        kind=haskey(c, :kind) ? c.kind : nothing,
        domain=haskey(c, :domain) ? c.domain : nothing,
        scale=haskey(c, :scale) ? c.scale : nothing,
        process=haskey(c, :process) ? c.process : nothing,
    )
end

function _model_spec_dependency_selector(dep_name::Symbol, selector::Call)
    return _hard_domains_from_call_selector(selector.selector)
end

function _model_spec_dependency_selector(dep_name::Symbol, selector::AbstractObjectMultiplicity)
    return _hard_domains_from_call_selector(selector)
end

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

include("routes.jl")

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
        model_deps = dep(spec)
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
        model_deps = dep(spec)
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

include("route_runtime.jl")
include("environment_bridge.jl")
include("output_publisher.jl")
include("domain_scheduler.jl")
include("graph_domain_runner.jl")
include("domain_run_loops.jl")

function _build_domain_simulation(mapping::SimulationMapping, meteo; staged_graph_domains=false)
    environment = environment_backend(meteo)
    _validate_meteo_duration(environment)
    timeline = _timeline_context(environment)
    foreach(staged_graph_domains ? _validate_staged_domain_mapping : _validate_initial_domain_mapping, mapping.domains)
    specs = Dict{DomainModelKey,ModelSpec}()
    for domain in mapping.domains
        merge!(specs, _domain_model_specs(domain))
    end
    mapping = _add_input_routes(mapping, specs)
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

function _single_status_dependency_targets(ctx::DomainRunContext, producer::DomainModelKey)
    sim = ctx.simulation
    domain = _domain_for_name(sim.mapping, producer.domain)
    model_list = _single_scale_model_set_from_mapping(_domain_mapping(domain))
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

"""
    run_call!(target; kwargs...)
    run_call!(models, status, dependency_name; kwargs...)

Unified scene/object spelling for manually executing a model call handle.
This currently delegates to `run_target!` while `ModelTarget` remains the
runtime carrier for hard-domain calls.
"""
run_call!(args...; kwargs...) = run_target!(args...; kwargs...)

function _domain_context_for(simulation::DomainSimulation, domain::Domain, node::SoftDependencyNode, step::Int, constants=nothing)
    key = DomainModelKey(domain.name, node.scale, node.process)
    return DomainRunContext(simulation, key, step, simulation.model_clocks[key], constants)
end

function _run_domain_node!(
    simulation::DomainSimulation,
    domain::Domain,
    node::SoftDependencyNode,
    model_list::SingleScaleModelSet,
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
    model_list = _single_scale_model_set_from_mapping(mapping)
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
    return _run_single_status_domain_simulation!(simulation, constants, nsteps)
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
    return _run_staged_graph_domain_simulation!(
        simulation,
        object,
        raw_meteo,
        constants,
        nsteps;
        check=check,
        executor=executor,
        type_promotion=type_promotion,
    )
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

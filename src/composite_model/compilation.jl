"""
Immutable scenario-level metadata for one model application. Runtime object
membership is stored separately in [`CompiledModelApplication`](@ref).
"""
struct CompiledApplicationPlan{S,AT,TM,TS,CL,MO}
    slot::Int
    id::Symbol
    spec::S
    process::Symbol
    name::Union{Nothing,Symbol}
    applies_to::AT
    target_matcher::TM
    timestep::TS
    clock::CL
    model_overrides::MO
end

"""
Object-dependent runtime state for one compiled application.
"""
mutable struct CompiledModelApplication{P}
    const plan::P
    target_ids::Vector{ObjectId}
end

@inline function Base.getproperty(
    application::CompiledModelApplication,
    name::Symbol,
)
    name === :plan && return getfield(application, :plan)
    name === :target_ids && return getfield(application, :target_ids)
    plan = getfield(application, :plan)
    name === :slot && return getfield(plan, :slot)
    name === :id && return getfield(plan, :id)
    name === :spec && return getfield(plan, :spec)
    name === :process && return getfield(plan, :process)
    name === :name && return getfield(plan, :name)
    name === :applies_to && return getfield(plan, :applies_to)
    name === :target_matcher && return getfield(plan, :target_matcher)
    name === :timestep && return getfield(plan, :timestep)
    name === :clock && return getfield(plan, :clock)
    name === :model_overrides && return getfield(plan, :model_overrides)
    return getproperty(plan, name)
end

Base.propertynames(application::CompiledModelApplication) =
    (:plan, :target_ids, propertynames(application.plan)...)

"""Immutable authored input declaration for one application."""
struct CompiledModelInputPlan{SEL,M,OA,PSA,W}
    slot::Int
    application_slot::Int
    application_id::Symbol
    input::Symbol
    selector::SEL
    matcher::M
    origin::Symbol
    order_after_application_ids::OA
    source_var::Symbol
    process::Union{Nothing,Symbol}
    application::Union{Nothing,Symbol}
    multiplicity::Symbol
    potential_source_application_ids::PSA
    breaks_same_step_cycle::Bool
    window::W
end

"""Immutable authored hard-call declaration for one application."""
struct CompiledModelCallPlan{NAME,MODE,SEL,M,PCA}
    slot::Int
    application_slot::Int
    application_id::Symbol
    call::Symbol
    selector::SEL
    matcher::M
    origin::Symbol
    process::Union{Nothing,Symbol}
    application::Union{Nothing,Symbol}
    multiplicity::Symbol
    potential_callee_application_ids::PCA
end

function CompiledModelCallPlan(
    slot,
    application_slot,
    application_id,
    call::Symbol,
    mode::Symbol,
    selector,
    matcher,
    origin,
    process,
    application,
    multiplicity,
    potential_callee_application_ids,
)
    return CompiledModelCallPlan{
        call,
        mode,
        typeof(selector),
        typeof(matcher),
        typeof(potential_callee_application_ids),
    }(
        slot,
        application_slot,
        application_id,
        call,
        selector,
        matcher,
        origin,
        process,
        application,
        multiplicity,
        potential_callee_application_ids,
    )
end

_compiled_call_name(::CompiledModelCallPlan{NAME}) where {NAME} = NAME
@inline _compiled_call_mode(::CompiledModelCallPlan{NAME,MODE}) where {NAME,MODE} = MODE

"""Immutable authored cross-object output declaration for one application."""
struct CompiledModelOutputDestinationPlan{GROUP,SEL,M,D,C}
    slot::Int
    application_slot::Int
    application_id::Symbol
    group::Symbol
    selector::SEL
    matcher::M
    declarations::D
    multiplicity::Symbol
    coverage::C
end

function CompiledModelOutputDestinationPlan(
    slot,
    application_slot,
    application_id,
    group::Symbol,
    selector,
    matcher,
    declarations,
    multiplicity,
    coverage,
)
    return CompiledModelOutputDestinationPlan{
        group,
        typeof(selector),
        typeof(matcher),
        typeof(declarations),
        typeof(coverage),
    }(
        slot,
        application_slot,
        application_id,
        group,
        selector,
        matcher,
        declarations,
        multiplicity,
        coverage,
    )
end

"""Resolved destination membership before status references are constructed."""
struct ResolvedModelOutputDestination{P}
    plan::P
    execution_object_id::ObjectId
    destination_ids::Vector{ObjectId}
end

"""Compiled columnar references for one execution object and output group."""
mutable struct CompiledModelOutputDestinationBinding{P,C,I}
    const plan::P
    const execution_object_id::ObjectId
    destination_ids::Vector{ObjectId}
    columns::C
    destination_index::I
    membership_generation::UInt64
end

@inline function Base.getproperty(
    binding::CompiledModelOutputDestinationBinding,
    name::Symbol,
)
    name === :plan && return getfield(binding, :plan)
    name === :execution_object_id &&
        return getfield(binding, :execution_object_id)
    name === :destination_ids && return getfield(binding, :destination_ids)
    name === :columns && return getfield(binding, :columns)
    name === :destination_index &&
        return getfield(binding, :destination_index)
    name === :membership_generation &&
        return getfield(binding, :membership_generation)
    plan = getfield(binding, :plan)
    name === :slot && return getfield(plan, :slot)
    name === :application_slot && return getfield(plan, :application_slot)
    name === :application_id && return getfield(plan, :application_id)
    name === :group && return getfield(plan, :group)
    name === :selector && return getfield(plan, :selector)
    name === :matcher && return getfield(plan, :matcher)
    name === :declarations && return getfield(plan, :declarations)
    name === :multiplicity && return getfield(plan, :multiplicity)
    name === :coverage && return getfield(plan, :coverage)
    return getproperty(plan, name)
end

Base.propertynames(binding::CompiledModelOutputDestinationBinding) = (
    :plan,
    :execution_object_id,
    :destination_ids,
    :columns,
    :destination_index,
    :membership_generation,
    propertynames(binding.plan)...,
)

"""One declared owner of a status variable on a destination object."""
struct CompiledWriterOwner
    application_slot::Int
    application_id::Symbol
    execution_object_id::ObjectId
    group::Union{Nothing,Symbol}
    kind::Symbol
end

"""Zero-cost marker used when a scenario has no distributed outputs."""
struct NoCompiledDistributedOutputPlans end

"""Zero-cost marker used when a compiled scene has no distributed outputs."""
struct NoCompiledDistributedOutputs end

struct CompiledDistributedOutputPlans{P,I}
    plans::P
    by_application::I
end

struct CompiledDistributedOutputs{B,I,W,D}
    bindings::B
    by_execution_target::I
    writer_ownership::W
    destination_ids_by_application_variable::D
end

"""One immutable root-scheduler rule in stable topological order."""
struct CompiledApplicationScheduleEntry
    slot::Int
    application_slot::Int
    application_id::Symbol
    dt::Float64
    phase::Float64
    kind::Symbol
    period_steps::Union{Nothing,Int}
    phase_step::Union{Nothing,Int}
end

"""Immutable cadence definitions for root-scheduled applications."""
struct CompiledApplicationSchedule{E,A,P,G}
    entries::E
    always_entry_indices::A
    periodic_entry_indices::P
    generic_entry_indices::G
end

"""Reverse candidate index for compiled selector matchers."""
struct SelectorCandidateIndex{W,S,K,SP,N,A}
    wildcard::W
    by_scale::S
    by_kind::K
    by_species::SP
    by_name::N
    by_scope_anchor::A
end

function _selector_candidate_index()
    return SelectorCandidateIndex(
        Int[],
        Dict{Symbol,Vector{Int}}(),
        Dict{Symbol,Vector{Int}}(),
        Dict{Symbol,Vector{Int}}(),
        Dict{Symbol,Vector{Int}}(),
        Dict{ObjectId,Vector{Int}}(),
    )
end

function _freeze_selector_candidate_index(index::SelectorCandidateIndex)
    freeze(groups) = Dict(key => Tuple(values) for (key, values) in groups)
    return SelectorCandidateIndex(
        Tuple(index.wildcard),
        freeze(index.by_scale),
        freeze(index.by_kind),
        freeze(index.by_species),
        freeze(index.by_name),
        freeze(index.by_scope_anchor),
    )
end

_selector_candidate_values(value) = value isa Tuple ? value : (value,)

function _selector_scope_anchor(
    model::CompositeModel,
    matcher::CompiledSelectorMatcher;
    context=nothing,
    default_scope=nothing,
)
    scope = isnothing(matcher.scope) ? default_scope : matcher.scope
    scope isa CompiledNamedScope && return scope.root_id
    isnothing(context) && return nothing
    context_id = _object_id_from_context(context)
    scope isa Union{Self,Subtree} && return context_id
    if scope isa SelfPlant
        return _ancestor_id(
            model,
            context_id,
            :Plant,
            nothing,
            true,
        )
    elseif scope isa Ancestor
        return _ancestor_id(
            model,
            context_id,
            scope.scale,
            nothing,
            false,
        )
    end
    if isnothing(scope) && !isnothing(matcher.relation)
        relation = _compiled_relation_symbol(matcher.relation)
        relation in (:self, :children, :descendants) && return context_id
        relation in (:parent, :siblings) &&
            return _model_object(model, context_id).parent
    end
    return nothing
end

function _selector_candidate_destination(
    index::SelectorCandidateIndex,
    model::CompositeModel,
    matcher::CompiledSelectorMatcher;
    context=nothing,
    default_scope=nothing,
)
    scope = isnothing(matcher.scope) ? default_scope : matcher.scope
    if scope isa Self && isnothing(matcher.relation)
        return nothing
    end
    anchor = _selector_scope_anchor(
        model,
        matcher;
        context=context,
        default_scope=default_scope,
    )
    !isnothing(anchor) &&
        return (index.by_scope_anchor, (ObjectId(anchor),))
    for (groups, value) in (
        (index.by_name, matcher.name),
        (index.by_scale, matcher.scale),
        (index.by_kind, matcher.kind),
        (index.by_species, matcher.species),
    )
        isnothing(value) ||
            return (groups, _selector_candidate_values(value))
    end
    return (nothing, ())
end

function _index_selector_candidate!(
    index::SelectorCandidateIndex,
    model::CompositeModel,
    matcher::CompiledSelectorMatcher,
    candidate_index::Int;
    context=nothing,
    default_scope=nothing,
)
    destination = _selector_candidate_destination(
        index,
        model,
        matcher;
        context=context,
        default_scope=default_scope,
    )
    isnothing(destination) && return index
    groups, values = destination
    if isnothing(groups)
        push!(index.wildcard, candidate_index)
    else
        for value in values
            push!(get!(groups, value, Int[]), candidate_index)
        end
    end
    return index
end

function _union_selector_candidates!(
    candidates::Set{Int},
    index::SelectorCandidateIndex,
    model::CompositeModel,
    object_id::ObjectId,
)
    union!(candidates, index.wildcard)
    object = _model_object(model, object_id)
    for (groups, value) in (
        (index.by_name, object.name),
        (index.by_scale, object.scale),
        (index.by_kind, object.kind),
        (index.by_species, object.species),
    )
        isnothing(value) || union!(candidates, get(groups, value, ()))
    end
    for anchor in _object_ancestor_ids(model.registry, object_id)
        union!(candidates, get(index.by_scope_anchor, anchor, ()))
    end
    return candidates
end

function _application_target_candidate_index(model, application_plans)
    index = _selector_candidate_index()
    for plan in application_plans
        _index_selector_candidate!(
            index,
            model,
            plan.target_matcher,
            plan.slot,
        )
    end
    return _freeze_selector_candidate_index(index)
end

function _exact_schedule_integer(value::Float64)
    isfinite(value) && isinteger(value) || return nothing
    return try
        Int(value)
    catch
        nothing
    end
end

function _compiled_application_schedule(
    applications_by_id,
    application_order,
    manual_application_ids,
)
    entries = CompiledApplicationScheduleEntry[]
    always_entry_indices = Int[]
    periodic_entry_indices = Int[]
    generic_entry_indices = Int[]
    for application_id in application_order
        application_id in manual_application_ids && continue
        application = applications_by_id[application_id]
        dt = float(application.clock.dt)
        phase = float(application.clock.phase)
        dt > 0.0 || error("Clock interval must be positive, got $(dt).")
        period_steps = _exact_schedule_integer(dt)
        phase_step = _exact_schedule_integer(phase)
        kind = if dt <= 1.0
            :always
        elseif !isnothing(period_steps) && !isnothing(phase_step)
            :periodic_integer
        else
            :generic
        end
        push!(
            entries,
            CompiledApplicationScheduleEntry(
                length(entries) + 1,
                application.slot,
                application.id,
                dt,
                phase,
                kind,
                kind === :periodic_integer ? period_steps : nothing,
                kind === :periodic_integer ? phase_step : nothing,
            ),
        )
        entry_indices = if kind === :always
            always_entry_indices
        elseif kind === :periodic_integer
            periodic_entry_indices
        else
            generic_entry_indices
        end
        push!(entry_indices, length(entries))
    end
    return CompiledApplicationSchedule(
        Tuple(entries),
        Tuple(always_entry_indices),
        Tuple(periodic_entry_indices),
        Tuple(generic_entry_indices),
    )
end

"""
Immutable application, dependency-declaration, and timeline metadata shared by
every lifecycle refresh of a compiled scenario.
"""
struct CompiledScenarioPlan{AP,AI,ATI,IP,IPI,CP,CPI,DOP,CO,MA,AC,AO,OAP,AS,TL}
    applications::AP
    applications_by_id::AI
    application_target_candidates::ATI
    input_plans::IP
    input_plans_by_application::IPI
    call_plans::CP
    call_plans_by_application::CPI
    distributed_output_plans::DOP
    call_owners::CO
    manual_application_ids::MA
    application_children::AC
    application_order::AO
    ordered_application_plans::OAP
    application_schedule::AS
    timeline::TL
end

function _plans_by_application(applications, plans)
    application_ids = Tuple(application.id for application in applications)
    grouped = Tuple(
        Tuple(plan for plan in plans if plan.application_id == application.id)
        for application in applications
    )
    return NamedTuple{application_ids}(grouped)
end

function _applications_by_id(applications)
    application_ids = Tuple(application.id for application in applications)
    return NamedTuple{application_ids}(Tuple(applications))
end

function _scenario_call_owners(applications, call_plans)
    owners = Dict{Symbol,Set{Symbol}}()
    for plan in call_plans
        _compiled_call_mode(plan) === :manual || continue
        for callee_id in plan.potential_callee_application_ids
            push!(get!(owners, callee_id, Set{Symbol}()), plan.application_id)
        end
    end
    application_ids = Tuple(application.id for application in applications)
    return NamedTuple{application_ids}(
        Tuple(
            Tuple(
                application.id for application in applications
                if application.id in get(owners, callee_id, Set{Symbol}())
            )
            for callee_id in application_ids
        ),
    )
end

function _initializer_call_application_ids(call_plans)
    ids = Set{Symbol}()
    for plan in call_plans
        _compiled_call_mode(plan) === :initializer || continue
        union!(ids, plan.potential_callee_application_ids)
    end
    return ids
end

function _potential_initializer_output_writers(
    applications,
    initializer_application,
    variable::Symbol,
    distributed_output_plans,
)
    writers = Symbol[]
    for application in applications
        application.id == initializer_application.id && continue
        local_writer =
            variable in _model_canonical_output_names(application) &&
            _selector_labels_may_overlap(
                initializer_application.applies_to,
                application.applies_to,
            )
        distributed_writer = _application_declares_distributed_output(
            application,
            variable,
            initializer_application.applies_to,
            distributed_output_plans,
        )
        (local_writer || distributed_writer) && push!(writers, application.id)
    end
    return writers
end

function _validate_initializer_call_plans!(
    model::CompositeModel,
    applications,
    input_plans,
    call_plans,
    distributed_output_plans,
)
    initializer_plans = [
        plan for plan in call_plans
        if _compiled_call_mode(plan) === :initializer
    ]
    isempty(initializer_plans) && return nothing

    applications_by_id = _applications_by_id(applications)
    manual_application_ids = Set{Symbol}()
    for plan in call_plans
        _compiled_call_mode(plan) === :manual || continue
        union!(manual_application_ids, plan.potential_callee_application_ids)
    end
    initializer_owner = Dict{Symbol,Tuple{Symbol,Symbol}}()

    for plan in initializer_plans
        isnothing(plan.application) && error(
            "Initializer `$(plan.call)` on application `$(plan.application_id)` " *
            "must name one scheduled target with `application=...`.",
        )
        plan.selector isa One || error(
            "Initializer `$(plan.call)` on application `$(plan.application_id)` " *
            "must use `Initializer(One(...))`.",
        )
        length(plan.potential_callee_application_ids) == 1 || error(
            "Initializer `$(plan.call)` on application `$(plan.application_id)` " *
            "must resolve exactly one scheduled application, got " *
            "`$(plan.potential_callee_application_ids)`.",
        )
        callee_id = only(plan.potential_callee_application_ids)
        callee = applications_by_id[callee_id]
        callee.applies_to isa Many || error(
            "Initializer `$(plan.call)` targets application `$(callee_id)`, whose " *
            "`on=...` selector must be `Many(...)` so newly registered objects can " *
            "join its normal schedule.",
        )
        callee_id in manual_application_ids && error(
            "Application `$(callee_id)` cannot be both a manual-call-only target and " *
            "an initializer target. Remove the ordinary `Call` binding and keep one " *
            "`Initializer` binding.",
        )
        plan.application_id in manual_application_ids && error(
            "Initializer caller `$(plan.application_id)` is itself manual-call-only. " *
            "Nested manual/initializer execution is not supported; keep the creator " *
            "application root-scheduled.",
        )
        any(candidate -> candidate.application_id == callee_id, call_plans) && error(
            "Initializer target application `$(callee_id)` declares hard calls. " *
            "Nested calls from targeted newborn initialization are not supported.",
        )
        isempty(outputs_to(callee.spec)) || error(
            "Initializer target application `$(callee_id)` declares `outputs_to`. " *
            "Targeted newborn initialization supports canonical local outputs only.",
        )
        stream_only = Symbol[
            Symbol(variable) for variable in keys(outputs_(callee.spec))
            if _publish_mode_for_output(callee.spec, Symbol(variable)) === :stream_only
        ]
        isempty(stream_only) || error(
            "Initializer target application `$(callee_id)` has stream-only output(s) " *
            "`$(Tuple(stream_only))`. Initializer outputs must be canonical so the " *
            "new object enters the normal scheduled state.",
        )
        for variable in _model_canonical_output_names(callee)
            other_writers = _potential_initializer_output_writers(
                applications,
                callee,
                variable,
                distributed_output_plans,
            )
            isempty(other_writers) || error(
                "Initializer target application `$(callee_id)` must be the sole " *
                "canonical writer of output `$(variable)` on its possible newborn " *
                "targets. Potential overlapping writer application(s): " *
                "`$(Tuple(other_writers))`. Remove the overlapping local or " *
                "distributed writer instead of relying on `Updates` ordering after " *
                "targeted initialization.",
            )
        end
        backend = _environment_backend_from_config(
            model,
            environment_config(callee.spec),
        )
        (isnothing(backend) || backend isa GlobalConstant) || error(
            "Initializer target application `$(callee_id)` uses a non-global " *
            "environment backend `$(typeof(backend))`. Targeted newborn " *
            "initialization currently supports only the global environment.",
        )
        for input_plan in input_plans
            input_plan.application_id == callee_id || continue
            policy = _model_selector_policy(
                input_plan.selector,
                applications_by_id,
                input_plan.potential_source_application_ids,
                input_plan.source_var,
            )
            carrier_hint = _carrier_hint(
                input_plan.selector,
                policy,
                input_plan.window,
            )
            carrier_hint === :temporal_stream &&
                !(policy isa PreviousTimeStep) && error(
                "Initializer target application `$(callee_id)` input " *
                "`$(input_plan.input)` requires temporal policy `$(typeof(policy))`. " *
                "Only `PreviousTimeStep` is defined for a newborn target; use a " *
                "non-temporal input or `PreviousTimeStep(:$(input_plan.input))`.",
            )
        end
        for consumer_plan in input_plans
            consumer_plan.application_id == callee_id && continue
            callee_id in consumer_plan.potential_source_application_ids ||
                continue
            policy = _model_selector_policy(
                consumer_plan.selector,
                applications_by_id,
                consumer_plan.potential_source_application_ids,
                consumer_plan.source_var,
            )
            carrier_hint = _carrier_hint(
                consumer_plan.selector,
                policy,
                consumer_plan.window,
            )
            carrier_hint === :temporal_stream || continue
            error(
                "Initializer target application `$(callee_id)` may provide newborn " *
                "output `$(consumer_plan.source_var)` to temporal input " *
                "`$(consumer_plan.input)` on downstream application " *
                "`$(consumer_plan.application_id)`. Targeted initialization does " *
                "not publish a mid-step temporal sample, so downstream temporal " *
                "policies (including `PreviousTimeStep`) are unsupported. Use a " *
                "direct non-temporal input, or publish the value from a distinct " *
                "scheduled application so temporal consumers can use its history " *
                "on a later timestep.",
            )
        end
        if haskey(initializer_owner, callee_id)
            previous = initializer_owner[callee_id]
            error(
                "Scheduled application `$(callee_id)` has several initializer " *
                "bindings: `$(previous[2])` on `$(previous[1])` and " *
                "`$(plan.call)` on `$(plan.application_id)`. Declare one owner so " *
                "each newborn target can be initialized exactly once.",
            )
        end
        initializer_owner[callee_id] = (plan.application_id, plan.call)
    end
    return nothing
end

function _scenario_root_call_owners(
    call_owners,
    application_id::Symbol,
    path=(),
)
    application_id in path && error(
        "Composite model hard-call ownership cycle detected among applications ",
        "`$((path..., application_id))`.",
    )
    direct_owners = get(call_owners, application_id, ())
    isempty(direct_owners) && return (application_id,)
    roots = Symbol[]
    for owner_id in direct_owners
        append!(
            roots,
            _scenario_root_call_owners(
                call_owners,
                owner_id,
                (path..., application_id),
            ),
        )
    end
    unique!(roots)
    return Tuple(roots)
end

function _validate_scenario_call_ownership!(
    call_owners,
    manual_application_ids,
)
    for application_id in manual_application_ids
        _scenario_root_call_owners(call_owners, application_id)
    end
    return nothing
end

function _scenario_input_order_edges!(children, input_plans, call_owners)
    for plan in input_plans
        plan.breaks_same_step_cycle && continue
        ordering_sources = (
            plan.potential_source_application_ids...,
            plan.order_after_application_ids...,
        )
        for source_id in unique(ordering_sources)
            direct_owners = get(call_owners, source_id, ())
            if isempty(direct_owners)
                _add_model_application_edge!(
                    children,
                    source_id,
                    plan.application_id,
                )
            else
                for owner_id in _scenario_root_call_owners(
                    call_owners,
                    source_id,
                )
                    _add_model_application_edge!(
                        children,
                        owner_id,
                        plan.application_id,
                    )
                end
            end
        end
    end
    return children
end

function _scenario_initializer_order_edges!(
    children,
    input_plans,
    call_plans,
    call_owners,
)
    initializer_owners = Dict{Symbol,Symbol}(
        only(plan.potential_callee_application_ids) => plan.application_id
        for plan in call_plans
        if _compiled_call_mode(plan) === :initializer
    )
    for initializer in call_plans
        _compiled_call_mode(initializer) === :initializer || continue
        callee_id = only(initializer.potential_callee_application_ids)
        caller_id = initializer.application_id
        # Existing targets run in their normal application slot before the
        # creator. The creator then initializes only its newborn target.
        _add_model_application_edge!(children, callee_id, caller_id)
        # A same-step consumer of the initialized application's output must
        # also wait for object creation and targeted initialization.
        for input_plan in input_plans
            input_plan.breaks_same_step_cycle && continue
            ordering_sources = (
                input_plan.potential_source_application_ids...,
                input_plan.order_after_application_ids...,
            )
            callee_id in ordering_sources || continue
            execution_owners = if haskey(
                initializer_owners,
                input_plan.application_id,
            )
                (initializer_owners[input_plan.application_id],)
            else
                _scenario_root_call_owners(
                    call_owners,
                    input_plan.application_id,
                )
            end
            for owner_id in execution_owners
                owner_id == caller_id && continue
                _add_model_application_edge!(
                    children,
                    caller_id,
                    owner_id,
                )
            end
        end
    end
    return children
end

function _scenario_update_order_edges!(
    children,
    applications,
    manual_application_ids,
    ::NoCompiledDistributedOutputPlans,
)
    for (application_index, application) in pairs(applications)
        application.id in manual_application_ids && continue
        for update in updates(application.spec)
            after_labels = _update_after(update)
            isempty(after_labels) && continue
            for variable in _update_variables(update)
                for previous_application in applications[1:(application_index - 1)]
                    previous_application.id in manual_application_ids &&
                        continue
                    variable in _model_canonical_output_names(
                        previous_application,
                    ) || continue
                    _selector_labels_may_overlap(
                        previous_application.applies_to,
                        application.applies_to,
                    ) || continue
                    any(
                        label -> _update_matches_application(
                            label,
                            previous_application,
                        ),
                        after_labels,
                    ) || continue
                    _add_model_application_edge!(
                        children,
                        previous_application.id,
                        application.id,
                    )
                end
            end
        end
    end
    return children
end

function _application_output_selectors(
    application,
    variable::Symbol,
    plans::CompiledDistributedOutputPlans,
)
    selectors = Any[]
    variable in _model_canonical_output_names(application) &&
        push!(selectors, application.applies_to)
    for plan in _application_plans(plans.by_application, application.slot)
        variable in keys(plan.declarations) || continue
        push!(selectors, plan.selector)
    end
    return selectors
end

function _scenario_update_order_edges!(
    children,
    applications,
    manual_application_ids,
    plans::CompiledDistributedOutputPlans,
)
    for (application_index, application) in pairs(applications)
        application.id in manual_application_ids && continue
        for update in updates(application.spec)
            after_labels = _update_after(update)
            isempty(after_labels) && continue
            for variable in _update_variables(update)
                current_selectors = _application_output_selectors(
                    application,
                    variable,
                    plans,
                )
                isempty(current_selectors) && continue
                for previous_application in applications[1:(application_index - 1)]
                    previous_application.id in manual_application_ids && continue
                    any(
                        label -> _update_matches_application(
                            label,
                            previous_application,
                        ),
                        after_labels,
                    ) || continue
                    previous_selectors = _application_output_selectors(
                        previous_application,
                        variable,
                        plans,
                    )
                    any(
                        pair -> _selector_labels_may_overlap(pair[1], pair[2]),
                        Iterators.product(previous_selectors, current_selectors),
                    ) || continue
                    _add_model_application_edge!(
                        children,
                        previous_application.id,
                        application.id,
                    )
                end
            end
        end
    end
    return children
end

function _freeze_scenario_application_children(applications, children)
    application_ids = Tuple(application.id for application in applications)
    return NamedTuple{application_ids}(
        Tuple(
            Tuple(
                application.id for application in applications
                if application.id in get(
                    children,
                    parent_id,
                    Set{Symbol}(),
                )
            )
            for parent_id in application_ids
        ),
    )
end

function _compile_scenario_application_children(
    applications,
    input_plans,
    call_plans,
    call_owners,
    manual_application_ids,
    distributed_output_plans,
)
    children = Dict{Symbol,Set{Symbol}}()
    _scenario_input_order_edges!(children, input_plans, call_owners)
    _scenario_initializer_order_edges!(
        children,
        input_plans,
        call_plans,
        call_owners,
    )
    _scenario_update_order_edges!(
        children,
        applications,
        manual_application_ids,
        distributed_output_plans,
    )
    return _freeze_scenario_application_children(applications, children)
end

function _compiled_scenario_plan(
    model::CompositeModel,
    applications,
    input_plans,
    call_plans,
    distributed_output_plans,
    timeline,
)
    application_plans = Tuple(application.plan for application in applications)
    application_ids = Tuple(plan.id for plan in application_plans)
    _validate_initializer_call_plans!(
        model,
        applications,
        input_plans,
        call_plans,
        distributed_output_plans,
    )
    call_owners = _scenario_call_owners(applications, call_plans)
    manual_application_ids = Tuple(
        application.id for application in applications
        if !isempty(call_owners[application.id])
    )
    _validate_scenario_call_ownership!(
        call_owners,
        manual_application_ids,
    )
    application_children = _compile_scenario_application_children(
        applications,
        input_plans,
        call_plans,
        call_owners,
        manual_application_ids,
        distributed_output_plans,
    )
    application_order = _stable_topological_application_order(
        applications,
        application_children,
    )
    application_plans_by_id = NamedTuple{application_ids}(application_plans)
    application_schedule = _compiled_application_schedule(
        application_plans_by_id,
        application_order,
        manual_application_ids,
    )
    return CompiledScenarioPlan(
        application_plans,
        application_plans_by_id,
        _application_target_candidate_index(model, application_plans),
        Tuple(input_plans),
        _plans_by_application(applications, input_plans),
        Tuple(call_plans),
        _plans_by_application(applications, call_plans),
        distributed_output_plans,
        call_owners,
        manual_application_ids,
        application_children,
        Tuple(application_order),
        Tuple(
            application_plans_by_id[application_id]
            for application_id in application_order
        ),
        application_schedule,
        timeline,
    )
end

struct CompiledModelInputBinding{PL,P,C}
    plan::PL
    consumer_id::ObjectId
    source_ids::Vector{ObjectId}
    source_application_ids::Vector{Symbol}
    policy::P
    carrier_hint::Symbol
    carrier::C
end

@inline function Base.getproperty(
    binding::CompiledModelInputBinding,
    name::Symbol,
)
    name === :plan && return getfield(binding, :plan)
    name === :consumer_id && return getfield(binding, :consumer_id)
    name === :source_ids && return getfield(binding, :source_ids)
    name === :source_application_ids &&
        return getfield(binding, :source_application_ids)
    name === :policy && return getfield(binding, :policy)
    name === :carrier_hint && return getfield(binding, :carrier_hint)
    name === :carrier && return getfield(binding, :carrier)
    plan = getfield(binding, :plan)
    name === :slot && return getfield(plan, :slot)
    name === :application_slot && return getfield(plan, :application_slot)
    name === :application_id && return getfield(plan, :application_id)
    name === :input && return getfield(plan, :input)
    name === :selector && return getfield(plan, :selector)
    name === :matcher && return getfield(plan, :matcher)
    name === :origin && return getfield(plan, :origin)
    name === :order_after_application_ids &&
        return getfield(plan, :order_after_application_ids)
    name === :source_var && return getfield(plan, :source_var)
    name === :process && return getfield(plan, :process)
    name === :application && return getfield(plan, :application)
    name === :multiplicity && return getfield(plan, :multiplicity)
    name === :potential_source_application_ids &&
        return getfield(plan, :potential_source_application_ids)
    name === :breaks_same_step_cycle &&
        return getfield(plan, :breaks_same_step_cycle)
    name === :window && return getfield(plan, :window)
    return getproperty(plan, name)
end

Base.propertynames(binding::CompiledModelInputBinding) = (
    :plan,
    :consumer_id,
    :source_ids,
    :source_application_ids,
    :policy,
    :carrier_hint,
    :carrier,
    propertynames(binding.plan)...,
)

struct CompiledTemporalInput{B,S,I,R}
    binding::B
    source_applications::S
    initial::I
    reference::R
end

struct CompiledModelStatusView{S,C,T,P,BI}
    status::S
    canonical_status::C
    temporal_inputs::T
    private_outputs::P
    bound_inputs::BI
end

struct CompiledModelCallBinding{P}
    plan::P
    consumer_id::ObjectId
    callee_object_ids::Vector{ObjectId}
    callee_application_ids::Vector{Symbol}
end

@inline function Base.getproperty(
    binding::CompiledModelCallBinding,
    name::Symbol,
)
    name === :plan && return getfield(binding, :plan)
    name === :consumer_id && return getfield(binding, :consumer_id)
    name === :callee_object_ids && return getfield(binding, :callee_object_ids)
    name === :callee_application_ids &&
        return getfield(binding, :callee_application_ids)
    plan = getfield(binding, :plan)
    name === :slot && return getfield(plan, :slot)
    name === :application_slot && return getfield(plan, :application_slot)
    name === :application_id && return getfield(plan, :application_id)
    name === :call && return getfield(plan, :call)
    name === :mode && return _compiled_call_mode(plan)
    name === :selector && return getfield(plan, :selector)
    name === :matcher && return getfield(plan, :matcher)
    name === :origin && return getfield(plan, :origin)
    name === :process && return getfield(plan, :process)
    name === :application && return getfield(plan, :application)
    name === :multiplicity && return getfield(plan, :multiplicity)
    name === :potential_callee_application_ids &&
        return getfield(plan, :potential_callee_application_ids)
    return getproperty(plan, name)
end

Base.propertynames(binding::CompiledModelCallBinding) = (
    :plan,
    :consumer_id,
    :callee_object_ids,
    :callee_application_ids,
    :mode,
    propertynames(binding.plan)...,
)

@inline _compiled_call_name(binding::CompiledModelCallBinding) =
    _compiled_call_name(binding.plan)

@inline _compiled_call_mode(binding::CompiledModelCallBinding) =
    _compiled_call_mode(binding.plan)

struct CompiledEnvironmentSamplingRule{T,S} end

CompiledEnvironmentSamplingRule(target::Symbol, source::Symbol) =
    CompiledEnvironmentSamplingRule{target,source}()

struct CompiledEnvironmentApplicationPlan{B,C,RI,SI,PO,R,CR,S,P}
    application_id::Symbol
    backend::B
    config::C
    required_inputs::RI
    source_inputs::SI
    produced_outputs::PO
    sampling_rules::R
    compiled_sampling_rules::CR
    sampler::S
    prepared_source::P
    uses_raw_global_source::Bool
end

struct CompiledEnvironmentBinding{P,H,C}
    plan::P
    object_id::ObjectId
    handle::H
    context::C
    geometry_source_object_id::Union{Nothing,ObjectId}
    geometry_source::Symbol
end

@inline function Base.getproperty(
    binding::CompiledEnvironmentBinding,
    name::Symbol,
)
    name === :plan && return getfield(binding, :plan)
    name === :object_id && return getfield(binding, :object_id)
    name === :handle && return getfield(binding, :handle)
    name === :context && return getfield(binding, :context)
    name === :geometry_source_object_id &&
        return getfield(binding, :geometry_source_object_id)
    name === :geometry_source && return getfield(binding, :geometry_source)
    plan = getfield(binding, :plan)
    name === :application_id && return getfield(plan, :application_id)
    name === :backend && return getfield(plan, :backend)
    name === :config && return getfield(plan, :config)
    name === :required_inputs && return getfield(plan, :required_inputs)
    name === :source_inputs && return getfield(plan, :source_inputs)
    name === :produced_outputs && return getfield(plan, :produced_outputs)
    name === :sampling_rules && return getfield(plan, :sampling_rules)
    name === :compiled_sampling_rules &&
        return getfield(plan, :compiled_sampling_rules)
    name === :sampler && return getfield(plan, :sampler)
    name === :prepared_source && return getfield(plan, :prepared_source)
    name === :uses_raw_global_source &&
        return getfield(plan, :uses_raw_global_source)
    return getproperty(plan, name)
end

Base.propertynames(binding::CompiledEnvironmentBinding) = (
    :plan,
    :object_id,
    :handle,
    :context,
    :geometry_source_object_id,
    :geometry_source,
    propertynames(binding.plan)...,
)

struct CompiledEnvironmentBindings{SC,AP,API,B,I,PI,OI,C}
    model::SC
    application_plans::AP
    application_plans_by_id::API
    bindings::B
    by_target::I
    positions_by_target::PI
    targets_by_object::OI
    sample_cache::C
    model_revision::Int
    environment_revision::Int
    applications_identity::UInt
end

# Keep a stable heap identity at dynamic execution-batch boundaries. The
# scenario plan and application plans remain immutable values; only their
# runtime shell is reference-backed so passing it across a batch boundary does
# not box and copy the complete typed scenario-plan tuple.
mutable struct CompiledCompositeModel{SC,SP,AP,AI,OA,ABO,IB,CB,IBI,CBI,DBI,DCBI,MBC,DO,CO,AC,SVI,CE,CET,PA,AO}
    model::SC
    scenario_plan::SP
    applications::AP
    applications_by_id::AI
    ordered_applications::OA
    applications_by_object::ABO
    input_bindings::IB
    call_bindings::CB
    input_bindings_by_target::IBI
    call_bindings_by_target::CBI
    dynamic_input_binding_indices::DBI
    dynamic_call_binding_indices::DCBI
    many_input_binding_cache::MBC
    distributed_outputs::DO
    call_owners::CO
    application_children::AC
    status_views_by_target::SVI
    changed_execution_application_ids::CE
    changed_execution_target_ids::CET
    status_view_refresh_is_pure_addition::PA
    application_order::AO
    revision::Int
end

function _index_dynamic_bindings(model::CompositeModel, bindings)
    index = _selector_candidate_index()
    for (binding_index, binding) in pairs(bindings)
        binding.origin == :inferred_same_object && continue
        _index_selector_candidate!(
            index,
            model,
            binding.matcher,
            binding_index;
            context=binding.consumer_id,
            default_scope=_default_dependency_scope(
                model,
                binding.consumer_id,
            ),
        )
    end
    return index
end

_index_dynamic_input_bindings(model::CompositeModel, bindings) =
    _index_dynamic_bindings(model, bindings)

function _index_dynamic_call_bindings(model::CompositeModel, bindings)
    index = _selector_candidate_index()
    for (binding_index, binding) in pairs(bindings)
        _compiled_call_mode(binding) === :manual || continue
        binding.origin == :inferred_same_object && continue
        _index_selector_candidate!(
            index,
            model,
            binding.matcher,
            binding_index;
            context=binding.consumer_id,
            default_scope=_default_dependency_scope(
                model,
                binding.consumer_id,
            ),
        )
    end
    return index
end

function _index_model_bindings(bindings, application_field::Symbol, object_field::Symbol)
    grouped = Dict{Tuple{Symbol,ObjectId},Vector{Any}}()
    for binding in bindings
        key = (
            getproperty(binding, application_field),
            getproperty(binding, object_field),
        )
        push!(get!(grouped, key, Any[]), binding)
    end
    return Dict(key => Tuple(values) for (key, values) in grouped)
end

"""
    compile_composite_model(model[, applications...])

Compile model applications, selectors, value bindings, hard calls, writer
ordering, and schedules into the single Composite Model/Object runtime representation.
Most callers can use [`run!`](@ref) directly, which compiles as needed.
"""
function compile_composite_model(model::CompositeModel; performance=nothing)
    return compile_composite_model(
        model,
        model.applications;
        performance=performance,
    )
end

function compile_composite_model(
    model::CompositeModel,
    specs::Tuple;
    performance=nothing,
)
    return _compile_scene(model, specs; performance=performance)
end

function compile_composite_model(
    model::CompositeModel,
    specs::AbstractVector;
    performance=nothing,
)
    return _compile_scene(model, Tuple(specs); performance=performance)
end

function compile_composite_model(
    model::CompositeModel,
    specs...;
    performance=nothing,
)
    return _compile_scene(model, specs; performance=performance)
end

function _model_timeline(model::CompositeModel)
    backend = environment_backend(model.environment)
    _validate_environment_duration(backend)
    return _timeline_context(backend)
end

function _compile_scene(
    model::CompositeModel,
    raw_specs;
    validate_required_inputs::Bool=true,
    performance=nothing,
)
    started_at = _runtime_performance_start(performance)
    timeline = _model_timeline(model)
    applications = _compile_model_applications(model, raw_specs, timeline)
    _runtime_performance_finish!(
        performance,
        :application_target_compile,
        started_at,
    )
    started_at = _runtime_performance_start(performance)
    distributed_output_plans =
        _compile_model_output_destination_plans(model, applications)
    input_plans = _compile_model_input_plans(
        model,
        applications,
        distributed_output_plans,
    )
    call_plans = _compile_model_call_plans(model, applications)
    scenario_plan = _compiled_scenario_plan(
        model,
        applications,
        input_plans,
        call_plans,
        distributed_output_plans,
        timeline,
    )
    _runtime_performance_finish!(
        performance,
        :scenario_plan_compile,
        started_at,
    )
    started_at = _runtime_performance_start(performance)
    call_bindings = _compile_model_call_bindings(
        model,
        applications;
        plans_by_application=scenario_plan.call_plans_by_application,
    )
    _validate_model_call_plan_cadences!(
        applications,
        scenario_plan.call_plans,
        timeline,
    )
    _runtime_performance_finish!(
        performance,
        :call_binding_compile,
        started_at,
    )
    distributed_outputs = _compile_model_distributed_outputs(
        model,
        applications,
        scenario_plan.manual_application_ids,
        scenario_plan.distributed_output_plans,
    )
    started_at = _runtime_performance_start(performance)
    input_bindings = _compile_model_input_bindings(
        model,
        applications,
        scenario_plan.manual_application_ids,
        scenario_plan.input_plans_by_application,
        distributed_outputs,
    )
    many_input_binding_cache =
        _share_many_input_bindings!(model, input_bindings)
    _prepare_model_input_defaults!(model, applications)
    _wire_model_input_carriers!(model, input_bindings)
    validate_required_inputs &&
        _validate_model_required_inputs!(model, applications, input_bindings)
    _runtime_performance_finish!(
        performance,
        :input_binding_compile,
        started_at,
    )
    # Lifecycle refresh may replace an initially empty `Many(...)` carrier
    # with a concrete carrier type. Keep the per-target index type-stable
    # across that replacement so an updated compiled scene can be stored in
    # an existing `Simulation`.
    input_bindings_by_target = Dict{Any,Any}(
        _index_model_bindings(
            input_bindings,
            :application_id,
            :consumer_id,
        ),
    )
    call_bindings_by_target = _index_model_bindings(
        call_bindings,
        :application_id,
        :consumer_id,
    )
    call_owners = scenario_plan.call_owners
    application_children = scenario_plan.application_children
    application_order = scenario_plan.application_order
    applications_by_id = _applications_by_id(applications)
    ordered_applications = Tuple(
        applications_by_id[application_id]
        for application_id in application_order
    )
    started_at = _runtime_performance_start(performance)
    status_views_by_target = _compile_model_status_views(
        model,
        applications,
        applications_by_id,
        input_bindings_by_target,
        application_order,
        distributed_outputs,
    )
    _runtime_performance_finish!(
        performance,
        :status_view_compile,
        started_at,
    )
    return CompiledCompositeModel(
        model,
        scenario_plan,
        applications,
        applications_by_id,
        ordered_applications,
        _applications_by_object(applications),
        input_bindings,
        call_bindings,
        input_bindings_by_target,
        call_bindings_by_target,
        _index_dynamic_input_bindings(model, input_bindings),
        _index_dynamic_call_bindings(model, call_bindings),
        many_input_binding_cache,
        distributed_outputs,
        call_owners,
        application_children,
        status_views_by_target,
        Set(application.id for application in applications),
        Set(keys(status_views_by_target)),
        false,
        application_order,
        model.revision,
    )
end

function _new_application_targets(
    model::CompositeModel,
    compiled::CompiledCompositeModel,
    added_ids,
    performance=nothing,
)
    candidate_slots = Set{Int}()
    for object_id in added_ids
        _union_selector_candidates!(
            candidate_slots,
            compiled.scenario_plan.application_target_candidates,
            model,
            object_id,
        )
    end
    _runtime_performance_count!(
        performance,
        :selector_application_candidates,
        length(candidate_slots),
    )
    targets = Dict{Symbol,Vector{ObjectId}}()
    for slot in sort!(collect(candidate_slots))
        application = compiled.applications[slot]
        matched = ObjectId[
            object_id for object_id in added_ids
            if _selector_matches_object_id(
                model,
                application.target_matcher,
                object_id,
            )
        ]
        isempty(matched) && continue
        new_count = length(application.target_ids) + length(matched)
        if (application.applies_to isa One && new_count != 1) ||
           (application.applies_to isa OptionalOne && new_count > 1)
            return nothing
        end
        targets[application.id] = matched
    end
    return targets
end

function _sorted_object_id_position(ids, object_id::ObjectId)
    lower = firstindex(ids)
    upper = lastindex(ids)
    while lower <= upper
        middle = (lower + upper) >>> 1
        candidate = @inbounds ids[middle]
        candidate == object_id && return (true, middle)
        if _object_id_isless(candidate, object_id)
            lower = middle + 1
        else
            upper = middle - 1
        end
    end
    return (false, lower)
end

function _insert_with_spare_capacity!(values::Vector, position::Integer, value)
    old_length = length(values)
    1 <= position <= old_length + 1 ||
        throw(BoundsError(values, position))
    push!(values, value)
    position == old_length + 1 && return values
    copyto!(
        values,
        position + 1,
        values,
        position,
        old_length - position + 1,
    )
    values[position] = value
    return values
end

function _insert_sorted_object_ids!(ids, added_ids)
    isempty(added_ids) && return ids
    sizehint!(ids, length(ids) + length(added_ids))
    for object_id in added_ids
        found, position = _sorted_object_id_position(ids, object_id)
        found || _insert_with_spare_capacity!(ids, position, object_id)
    end
    return ids
end

function _compile_added_consumer_bindings!(
    bindings,
    model,
    application,
    consumer_id,
    input_plans,
    manual_application_ids,
    applications_by_object,
    applications_by_id,
    distributed_outputs=NoCompiledDistributedOutputs(),
)
    for plan in input_plans
        plan.origin == :inferred_same_object && continue
        _push_model_input_binding!(
            bindings,
            model,
            application,
            consumer_id,
            plan,
            applications_by_object,
            applications_by_id,
            nothing,
            distributed_outputs,
        )
    end
    application.id in manual_application_ids && return bindings
    processed_inputs = Set{Symbol}()
    for plan in input_plans
        plan.origin == :inferred_same_object || continue
        plan.input in processed_inputs && continue
        push!(processed_inputs, plan.input)
        matches = CompiledModelInputPlan[
            candidate for candidate in input_plans
            if candidate.origin == :inferred_same_object &&
               candidate.input == plan.input &&
               _application_writes_object_variable(
                   distributed_outputs,
                   applications_by_id[candidate.application],
                   consumer_id,
                   candidate.source_var,
               )
        ]
        matches = _final_inferred_output_plans(
            distributed_outputs,
            consumer_id,
            plan.source_var,
            matches,
        )
        isempty(matches) && continue
        if length(matches) > 1
            error(
                "Input `$(plan.input)` on application `$(application.id)` for object `$(consumer_id.value)` ",
                "has ambiguous same-object producers: `$([match.application for match in matches])`. ",
                "Add `inputs=(:$(plan.input) => One(...),)` to disambiguate."
            )
        end
        _push_model_input_binding!(
            bindings,
            model,
            application,
            consumer_id,
            only(matches),
            applications_by_object,
            applications_by_id,
            ObjectId[consumer_id],
            distributed_outputs,
        )
    end
    return bindings
end

_final_inferred_output_plans(
    ::NoCompiledDistributedOutputs,
    object_id,
    variable,
    matches,
) = matches

function _final_inferred_output_plans(
    distributed_outputs::CompiledDistributedOutputs,
    object_id::ObjectId,
    variable::Symbol,
    matches,
)
    owners = get(
        distributed_outputs.writer_ownership,
        (object_id, variable),
        (),
    )
    isempty(owners) && return matches
    final_application_id = last(owners).application_id
    final_matches = CompiledModelInputPlan[
        match for match in matches
        if match.application == final_application_id
    ]
    return isempty(final_matches) ? matches : final_matches
end

function _many_binding_scope_anchor(model::CompositeModel, binding::CompiledModelInputBinding)
    selector_criteria = criteria(binding.selector)
    !isnothing(_criteria_get(selector_criteria, :relation, nothing)) &&
        return (:consumer, binding.consumer_id)
    explicit_scope = _criteria_scope(selector_criteria)
    scope = isnothing(explicit_scope) ?
            _default_dependency_scope(model, binding.consumer_id) : explicit_scope
    if isnothing(scope) || scope isa SceneScope
        return (:scene,)
    elseif scope isa SelfPlant
        return (:plant, _ancestor_id(model, binding.consumer_id; scale=:Plant))
    elseif scope isa Scope
        return (:scope, scope.name)
    elseif scope isa Ancestor
        return (
            :ancestor,
            _ancestor_id(
                model,
                binding.consumer_id;
                scale=scope.scale,
                include_self=false,
            ),
        )
    end
    return (:consumer, binding.consumer_id)
end

function _many_binding_share_key(model::CompositeModel, binding::CompiledModelInputBinding)
    binding.multiplicity == :many || return nothing
    isnothing(binding.carrier) && return nothing
    return (
        binding.selector,
        _many_binding_scope_anchor(model, binding),
        binding.source_var,
        binding.process,
        binding.application,
        binding.carrier_hint,
        typeof(binding.carrier),
    )
end

function _binding_with_shared_many_sources(
    binding::CompiledModelInputBinding,
    canonical::CompiledModelInputBinding,
)
    return CompiledModelInputBinding(
        binding.plan,
        binding.consumer_id,
        canonical.source_ids,
        canonical.source_application_ids,
        binding.policy,
        binding.carrier_hint,
        canonical.carrier,
    )
end

function _share_many_input_binding!(cache, model::CompositeModel, binding)
    key = _many_binding_share_key(model, binding)
    isnothing(key) && return binding
    canonical = get(cache, key, nothing)
    if isnothing(canonical)
        cache[key] = binding
        return binding
    end
    if canonical.source_ids != binding.source_ids ||
       canonical.source_application_ids != binding.source_application_ids
        cache[(key, binding.consumer_id)] = binding
        return binding
    end
    return _binding_with_shared_many_sources(binding, canonical)
end

function _share_many_input_bindings!(model::CompositeModel, bindings; cache=Dict{Any,Any}())
    for index in eachindex(bindings)
        bindings[index] = _share_many_input_binding!(cache, model, bindings[index])
    end
    return cache
end

function _many_input_binding_cache(model::CompositeModel, bindings)
    cache = Dict{Any,Any}()
    for binding in bindings
        key = _many_binding_share_key(model, binding)
        isnothing(key) || haskey(cache, key) || (cache[key] = binding)
    end
    return cache
end

function _append_added_many_sources!(
    model::CompositeModel,
    binding::CompiledModelInputBinding,
    added_ids,
    applications_by_object,
)
    binding.multiplicity == :many || return false
    default_scope = _default_dependency_scope(model, binding.consumer_id)
    new_source_ids = ObjectId[
        object_id for object_id in added_ids if
        _selector_matches_object_id(
            model,
            binding.matcher,
            object_id;
            context=binding.consumer_id,
            default_to_context=true,
            default_scope=default_scope,
        ) && !(object_id in binding.source_ids)
    ]
    isempty(new_source_ids) && return true
    _sort_object_ids!(new_source_ids)

    # The growth path allocates monotonically increasing IDs. Appending preserves the
    # selector's stable order and, critically, keeps the carrier already installed in
    # the consumer status. Non-monotonic explicit IDs use the general rebuild path.
    if !isempty(binding.source_ids) &&
       !_object_id_isless(last(binding.source_ids), first(new_source_ids))
        return false
    end

    new_carrier = _input_carrier(model, binding.selector, new_source_ids, binding.source_var)
    isnothing(new_carrier) && return false
    existing_refs = parent(binding.carrier)
    new_refs = parent(new_carrier)
    eltype(new_refs) <: eltype(existing_refs) || return false
    append!(existing_refs, new_refs)
    append!(binding.source_ids, new_source_ids)

    new_application_ids = if _selector_from_status(binding.selector)
        Symbol[]
    else
        _matching_input_source_applications(
            applications_by_object,
            new_source_ids,
            binding.source_var,
            binding.process,
            binding.application;
            allow_empty=binding.selector isa OptionalOne,
        )
    end
    for application_id in new_application_ids
        application_id in binding.source_application_ids ||
            push!(binding.source_application_ids, application_id)
    end
    return true
end

function _update_structural_many_sources!(
    model::CompositeModel,
    binding::CompiledModelInputBinding,
    dirty_ids,
)
    binding.multiplicity == :many || return :fallback
    binding.carrier_hint == :ref_vector || return :fallback
    isnothing(binding.application) && return :fallback
    carrier_references = parent(binding.carrier)
    default_scope = _default_dependency_scope(model, binding.consumer_id)
    changes = Tuple{ObjectId,Bool,Any}[]
    for object_id in dirty_ids
        was_source, _ =
            _sorted_object_id_position(binding.source_ids, object_id)
        is_source = haskey(model.registry.objects, object_id) &&
                    _selector_matches_object_id(
            model,
            binding.matcher,
            object_id;
            context=binding.consumer_id,
            default_to_context=true,
            default_scope=default_scope,
        )
        was_source == is_source && continue
        source_reference = nothing
        if is_source
            source = _model_object(model, object_id)
            source_reference =
                _status_ref_or_nothing(source.status, binding.source_var)
            isnothing(source_reference) && return :fallback
            source_reference isa eltype(carrier_references) ||
                return :fallback
        end
        push!(changes, (object_id, is_source, source_reference))
    end
    for (object_id, is_source, source_reference) in changes
        was_source, position =
            _sorted_object_id_position(binding.source_ids, object_id)
        if was_source
            deleteat!(binding.source_ids, position)
            deleteat!(carrier_references, position)
        elseif is_source
            _insert_with_spare_capacity!(
                binding.source_ids,
                position,
                object_id,
            )
            _insert_with_spare_capacity!(
                carrier_references,
                position,
                source_reference,
            )
        end
    end
    return isempty(changes) ? :unchanged : :updated
end

function _preserve_temporal_input_state!(
    current::CompiledTemporalInput,
    previous::CompiledTemporalInput,
    previous_source_ids,
)
    if current.binding.multiplicity != :many ||
       previous.binding.multiplicity != :many
        current.reference[] = _private_temporal_value(previous.reference[])
        return CompiledTemporalInput(
            current.binding,
            current.source_applications,
            previous.initial,
            current.reference,
        )
    end

    current_initial = current.initial
    current_storage = current.reference[]
    previous_initial = previous.initial
    previous_storage = previous.reference[]
    previous_indices = Dict(
        object_id => index
        for (index, object_id) in pairs(previous_source_ids)
    )
    for (current_index, object_id) in pairs(current.binding.source_ids)
        previous_index = get(previous_indices, object_id, nothing)
        isnothing(previous_index) && continue
        current_initial[current_index] =
            _private_temporal_value(previous_initial[previous_index])
        current_storage[current_index] =
            _private_temporal_value(previous_storage[previous_index])
    end
    return CompiledTemporalInput(
        current.binding,
        current.source_applications,
        current_initial,
        current.reference,
    )
end

function _preserve_model_status_view_temporal_state!(
    current::CompiledModelStatusView,
    previous::CompiledModelStatusView,
    previous_temporal_sources,
    key,
)
    previous_by_input = Dict(
        temporal_input.binding.input => temporal_input
        for temporal_input in previous.temporal_inputs
    )
    temporal_inputs = Tuple(begin
        previous_input = get(
            previous_by_input,
            temporal_input.binding.input,
            nothing,
        )
        if isnothing(previous_input)
            temporal_input
        else
            previous_source_ids = get(
                previous_temporal_sources,
                (key..., temporal_input.binding.input),
                previous_input.binding.source_ids,
            )
            _preserve_temporal_input_state!(
                temporal_input,
                previous_input,
                previous_source_ids,
            )
        end
    end for temporal_input in current.temporal_inputs)
    temporal_by_name = Dict(
        temporal_input.binding.input => temporal_input
        for temporal_input in temporal_inputs
    )
    private_output_names = propertynames(current.private_outputs)
    private_output_references = ntuple(
        index -> begin
            name = private_output_names[index]
            return hasproperty(previous.private_outputs, name) ?
                   getproperty(previous.private_outputs, name) :
                   getproperty(current.private_outputs, name)
        end,
        length(private_output_names),
    )
    private_outputs =
        NamedTuple{private_output_names}(private_output_references)
    names = propertynames(current.status)
    references = ntuple(length(names)) do index
        name = names[index]
        temporal_input = get(temporal_by_name, name, nothing)
        isnothing(temporal_input) || return temporal_input.reference
        hasproperty(private_outputs, name) &&
            return getproperty(private_outputs, name)
        return refvalue(current.canonical_status, name)
    end
    status = Status(NamedTuple{names}(references))
    return CompiledModelStatusView(
        status,
        current.canonical_status,
        temporal_inputs,
        private_outputs,
        _rebind_compiled_bound_many_inputs(
            current.bound_inputs,
            status,
        ),
    )
end

function _preserve_recompiled_model_status_views!(
    current::CompiledCompositeModel,
    previous::CompiledCompositeModel,
)
    previous_temporal_sources = Dict{Tuple{Symbol,ObjectId,Symbol},Vector{ObjectId}}()
    for (key, current_view) in current.status_views_by_target
        previous_view = get(previous.status_views_by_target, key, nothing)
        isnothing(previous_view) && continue
        current.status_views_by_target[key] =
            _preserve_model_status_view_temporal_state!(
                current_view,
                previous_view,
                previous_temporal_sources,
                key,
            )
    end
    return current
end

function _extend_model_status_views(
    model::CompositeModel,
    compiled::CompiledCompositeModel,
    applications,
    applications_by_id,
    applications_by_object,
    input_bindings_by_target,
    application_order,
    new_targets,
    rewired_consumer_ids,
    affected_temporal_keys,
    previous_temporal_sources,
    previous_views=compiled.status_views_by_target,
)
    views = compiled.status_views_by_target
    affected_keys = Set{Tuple{Symbol,ObjectId}}(affected_temporal_keys)
    for application in applications
        for object_id in get(new_targets, application.id, ObjectId[])
            push!(affected_keys, (application.id, object_id))
        end
    end
    for object_id in rewired_consumer_ids
        for application in get(applications_by_object, object_id, ())
            push!(affected_keys, (application.id, object_id))
        end
    end

    positions = Dict(
        application_id => index
        for (index, application_id) in pairs(application_order)
    )
    for key in affected_keys
        application_id, object_id = key
        application = applications_by_id[application_id]
        previous_view = get(previous_views, key, nothing)
        if !isnothing(previous_view)
            for temporal_input in previous_view.temporal_inputs
                get!(
                    previous_temporal_sources,
                    (key..., temporal_input.binding.input),
                ) do
                    copy(temporal_input.binding.source_ids)
                end
            end
        end
        current_view = _compile_model_status_view(
            model,
            application,
            object_id,
            get(input_bindings_by_target, key, ()),
            applications_by_id,
            positions,
        )
        views[key] = isnothing(previous_view) ?
                     current_view :
                     _preserve_model_status_view_temporal_state!(
            current_view,
            previous_view,
            previous_temporal_sources,
            key,
        )
    end
    return views
end

function _append_added_many_call_targets!(
    model::CompositeModel,
    binding::CompiledModelCallBinding,
    added_ids,
    applications_by_object,
)
    binding.multiplicity == :many || return false
    default_scope = _default_dependency_scope(model, binding.consumer_id)
    new_target_ids = ObjectId[
        object_id for object_id in added_ids
        if _selector_matches_object_id(
            model,
            binding.matcher,
            object_id;
            context=binding.consumer_id,
            default_to_context=true,
            default_scope=default_scope,
        ) && !(object_id in binding.callee_object_ids)
    ]
    isempty(new_target_ids) && return true
    _sort_object_ids!(new_target_ids)

    # Monotonically increasing lifecycle IDs preserve the selector's compiled
    # stable order. Explicit non-monotonic IDs use the general rebuild path.
    if !isempty(binding.callee_object_ids) &&
       !_object_id_isless(
        last(binding.callee_object_ids),
        first(new_target_ids),
    )
        return false
    end

    append!(binding.callee_object_ids, new_target_ids)
    for object_id in new_target_ids
        for application_id in _matching_callee_applications(
            applications_by_object,
            object_id,
            binding.process,
            binding.application,
        )
            application_id in binding.callee_application_ids ||
                push!(binding.callee_application_ids, application_id)
        end
    end
    return true
end

function _prepare_structural_compiled_delta(
    model::CompositeModel,
    compiled::CompiledCompositeModel,
    dirty_object_ids,
    performance=nothing,
)
    started_at = _runtime_performance_start(performance)
    dirty = Set{ObjectId}(dirty_object_ids)
    removed_target_keys = Set{Tuple{Symbol,ObjectId}}()
    changed_application_ids = Set{Symbol}()
    applications_by_object = compiled.applications_by_object
    for object_id in dirty
        for application in get(applications_by_object, object_id, ())
            found, position = _sorted_object_id_position(
                application.target_ids,
                object_id,
            )
            found || continue
            push!(removed_target_keys, (application.id, object_id))
            push!(changed_application_ids, application.id)
            deleteat!(application.target_ids, position)
        end
    end

    for object_id in dirty
        delete!(applications_by_object, object_id)
    end

    input_bindings = CompiledModelInputBinding[]
    sizehint!(input_bindings, length(compiled.input_bindings))
    for binding in compiled.input_bindings
        if binding.consumer_id in dirty
            continue
        end
        push!(input_bindings, binding)
    end
    forced_input_binding_keys = Set{Tuple{Symbol,ObjectId,Symbol}}()
    previous_temporal_sources = Dict{
        Tuple{Symbol,ObjectId,Symbol},
        Vector{ObjectId},
    }()
    for binding in input_bindings
        any(dirty_id -> first(_sorted_object_id_position(binding.source_ids, dirty_id)), dirty) ||
            continue
        key = (binding.application_id, binding.consumer_id, binding.input)
        push!(forced_input_binding_keys, key)
        if binding.carrier_hint == :temporal_stream
            previous_temporal_sources[key] = copy(binding.source_ids)
        end
    end
    input_bindings_by_target = Dict{Any,Any}(
        _index_model_bindings(
            input_bindings,
            :application_id,
            :consumer_id,
        ),
    )

    call_bindings = CompiledModelCallBinding[]
    sizehint!(call_bindings, length(compiled.call_bindings))
    for binding in compiled.call_bindings
        key = (binding.application_id, binding.consumer_id)
        if binding.consumer_id in dirty
            continue
        end
        push!(call_bindings, binding)
    end
    forced_call_target_keys = Set{Tuple{Symbol,ObjectId}}()
    for binding in call_bindings
        any(
            dirty_id -> first(
                _sorted_object_id_position(
                    binding.callee_object_ids,
                    dirty_id,
                ),
            ),
            dirty,
        ) ||
            continue
        push!(
            forced_call_target_keys,
            (binding.application_id, binding.consumer_id),
        )
    end
    call_bindings_by_target = _index_model_bindings(
        call_bindings,
        :application_id,
        :consumer_id,
    )

    stripped = CompiledCompositeModel(
        model,
        compiled.scenario_plan,
        compiled.applications,
        compiled.applications_by_id,
        compiled.ordered_applications,
        applications_by_object,
        input_bindings,
        call_bindings,
        input_bindings_by_target,
        call_bindings_by_target,
        _index_dynamic_input_bindings(model, input_bindings),
        _index_dynamic_call_bindings(model, call_bindings),
        _many_input_binding_cache(model, input_bindings),
        compiled.distributed_outputs,
        compiled.call_owners,
        compiled.application_children,
        compiled.status_views_by_target,
        changed_application_ids,
        removed_target_keys,
        false,
        compiled.application_order,
        model.revision,
    )
    result = (
        compiled=stripped,
        forced_input_binding_keys=forced_input_binding_keys,
        forced_call_target_keys=forced_call_target_keys,
        previous_temporal_sources=previous_temporal_sources,
        changed_application_ids=changed_application_ids,
        changed_target_ids=removed_target_keys,
    )
    _runtime_performance_finish!(
        performance,
        :structural_delta_prepare,
        started_at,
    )
    return result
end

function _remove_stale_status_views!(
    compiled::CompiledCompositeModel,
    candidate_keys,
)
    for key in candidate_keys
        application_id, object_id = key
        application = compiled.applications_by_id[application_id]
        object_id in application.target_ids && continue
        delete!(compiled.status_views_by_target, key)
    end
    return compiled
end

function _extend_compiled_scene(
    model::CompositeModel,
    compiled::CompiledCompositeModel,
    added_objects;
    forced_input_binding_keys=Set{Tuple{Symbol,ObjectId,Symbol}}(),
    forced_call_target_keys=Set{Tuple{Symbol,ObjectId}}(),
    previous_views=compiled.status_views_by_target,
    previous_temporal_sources_seed=Dict{
        Tuple{Symbol,ObjectId,Symbol},
        Vector{ObjectId},
    }(),
    changed_application_ids_seed=Set{Symbol}(),
    changed_target_ids_seed=Set{Tuple{Symbol,ObjectId}}(),
    pure_addition::Bool=true,
    structural_dirty_ids=ObjectId[],
    performance=nothing,
)
    added_ids = ObjectId[id for id in added_objects if haskey(model.registry.objects, id)]
    started_at = _runtime_performance_start(performance)
    new_targets = _new_application_targets(
        model,
        compiled,
        added_ids,
        performance,
    )
    isnothing(new_targets) && return compile_composite_model(
        model,
        model.applications;
        performance=performance,
    )
    applications = compiled.applications
    applications_by_id = compiled.applications_by_id
    new_target_application_ids = sort!(
        collect(keys(new_targets));
        by=application_id -> applications_by_id[application_id].slot,
    )
    new_target_applications = Tuple(
        applications_by_id[application_id]
        for application_id in new_target_application_ids
    )
    for application in new_target_applications
        _insert_sorted_object_ids!(
            application.target_ids,
            new_targets[application.id],
        )
    end
    changed_application_ids = union(
        Set(new_target_application_ids),
        changed_application_ids_seed,
    )
    for application_id in changed_application_ids
        application = applications_by_id[application_id]
        if application.id in changed_application_ids_seed
            target_count = length(application.target_ids)
            if application.applies_to isa One && target_count != 1
                error(
                    "Lifecycle refresh left application `$(application.id)` with ",
                    "$(target_count) targets for a `One` selector.",
                )
            elseif application.applies_to isa OptionalOne && target_count > 1
                error(
                    "Lifecycle refresh left application `$(application.id)` with ",
                    "$(target_count) targets for an `OptionalOne` selector.",
                )
            end
        end
    end
    applications_by_object = compiled.applications_by_object
    for application in new_target_applications
        for object_id in new_targets[application.id]
            push!(get!(applications_by_object, object_id, Any[]), application)
        end
    end
    _runtime_performance_finish!(
        performance,
        :application_target_refresh,
        started_at,
    )

    started_at = _runtime_performance_start(performance)
    has_calls = !isempty(compiled.scenario_plan.call_plans)
    added_applications = CompiledModelApplication[
        CompiledModelApplication(
            application.plan,
            new_targets[application.id],
        )
        for application in new_target_applications
    ]
    rebuilt_existing_call_targets =
        Set{Tuple{Symbol,ObjectId}}(forced_call_target_keys)
    changed_call_target_keys =
        Set{Tuple{Symbol,ObjectId}}(forced_call_target_keys)
    if has_calls
        candidate_call_binding_indices = Set{Int}()
        for object_id in added_ids
            _union_selector_candidates!(
                candidate_call_binding_indices,
                compiled.dynamic_call_binding_indices,
                model,
                object_id,
            )
        end
        _runtime_performance_count!(
            performance,
            :selector_call_binding_candidates,
            length(candidate_call_binding_indices),
        )
        for binding_index in candidate_call_binding_indices
            binding = compiled.call_bindings[binding_index]
            _selector_matches_any_object_id(
                model,
                binding.matcher,
                added_ids;
                context=binding.consumer_id,
                default_to_context=true,
                default_scope=_default_dependency_scope(model, binding.consumer_id),
            ) || continue
            key = (binding.application_id, binding.consumer_id)
            push!(changed_call_target_keys, key)
            appended = key in forced_call_target_keys ?
                       false :
                       _append_added_many_call_targets!(
                model,
                binding,
                added_ids,
                applications_by_object,
            )
            appended || push!(rebuilt_existing_call_targets, key)
        end
    end
    new_call_bindings = has_calls ?
                        _compile_model_call_bindings(
        model,
        added_applications,
        applications,
        ;
        by_object=applications_by_object,
        plans_by_application=compiled.scenario_plan.call_plans_by_application,
    ) : CompiledModelCallBinding[]
    affected_call_applications = CompiledModelApplication[]
    if !isempty(rebuilt_existing_call_targets)
        target_ids_by_application = Dict{Symbol,Vector{ObjectId}}()
        for (application_id, object_id) in rebuilt_existing_call_targets
            push!(
                get!(
                    target_ids_by_application,
                    application_id,
                    ObjectId[],
                ),
                object_id,
            )
        end
        for application_id in sort!(
            collect(keys(target_ids_by_application));
            by=id -> applications_by_id[id].slot,
        )
            application = applications_by_id[application_id]
            target_ids = target_ids_by_application[application_id]
            _sort_object_ids!(target_ids)
            push!(
                affected_call_applications,
                CompiledModelApplication(
                    application.plan,
                    target_ids,
                ),
            )
        end
    end
    replacement_call_bindings = isempty(affected_call_applications) ?
                                CompiledModelCallBinding[] :
        _compile_model_call_bindings(
            model,
            affected_call_applications,
            applications;
            by_object=applications_by_object,
            plans_by_application=compiled.scenario_plan.call_plans_by_application,
        )
    replacement_call_bindings_by_target = _index_model_bindings(
        replacement_call_bindings,
        :application_id,
        :consumer_id,
    )
    call_bindings = compiled.call_bindings
    for key in rebuilt_existing_call_targets
        existing = get(compiled.call_bindings_by_target, key, ())
        replacements = get(replacement_call_bindings_by_target, key, ())
        length(existing) == length(replacements) || error(
            "Incremental hard-call refresh changed the number of declared calls ",
            "for application `$(first(key))` on object `$(last(key).value)`.",
        )
        for binding in existing
            replacement_index = findfirst(
                candidate ->
                    _compiled_call_name(candidate) ===
                    _compiled_call_name(binding),
                replacements,
            )
            isnothing(replacement_index) && error(
                "Incremental hard-call refresh lost declared call ",
                "`$(_compiled_call_name(binding))` for application ",
                "`$(first(key))` on object `$(last(key).value)`.",
            )
            replacement = replacements[replacement_index]
            empty!(binding.callee_object_ids)
            append!(binding.callee_object_ids, replacement.callee_object_ids)
            empty!(binding.callee_application_ids)
            append!(
                binding.callee_application_ids,
                replacement.callee_application_ids,
            )
        end
    end
    append!(call_bindings, new_call_bindings)
    dynamic_call_binding_indices = compiled.dynamic_call_binding_indices
    first_new_call_binding = length(call_bindings) - length(new_call_bindings) + 1
    for binding_index in first_new_call_binding:length(call_bindings)
        binding = call_bindings[binding_index]
        _compiled_call_mode(binding) === :manual || continue
        binding.origin == :inferred_same_object && continue
        _index_selector_candidate!(
            dynamic_call_binding_indices,
            model,
            binding.matcher,
            binding_index;
            context=binding.consumer_id,
            default_scope=_default_dependency_scope(
                model,
                binding.consumer_id,
            ),
        )
    end
    _validate_model_writers_for_objects!(
        applications,
        applications_by_object,
        added_ids,
        compiled.scenario_plan.manual_application_ids,
    )
    _prepare_model_output_statuses!(model, added_applications)
    _runtime_performance_finish!(
        performance,
        :call_binding_refresh,
        started_at,
    )

    started_at = _runtime_performance_start(performance)
    manual_application_ids = compiled.scenario_plan.manual_application_ids
    added_input_binding_capacity = sum(
        length(_model_input_names(application)) *
        length(application.target_ids)
        for application in added_applications;
        init=0,
    )
    input_bindings = compiled.input_bindings
    sizehint!(
        input_bindings,
        length(compiled.input_bindings) + added_input_binding_capacity,
    )
    # A `Many(...)` binding that starts empty is compiled with an untyped
    # `RefVector{Any}` carrier. Once matching objects are registered, the
    # refreshed carrier becomes concrete (for example `RefVector{Float64}`).
    # Keep this incremental index value-widened so that lifecycle refresh can
    # replace an initially empty binding without rebuilding the whole scene.
    input_bindings_by_target = compiled.input_bindings_by_target
    many_binding_cache = compiled.many_input_binding_cache
    changed_bindings = CompiledModelInputBinding[]
    rewired_consumer_ids = Set{ObjectId}()
    affected_temporal_keys = Set{Tuple{Symbol,ObjectId}}()
    previous_temporal_sources = copy(previous_temporal_sources_seed)
    processed_many_sources = IdDict{Any,Nothing}()
    previous_shared_many_sources = IdDict{Any,Vector{ObjectId}}()
    candidate_binding_indices = Set{Int}()
    if !isempty(forced_input_binding_keys)
        for (binding_index, binding) in pairs(input_bindings)
            key = (binding.application_id, binding.consumer_id, binding.input)
            key in forced_input_binding_keys &&
                push!(candidate_binding_indices, binding_index)
        end
    end
    for object_id in added_ids
        _union_selector_candidates!(
            candidate_binding_indices,
            compiled.dynamic_input_binding_indices,
            model,
            object_id,
        )
    end
    _runtime_performance_count!(
        performance,
        :selector_input_binding_candidates,
        length(candidate_binding_indices),
    )
    for index in candidate_binding_indices
        binding = input_bindings[index]
        force_rebuild =
            !isempty(forced_input_binding_keys) &&
            (
                binding.application_id,
                binding.consumer_id,
                binding.input,
            ) in forced_input_binding_keys
        if binding.multiplicity == :many && haskey(processed_many_sources, binding.source_ids)
            if binding.carrier_hint == :temporal_stream
                key = (binding.application_id, binding.consumer_id)
                push!(affected_temporal_keys, key)
                previous_temporal_sources[(
                    key...,
                    binding.input,
                )] = previous_shared_many_sources[binding.source_ids]
            end
            continue
        end
        previous_source_ids = binding.carrier_hint == :temporal_stream ?
                              copy(binding.source_ids) :
                              ObjectId[]
        binding.multiplicity == :many &&
            binding.carrier_hint == :temporal_stream &&
            (previous_shared_many_sources[binding.source_ids] = copy(binding.source_ids))
        default_scope = _default_dependency_scope(model, binding.consumer_id)
        if !pure_addition
            structural_update = _update_structural_many_sources!(
                model,
                binding,
                structural_dirty_ids,
            )
            if structural_update != :fallback
                processed_many_sources[binding.source_ids] = nothing
                continue
            end
        end
        if !force_rebuild
            _selector_matches_any_object_id(
                model,
                binding.matcher,
                added_ids;
                context=binding.consumer_id,
                default_to_context=true,
                default_scope=default_scope,
            ) || continue
        end
        appended_sources = if force_rebuild
            false
        else
            _append_added_many_sources!(
                model,
                binding,
                added_ids,
                applications_by_object,
            )
        end
        if appended_sources
            if binding.carrier_hint == :temporal_stream &&
               previous_source_ids != binding.source_ids
                key = (binding.application_id, binding.consumer_id)
                push!(affected_temporal_keys, key)
                previous_temporal_sources[(
                    key...,
                    binding.input,
                )] = previous_source_ids
            end
            processed_many_sources[binding.source_ids] = nothing
            continue
        end
        application = applications_by_id[binding.application_id]
        replacement = CompiledModelInputBinding[]
        _push_model_input_binding!(
            replacement,
            model,
            application,
            binding.consumer_id,
            binding.plan,
            applications_by_object,
            applications_by_id,
        )
        old_cache_key = _many_binding_share_key(model, binding)
        if !isnothing(old_cache_key) &&
           get(many_binding_cache, old_cache_key, nothing) === binding
            delete!(many_binding_cache, old_cache_key)
        end
        replacement_binding = _share_many_input_binding!(
            many_binding_cache,
            model,
            only(replacement),
        )
        input_bindings[index] = replacement_binding
        push!(changed_bindings, replacement_binding)
        push!(rewired_consumer_ids, binding.consumer_id)
        if binding.carrier_hint == :temporal_stream
            key = (binding.application_id, binding.consumer_id)
            push!(affected_temporal_keys, key)
            previous_temporal_sources[(
                key...,
                binding.input,
            )] = previous_source_ids
        end
        target = (binding.application_id, binding.consumer_id)
        input_bindings_by_target[target] = Tuple(
            existing === binding ? replacement_binding : existing
            for existing in get(input_bindings_by_target, target, ())
        )
    end
    previous_binding_count = length(input_bindings)
    for application in added_applications
        for consumer_id in application.target_ids
            first_new_binding = length(input_bindings) + 1
            _compile_added_consumer_bindings!(
                input_bindings,
                model,
                application,
                consumer_id,
                _application_plans(
                    compiled.scenario_plan.input_plans_by_application,
                    application.slot,
                ),
                manual_application_ids,
                applications_by_object,
                applications_by_id,
            )
            last_new_binding = length(input_bindings)
            if first_new_binding <= last_new_binding
                for binding_index in first_new_binding:last_new_binding
                    input_bindings[binding_index] = _share_many_input_binding!(
                        many_binding_cache,
                        model,
                        input_bindings[binding_index],
                    )
                end
                new_bindings = input_bindings[first_new_binding:last_new_binding]
                append!(changed_bindings, new_bindings)
                input_bindings_by_target[(application.id, consumer_id)] = Tuple(new_bindings)
            end
        end
    end
    dynamic_input_binding_indices = compiled.dynamic_input_binding_indices
    for binding_index in (previous_binding_count + 1):length(input_bindings)
        binding = input_bindings[binding_index]
        binding.origin == :inferred_same_object && continue
        _index_selector_candidate!(
            dynamic_input_binding_indices,
            model,
            binding.matcher,
            binding_index;
            context=binding.consumer_id,
            default_scope=_default_dependency_scope(
                model,
                binding.consumer_id,
            ),
        )
    end

    affected_input_applications = if pure_addition ||
                                     isempty(rewired_consumer_ids)
        Tuple(added_applications)
    else
        rewired_applications = CompiledModelApplication[]
        targets_by_application = Dict{Symbol,Vector{ObjectId}}()
        for object_id in rewired_consumer_ids
            for application in get(
                applications_by_object,
                object_id,
                (),
            )
                push!(
                    get!(
                        targets_by_application,
                        application.id,
                        ObjectId[],
                    ),
                    object_id,
                )
            end
        end
        for application_id in sort!(
            collect(keys(targets_by_application));
            by=id -> applications_by_id[id].slot,
        )
            application = applications_by_id[application_id]
            target_ids = targets_by_application[application_id]
            _sort_object_ids!(target_ids)
            push!(
                rewired_applications,
                CompiledModelApplication(
                    application.plan,
                    target_ids,
                ),
            )
        end
        (added_applications..., rewired_applications...)
    end
    _prepare_model_input_defaults!(model, affected_input_applications)
    _wire_model_input_carriers!(model, changed_bindings)
    _validate_model_required_inputs!(
        model,
        affected_input_applications,
        changed_bindings,
    )
    _runtime_performance_finish!(
        performance,
        :input_binding_refresh,
        started_at,
    )
    call_bindings_by_target = compiled.call_bindings_by_target
    isempty(new_call_bindings) || merge!(
        call_bindings_by_target,
        _index_model_bindings(
            new_call_bindings,
            :application_id,
            :consumer_id,
        ),
    )
    call_owners = compiled.scenario_plan.call_owners
    application_children = compiled.scenario_plan.application_children
    application_order = compiled.scenario_plan.application_order
    started_at = _runtime_performance_start(performance)
    status_views_by_target = _extend_model_status_views(
        model,
        compiled,
        applications,
        applications_by_id,
        applications_by_object,
        input_bindings_by_target,
        application_order,
        new_targets,
        rewired_consumer_ids,
        affected_temporal_keys,
        previous_temporal_sources,
        previous_views,
    )
    _runtime_performance_finish!(
        performance,
        :status_view_refresh,
        started_at,
    )
    changed_execution_target_ids = Set{Tuple{Symbol,ObjectId}}(
        (application_id, object_id)
        for (application_id, object_ids) in new_targets
        for object_id in object_ids
    )
    union!(
        changed_execution_target_ids,
        affected_temporal_keys,
    )
    union!(changed_execution_target_ids, changed_target_ids_seed)
    union!(changed_execution_target_ids, changed_call_target_keys)
    for object_id in rewired_consumer_ids
        union!(
            changed_execution_target_ids,
            (
                (application.id, object_id)
                for application in get(applications_by_object, object_id, ())
            ),
        )
    end
    changed_execution_application_ids = Set(
        first(key) for key in changed_execution_target_ids
    )
    union!(
        changed_execution_application_ids,
        changed_application_ids_seed,
    )
    status_view_refresh_is_pure_addition = pure_addition
    return CompiledCompositeModel(
        model,
        compiled.scenario_plan,
        applications,
        applications_by_id,
        compiled.ordered_applications,
        applications_by_object,
        input_bindings,
        call_bindings,
        input_bindings_by_target,
        call_bindings_by_target,
        dynamic_input_binding_indices,
        dynamic_call_binding_indices,
        many_binding_cache,
        compiled.distributed_outputs,
        call_owners,
        application_children,
        status_views_by_target,
        changed_execution_application_ids,
        changed_execution_target_ids,
        status_view_refresh_is_pure_addition,
        application_order,
        model.revision,
    )
end

function _validate_model_call_cadence!(
    caller,
    callee,
    call,
    timeline,
    mode::Symbol=:manual,
)
    # A call-only target with no model/scenario cadence declaration inherits
    # the cadence of its parent call. An explicit target cadence is a
    # scientific contract and must match the caller.
    mode === :manual &&
        _runtime_clock_source_for_spec(callee.spec) == :environment_base_step &&
        return nothing
    same_dt = isapprox(
        float(caller.clock.dt),
        float(callee.clock.dt);
        atol=1.0e-9,
        rtol=0.0,
    )
    same_phase = isapprox(
        float(caller.clock.phase),
        float(callee.clock.phase);
        atol=1.0e-9,
        rtol=0.0,
    )
    same_dt && same_phase && return nothing
    caller_seconds = float(caller.clock.dt) * timeline.base_step_seconds
    callee_seconds = float(callee.clock.dt) * timeline.base_step_seconds
    error(
        "Hard call `$(call)` from application `$(caller.id)` to ",
        "application `$(callee.id)` has incompatible cadence: caller=",
        "$(caller_seconds) seconds (phase=$(caller.clock.phase)), target=",
        "$(callee_seconds) seconds (phase=$(callee.clock.phase)). ",
        mode === :initializer ?
        "Initializer callers and their normally scheduled targets require exactly " *
        "matching cadence and phase." :
        "Use matching `ModelSpec(...; every=...)` declarations or omit `every` on the " *
        "manual-call-only target so it inherits the parent call cadence."
    )
end

function _validate_model_call_plan_cadences!(applications, call_plans, timeline)
    applications_by_id = _applications_by_id(applications)
    for plan in call_plans
        caller = applications_by_id[plan.application_id]
        for callee_id in plan.potential_callee_application_ids
            callee = applications_by_id[callee_id]
            _validate_model_call_cadence!(
                caller,
                callee,
                _compiled_call_name(plan),
                timeline,
                _compiled_call_mode(plan),
            )
        end
    end
    return nothing
end

function _validate_model_call_cadences!(applications, call_bindings, timeline)
    applications_by_id = _applications_by_id(applications)
    for binding in call_bindings
        caller = applications_by_id[binding.application_id]
        for callee_id in binding.callee_application_ids
            _validate_model_call_cadence!(
                caller,
                applications_by_id[callee_id],
                binding.call,
                timeline,
                _compiled_call_mode(binding),
            )
        end
    end
    return nothing
end

function _initialization_effective_value(
    model::CompositeModel,
    compiled::CompiledCompositeModel,
    application_id::Symbol,
    object_id::ObjectId,
    variable::Symbol,
)
    view = get(
        compiled.status_views_by_target,
        (application_id, object_id),
        nothing,
    )
    if !isnothing(view) && variable in propertynames(view.status)
        return true, view.status[variable]
    end
    status = _model_object(model, object_id).status
    if status isa Status && variable in propertynames(status)
        return true, status[variable]
    end
    return false, nothing
end

function _initialization_conversion_record(
    model::CompositeModel,
    application_id,
    object_id::ObjectId,
    variable::Symbol,
    origins,
)
    for origin in origins
        record = get(
            model.status_conversion_records,
            _status_conversion_record_key(
                variable;
                object_id=object_id,
                application_id=application_id,
                origin=origin,
            ),
            nothing,
        )
        record isa StatusConversionRecord && return record
    end
    record = get(
        model.status_conversion_records,
        _status_conversion_record_key(
            variable;
            object_id=object_id,
            origin=:supplied_status,
        ),
        nothing,
    )
    return record isa StatusConversionRecord ? record : nothing
end

function _initialization_conversion_fields(
    model::CompositeModel,
    compiled::CompiledCompositeModel,
    application_id::Symbol,
    object_id::ObjectId,
    variable::Symbol;
    declared_type=nothing,
    origins=(),
)
    record = _initialization_conversion_record(
        model,
        application_id,
        object_id,
        variable,
        origins,
    )
    has_effective, effective = _initialization_effective_value(
        model,
        compiled,
        application_id,
        object_id,
        variable,
    )
    effective_type = has_effective ? typeof(effective) : nothing
    original_type = isnothing(record) ? effective_type : record.original_type
    return (
        declared_type=declared_type,
        original_type=original_type,
        transformed_type=isnothing(record) ? original_type : record.transformed_type,
        effective_type=effective_type,
        status_transform_applied=!isnothing(record) && record.transform_applied,
        status_transform_changed=!isnothing(record) && record.transform_changed,
        type_mapping_applied=!isnothing(record) && record.mapping_applied,
        type_mapping_changed=!isnothing(record) && record.mapping_changed,
        type_mapping_rule=isnothing(record) ? nothing : record.mapping_rule,
    )
end

_no_initialization_conversion_fields(; declared_type=nothing) = (
    declared_type=declared_type,
    original_type=nothing,
    transformed_type=nothing,
    effective_type=nothing,
    status_transform_applied=false,
    status_transform_changed=false,
    type_mapping_applied=false,
    type_mapping_changed=false,
    type_mapping_rule=nothing,
)

"""
    explain_initialization(model::CompositeModel)

Return structured rows describing how every application variable is
initialized. `disposition` is one of:

- `:supplied`: present on the object's status before compilation;
- `:generated`: created from a model output declaration;
- `:producer_bound`: connected through an explicit or inferred `inputs` binding;
- `:environment_bound`: provided by the selected environment backend;
- `:unresolved`: still requires user or scenario configuration.

Unlike [`compile_composite_model`](@ref), this report does not fail solely because a
required status or environment value is unresolved. Selector, writer, call,
and other invalid configuration errors remain errors.
"""
function explain_initialization(model::CompositeModel)
    supplied = Dict(
        object.id => setdiff(
            Set{Symbol}(
                object.status isa Status ? Symbol.(propertynames(object.status)) : Symbol[]
            ),
            get(model.input_default_status_variables, object.id, Set{Symbol}()),
        )
        for object in values(model.registry.objects)
    )
    compiled = _compile_scene(
        model,
        Tuple(model.applications);
        validate_required_inputs=false,
    )
    bindings = Dict(
        (binding.application_id, binding.consumer_id, binding.input) => binding
        for binding in compiled.input_bindings
    )

    _, environment_plans_by_id = _compile_environment_application_plans(
        model,
        compiled.applications;
        prepare_runtime=false,
    )
    environment_bindings = Dict(
        (binding.application_id, binding.object_id) => binding
        for binding in _compile_environment_bindings(
            model,
            compiled,
            environment_plans_by_id,
        )
    )

    rows = NamedTuple[]
    for application in compiled.applications
        model_outputs = outputs_(application.spec)
        environment_model_outputs = environment_outputs_(application.spec)
        model_inputs = _input_schema(application.spec)
        environment_inputs = environment_inputs_(application.spec)
        generated = Set(Symbol.(keys(model_outputs)))
        for object_id in application.target_ids
            for variable in sort!(collect(generated); by=string)
                default_value = getproperty(model_outputs, variable)
                conversion = _initialization_conversion_fields(
                    model,
                    compiled,
                    application.id,
                    object_id,
                    variable;
                    declared_type=typeof(default_value),
                    origins=(
                        :model_output_default,
                        :stream_only_private_default,
                    ),
                )
                push!(rows, (
                    application_id=application.id,
                    object_id=object_id.value,
                    variable=variable,
                    role=:output,
                    disposition=:generated,
                    source_application_ids=Symbol[],
                    source_object_ids=Any[],
                    source_variable=nothing,
                    origin=:model_output,
                    expected_type=typeof(default_value),
                    default_value=default_value,
                    provided_type=nothing,
                    conversion...,
                    detail=nothing,
                ))
            end
            for variable in sort!(Symbol.(collect(keys(environment_model_outputs))); by=string)
                default_value = getproperty(environment_model_outputs, variable)
                conversion = _no_initialization_conversion_fields(
                    ; declared_type=typeof(default_value),
                )
                push!(rows, (
                    application_id=application.id,
                    object_id=object_id.value,
                    variable=variable,
                    role=:environment_output,
                    disposition=:declared,
                    source_application_ids=Symbol[],
                    source_object_ids=Any[],
                    source_variable=nothing,
                    origin=:environment_commit,
                    expected_type=typeof(default_value),
                    default_value=default_value,
                    provided_type=nothing,
                    conversion...,
                    detail=nothing,
                ))
            end
            for variable in sort!(Symbol.(collect(keys(model_inputs))); by=string)
                key = (application.id, object_id, variable)
                binding = get(bindings, key, nothing)
                declaration = getproperty(model_inputs, variable)
                binding_resolved =
                    !isnothing(binding) &&
                    !(binding.carrier_hint == :optional_default &&
                      isnothing(binding.carrier))
                missing_previous_initial =
                    binding_resolved &&
                    binding.policy isa PreviousTimeStep &&
                    declaration isa Required &&
                    !(variable in get(supplied, object_id, Set{Symbol}()))
                disposition = if missing_previous_initial
                    :required
                elseif binding_resolved
                    :producer_bound
                elseif variable in get(supplied, object_id, Set{Symbol}())
                    :supplied
                elseif declaration isa Default
                    :defaulted
                else
                    :required
                end
                default_value =
                    declaration isa Default ? declaration.value : nothing
                object = _model_object(model, object_id)
                provided_type = if disposition == :supplied
                    typeof(getproperty(object.status, variable))
                else
                    nothing
                end
                conversion = _initialization_conversion_fields(
                    model,
                    compiled,
                    application.id,
                    object_id,
                    variable;
                    declared_type=declaration isa Default ?
                                  typeof(default_value) :
                                  _input_expected_type(declaration),
                    origins=(:model_input_default,),
                )
                push!(rows, (
                    application_id=application.id,
                    object_id=object_id.value,
                    variable=variable,
                    role=:input,
                    disposition=disposition,
                    source_application_ids=binding_resolved ?
                                           copy(binding.source_application_ids) :
                                           Symbol[],
                    source_object_ids=binding_resolved ?
                                      [id.value for id in binding.source_ids] :
                                      Any[],
                    source_variable=binding_resolved ? binding.source_var : nothing,
                    origin=binding_resolved ?
                           binding.origin :
                           (disposition == :supplied ? :status :
                            disposition == :defaulted ? :model_default : :missing),
                    declaration=declaration isa Required ? :required : :defaulted,
                    expected_type=_input_expected_type(declaration),
                    default_value=default_value,
                    provided_type=provided_type,
                    conversion...,
                    detail=disposition == :required ?
                           "Provide `$(variable)` on object `$(object_id.value)` Status or add `inputs=(:$(variable) => ..., )` to application `$(application.id)`." :
                           nothing,
                ))
            end
            for variable in sort!(Symbol.(collect(keys(environment_inputs_(application.spec)))); by=string)
                environment_binding = get(
                    environment_bindings,
                    (application.id, object_id),
                    nothing,
                )
                source = get(
                    _environment_source_overrides(application.spec),
                    variable,
                    variable,
                )
                available = isnothing(environment_binding) ?
                            Set{Symbol}() :
                            environment_variables(environment_binding.backend)
                bound = isnothing(available) || Symbol(source) in available
                default_value = getproperty(environment_inputs, variable)
                conversion = _no_initialization_conversion_fields(
                    ; declared_type=typeof(default_value),
                )
                push!(rows, (
                    application_id=application.id,
                    object_id=object_id.value,
                    variable=variable,
                    role=:environment_input,
                    disposition=bound ? :environment_bound : :unresolved,
                    source_application_ids=Symbol[],
                    source_object_ids=Any[],
                    source_variable=Symbol(source),
                    origin=:environment,
                    expected_type=typeof(default_value),
                    default_value=default_value,
                    provided_type=nothing,
                    conversion...,
                    detail=bound ? nothing :
                           "Environment source `$(source)` is not available for this application/object.",
                ))
            end
        end
    end
    sort!(rows; by=row -> (
        string(row.application_id),
        string(row.object_id),
        string(row.role),
        string(row.variable),
    ))
    return rows
end

function _compile_model_applications(model::CompositeModel, raw_specs, timeline)
    specs = [as_model_spec(raw_spec) for raw_spec in raw_specs]
    process_counts = Dict{Symbol,Int}()
    for spec in specs
        proc = process(spec)
        process_counts[proc] = get(process_counts, proc, 0) + 1
    end
    ids = Set{Symbol}()
    applications = CompiledModelApplication[]
    for (slot, spec) in pairs(specs)
        selector = applies_to(spec)
        isnothing(selector) && error(
            "Model application for process `$(process(spec))` has no `ModelSpec(...; on=...)` selector."
        )
        selector isa AbstractObjectMultiplicity || error(
            "`ModelSpec(...; on=...)` for process `$(process(spec))` must use an object selector such as `Many(scale=:Leaf)`."
        )
        proc = process(spec)
        name = application_name(spec)
        if isnothing(name) && process_counts[proc] > 1
            error(
                "Composite model contains $(process_counts[proc]) unnamed applications for process `$(proc)`. ",
                "Give every repeated application a unique name with `ModelSpec(model; name=:application_name)`.",
            )
        end
        app_id = isnothing(name) ? proc : name
        app_id in ids && error("Duplicate compiled model application id `$(app_id)`.")
        push!(ids, app_id)
        target_matcher = _compile_selector_matcher(model, selector)
        target_ids = _resolve_object_ids(model, selector, target_matcher)
        sizehint!(target_ids, length(target_ids) + 1)
        spec = _model_spec_with_environment_hints(
            model,
            spec,
            _model_application_hint_scale(model, target_ids),
        )
        model_overrides = _compiled_object_model_overrides(spec, target_ids, app_id)
        push!(
            applications,
            CompiledModelApplication(
                CompiledApplicationPlan(
                    slot,
                    app_id,
                    spec,
                    proc,
                    name,
                    selector,
                    target_matcher,
                    timestep(spec),
                    _model_application_clock(
                        model,
                        spec,
                        target_ids,
                        timeline,
                    ),
                    model_overrides,
                ),
                target_ids,
            ),
        )
    end
    return applications
end

function _model_spec_with_environment_hints(model::CompositeModel, spec, scale::Symbol)
    hint = _normalize_environment_hint(scale, process(spec), environment_hint(model_(spec)))

    current_bindings = environment_bindings(spec)
    has_explicit_bindings = !(current_bindings isa NamedTuple && isempty(keys(current_bindings)))
    new_bindings = has_explicit_bindings || isnothing(hint.bindings) ? current_bindings : hint.bindings
    new_bindings = _model_environment_bindings_with_environment_sources(spec, new_bindings)

    current_window = environment_window(spec)
    new_window = isnothing(current_window) && !isnothing(hint.window) ? hint.window : current_window

    (new_bindings === current_bindings && new_window === current_window) && return spec
    return _replace_model_spec(
        spec;
        environment_bindings=new_bindings,
        environment_window=new_window,
    )
end

function _model_environment_bindings_with_environment_sources(spec, bindings)
    sources = _environment_source_overrides(spec)
    isempty(keys(sources)) && return bindings

    bindings = bindings isa NamedTuple ? bindings : NamedTuple()
    model_inputs = Set(Symbol.(keys(environment_inputs_(spec))))
    unknown = Symbol[target for target in keys(sources) if !(Symbol(target) in model_inputs)]
    isempty(unknown) || error(
        "`Environment(; sources=...)` for process `$(process(spec))` contains ",
        "unknown model-facing environment input(s) `$(Tuple(unknown))`. Declared ",
        "`environment_inputs_` are `$(Tuple(sort!(collect(model_inputs); by=string)))`."
    )

    targets = Symbol[Symbol(target) for target in keys(bindings)]
    for target in keys(sources)
        target = Symbol(target)
        target in targets || push!(targets, target)
    end

    resolved = Pair{Symbol,Any}[]
    for target in targets
        rule = haskey(bindings, target) ?
               _normalize_environment_binding_rule(target, bindings[target]) :
               (source=target, reducer=PlantMeteo.MeanWeighted())
        source = haskey(sources, target) ? Symbol(sources[target]) : rule.source
        push!(resolved, target => (source=source, reducer=rule.reducer))
    end
    return (; resolved...)
end

function _compiled_object_model_overrides(spec, target_ids, application_id::Symbol)
    model = model_(spec)
    model isa ObjectModelOverrides || return nothing
    target_set = Set(target_ids)
    unmatched = ObjectId[id for id in keys(model.overrides) if !(id in target_set)]
    isempty(unmatched) || error(
        "Object override(s) `$([id.value for id in unmatched])` for application ",
        "`$(application_id)` do not match its `on=...` target set."
    )
    return model.overrides
end

_application_default_model(application::CompiledModelApplication) =
    model_(application.spec) isa ObjectModelOverrides ?
    model_(application.spec).base :
    model_(application.spec)

function _application_model(application::CompiledModelApplication, object_id::ObjectId)
    isnothing(application.model_overrides) && return _application_default_model(application)
    return get(
        application.model_overrides,
        object_id,
        _application_default_model(application),
    )
end

function _model_output_names(application::CompiledModelApplication)
    return Symbol[Symbol(var) for var in keys(outputs_(application.spec))]
end

function _model_canonical_output_names(application::CompiledModelApplication)
    return Symbol[
        variable for variable in _model_output_names(application)
        if _publish_mode_for_output(application.spec, variable) == :canonical
    ]
end

function _model_writer_groups(applications, skipped_application_ids=Set{Symbol}())
    groups = Dict{Tuple{ObjectId,Symbol},Vector{Tuple{Int,Any}}}()
    for (index, application) in pairs(applications)
        application.id in skipped_application_ids && continue
        for object_id in application.target_ids
            for variable in _model_canonical_output_names(application)
                push!(get!(groups, (object_id, variable), Tuple{Int,Any}[]), (index, application))
            end
        end
    end
    return groups
end

function _application_match_labels(application::CompiledModelApplication)
    labels = Set{Symbol}([application.id])
    isnothing(application.name) || push!(labels, application.name)
    return labels
end

_update_matches_application(label::Symbol, application::CompiledModelApplication) =
    label == application.id

function _update_variables(update)
    return Tuple(Symbol(variable) for variable in getproperty(update, :variables))
end

function _update_after(update)
    return Tuple(Symbol(label) for label in getproperty(update, :after))
end

function _matching_updates(spec, variable::Symbol)
    return [update for update in updates(spec) if variable in _update_variables(update)]
end

function _update_after_labels(spec, variable::Symbol)
    labels = Symbol[]
    for update in _matching_updates(spec, variable)
        append!(labels, _update_after(update))
    end
    unique!(labels)
    return labels
end

function _updates_after_previous_writer(spec, variable::Symbol, previous_applications)
    matching = _matching_updates(spec, variable)
    isempty(matching) && return false
    for update in matching
        after = _update_after(update)
        isempty(after) && continue
        any(
            label -> any(application -> _update_matches_application(label, application), previous_applications),
            after,
        ) && return true
    end
    return false
end

function _declares_update_without_previous_writer(spec, variable::Symbol, previous_applications)
    isempty(previous_applications) || return false
    for update in _matching_updates(spec, variable)
        isempty(_update_after(update)) || return true
    end
    return false
end

function _manual_call_application_ids(call_bindings)
    ids = Set{Symbol}()
    for binding in call_bindings
        _compiled_call_mode(binding) === :manual || continue
        union!(ids, binding.callee_application_ids)
        isnothing(binding.application) || push!(ids, binding.application)
    end
    return ids
end

function _validate_model_writer_groups!(writer_groups)
    for ((object_id, variable), indexed_writers) in writer_groups
        length(indexed_writers) <= 1 && continue
        sort!(indexed_writers; by=first)
        previous = CompiledModelApplication[]
        for (_, application) in indexed_writers
            if _declares_update_without_previous_writer(application.spec, variable, previous)
                error(
                    "Application `$(application.id)` declares `Updates($(variable))` for object ",
                    "`$(object_id.value)`, but no previous writer for `$(variable)` exists. ",
                    "Move it after the producer named in `after=...`."
                )
            end
            if !isempty(previous) && isempty(_matching_updates(application.spec, variable))
                previous_labels = sort!(collect(reduce(union!, (_application_match_labels(app) for app in previous); init=Set{Symbol}())))
                error(
                    "Ambiguous canonical writers for variable `$(variable)` on object ",
                    "`$(object_id.value)`. ",
                    "applications. Application `$(application.id)` must declare ",
                    "`Updates(:$(variable); after=...)` matching one of the previous writers ",
                    "`$(previous_labels)`."
                )
            end
            if !isempty(previous) &&
               !_updates_after_previous_writer(
                   application.spec,
                   variable,
                   CompiledModelApplication[last(previous)],
               )
                previous_writer = last(previous)
                error(
                    "Application `$(application.id)` updates `$(variable)` on object ",
                    "`$(object_id.value)` without an ordering relation to the immediately ",
                    "previous writer `$(previous_writer.id)`. Add that application identifier ",
                    "to `Updates(:$(variable); after=...)`."
                )
            end
            push!(previous, application)
        end
    end
    return nothing
end

_resolve_model_output_destinations(
    ::CompositeModel,
    applications,
    ::NoCompiledDistributedOutputPlans,
) = ()

function _resolve_model_output_destinations(
    model::CompositeModel,
    applications,
    compiled_plans::CompiledDistributedOutputPlans,
)
    resolved = ResolvedModelOutputDestination[]
    for plan in compiled_plans.plans
        application = applications[plan.application_slot]
        for execution_object_id in application.target_ids
            destination_ids = _dependency_object_ids(
                model,
                plan.selector,
                plan.matcher,
                execution_object_id,
            )
            sizehint!(destination_ids, length(destination_ids) + 1)
            push!(
                resolved,
                ResolvedModelOutputDestination(
                    plan,
                    execution_object_id,
                    destination_ids,
                ),
            )
        end
    end
    return Tuple(resolved)
end

function _push_compiled_writer_owner!(
    ownership,
    object_id::ObjectId,
    variable::Symbol,
    owner::CompiledWriterOwner,
)
    push!(
        get!(
            ownership,
            (object_id, variable),
            CompiledWriterOwner[],
        ),
        owner,
    )
    return ownership
end

function _validate_compiled_writer_ownership!(ownership, applications)
    groups = Dict{Tuple{ObjectId,Symbol},Vector{Tuple{Int,Any}}}()
    for ((object_id, variable), owners) in ownership
        sort!(owners; by=owner -> owner.application_slot)
        seen_application_slots = Set{Int}()
        for owner in owners
            if owner.application_slot in seen_application_slots
                error(
                    "Application `$(owner.application_id)` declares more than one canonical " *
                    "writer for `$(variable)` on object `$(object_id.value)`. Ensure its " *
                    "`on=...` targets and named `outputs_to` destinations do not overlap.",
                )
            end
            push!(seen_application_slots, owner.application_slot)
            push!(
                get!(
                    groups,
                    (object_id, variable),
                    Tuple{Int,Any}[],
                ),
                (
                    owner.application_slot,
                    applications[owner.application_slot],
                ),
            )
        end
    end
    _validate_model_writer_groups!(groups)
    return ownership
end

function _compile_model_writer_ownership(
    applications,
    manual_application_ids,
    resolved_destinations,
)
    ownership = Dict{
        Tuple{ObjectId,Symbol},
        Vector{CompiledWriterOwner},
    }()
    for application in applications
        application.id in manual_application_ids && continue
        for object_id in application.target_ids
            for variable in _model_canonical_output_names(application)
                _push_compiled_writer_owner!(
                    ownership,
                    object_id,
                    variable,
                    CompiledWriterOwner(
                        application.plan.slot,
                        application.id,
                        object_id,
                        nothing,
                        :application_target,
                    ),
                )
            end
        end
    end
    for resolved in resolved_destinations
        plan = resolved.plan
        application = applications[plan.application_slot]
        for destination_id in resolved.destination_ids
            for variable_ in keys(plan.declarations)
                variable = Symbol(variable_)
                if destination_id in application.target_ids &&
                   variable in keys(outputs_(application.spec)) &&
                   _publish_mode_for_output(application.spec, variable) ==
                   :stream_only
                    error(
                        "Application `$(plan.application_id)` publishes stream-only local " *
                        "output `$(variable)` and distributes the same variable to its " *
                        "execution object `$(destination_id.value)`. Both publications " *
                        "would share one retained stream key; use distinct variable names " *
                        "or exclude the execution object from `outputs_to`.",
                    )
                end
                _push_compiled_writer_owner!(
                    ownership,
                    destination_id,
                    variable,
                    CompiledWriterOwner(
                        plan.application_slot,
                        plan.application_id,
                        resolved.execution_object_id,
                        plan.group,
                        :output_destination,
                    ),
                )
            end
        end
    end
    return _validate_compiled_writer_ownership!(ownership, applications)
end

function _validate_manual_model_output_destination_plans!(
    plans::CompiledDistributedOutputPlans,
    manual_application_ids,
)
    for plan in plans.plans
        plan.application_id in manual_application_ids || continue
        error(
            "Application `$(plan.application_id)` declares distributed outputs but is " *
            "manual-call-only. Distributed outputs on hard-called applications are not " *
            "supported yet; declare the application as root-scheduled instead.",
        )
    end
    return plans
end

function _validate_model_writers!(applications, call_bindings=())
    manual_application_ids = _manual_call_application_ids(call_bindings)
    return _validate_model_writer_groups!(
        _model_writer_groups(applications, manual_application_ids),
    )
end

function _validate_model_writers_for_objects!(
    applications,
    applications_by_object,
    object_ids,
    manual_application_ids=(),
)
    isempty(object_ids) && return nothing
    positions = Dict(
        application.id => index
        for (index, application) in pairs(applications)
    )
    groups = Dict{Tuple{ObjectId,Symbol},Vector{Tuple{Int,Any}}}()
    for object_id in object_ids
        for application in get(applications_by_object, object_id, ())
            application.id in manual_application_ids && continue
            for variable in _model_canonical_output_names(application)
                push!(
                    get!(
                        groups,
                        (object_id, variable),
                        Tuple{Int,Any}[],
                    ),
                    (positions[application.id], application),
                )
            end
        end
    end
    return _validate_model_writer_groups!(groups)
end

function _model_application_hint_scale(model::CompositeModel, target_ids::Vector{ObjectId})
    isempty(target_ids) && return :Scene
    scales = unique!([_model_object(model, object_id).scale for object_id in target_ids])
    length(scales) == 1 && return only(scales)
    return :Mixed
end

function _model_application_clock(model::CompositeModel, spec, target_ids::Vector{ObjectId}, timeline)
    process_model = model_(spec)
    source = _runtime_clock_source_for_spec(spec)
    source == :environment_base_step || return _model_clock(spec, process_model, timeline)
    scale = _model_application_hint_scale(model, target_ids)
    clock, hint_reason =
        _resolve_environment_hint_clock(scale, process(spec), process_model, timeline)
    isnothing(hint_reason) || error(hint_reason)
    return clock
end

function _criteria_get(criteria, key::Symbol, default=nothing)
    return haskey(criteria, key) ? getproperty(criteria, key) : default
end

function _selector_policy(selector::AbstractObjectMultiplicity)
    return _criteria_get(criteria(selector), :policy, HoldLast())
end

_selector_has_policy(selector::AbstractObjectMultiplicity) =
    haskey(criteria(selector), :policy)

function _model_policy_from_source_application(applications_by_id, application_id::Symbol, source_var::Symbol)
    application = get(applications_by_id, application_id, nothing)
    isnothing(application) && error(
        "No compiled model application with id `$(application_id)` while resolving ",
        "default output policy for `$(source_var)`."
    )
    return _policy_for_output(_application_default_model(application), source_var)
end

function _model_selector_policy(selector::AbstractObjectMultiplicity, applications_by_id, source_application_ids, source_var::Symbol)
    if _selector_has_policy(selector)
        policy = _selector_policy(selector)
        policy isa PreviousTimeStep && return policy
        return _as_schedule_policy(
            policy;
            context="model input policy for `$(source_var)`",
        )
    end
    isempty(source_application_ids) && return HoldLast()
    length(source_application_ids) == 1 && return _model_policy_from_source_application(
        applications_by_id,
        only(source_application_ids),
        source_var,
    )
    policies = [
        _model_policy_from_source_application(applications_by_id, application_id, source_var)
        for application_id in source_application_ids
    ]
    first_policy = first(policies)
    all(policy -> policy == first_policy, policies) && return first_policy
    error(
        "Cannot infer default policy for model input from `$(source_var)` because ",
        "selector resolves several source applications `$(source_application_ids)` with ",
        "different output policies. Add `policy=...` to the `inputs=...` selector."
    )
end

function _selector_window(selector::AbstractObjectMultiplicity)
    return _criteria_get(criteria(selector), :window, nothing)
end

function _selector_var(selector::AbstractObjectMultiplicity, fallback::Symbol)
    return _criteria_get(criteria(selector), :var, fallback)
end

function _selector_application(selector::AbstractObjectMultiplicity)
    return _criteria_get(criteria(selector), :application, nothing)
end

function _selector_from_status(selector::AbstractObjectMultiplicity)
    from_status = _criteria_get(criteria(selector), :from_status, false)
    from_status isa Bool || error(
        "Selector keyword `from_status` must be `true` or `false`, got `$(repr(from_status))`."
    )
    return from_status
end

function _selector_order_after(selector::AbstractObjectMultiplicity)
    after = _criteria_get(criteria(selector), :after, nothing)
    isnothing(after) && return Symbol[]
    values = after isa Union{Tuple,AbstractVector} ? after : (after,)
    applications = Symbol[Symbol(value) for value in values]
    isempty(applications) && error("Selector keyword `after` cannot be empty.")
    return unique!(applications)
end

function _validate_from_status_selector!(
    selector::AbstractObjectMultiplicity,
    process_filter,
    application_filter,
    applications_by_id,
    consumer_application_id,
)
    order_after = _selector_order_after(selector)
    if !_selector_from_status(selector)
        isempty(order_after) || error(
            "Selector keyword `after` is only supported with `from_status=true`. ",
            "Producer-bound inputs already derive their order from the selected application."
        )
        return order_after
    end
    isnothing(process_filter) || error(
        "`from_status=true` cannot be combined with `process=` because it deliberately ",
        "reads the selected objects' current Status without choosing a producer application."
    )
    isnothing(application_filter) || error(
        "`from_status=true` cannot be combined with `application=` because it deliberately ",
        "reads the selected objects' current Status without choosing a producer application."
    )
    _selector_has_policy(selector) && error(
        "`from_status=true` cannot be combined with a temporal `policy=`. Remove ",
        "`from_status=true` when reading a producer stream."
    )
    isnothing(_selector_window(selector)) || error(
        "`from_status=true` cannot be combined with `window=`. Status bindings are ",
        "same-step live references, not temporal streams."
    )
    for application_id in order_after
        application_id == consumer_application_id && error(
            "Status input on application `$(consumer_application_id)` cannot be ordered after itself."
        )
        haskey(applications_by_id, application_id) || error(
            "Status input on application `$(consumer_application_id)` requested ",
            "`after=$(repr(application_id))`, but no application with that id exists."
        )
    end
    return order_after
end

function _dependency_object_ids(
    model::CompositeModel,
    selector::AbstractObjectMultiplicity,
    matcher::CompiledSelectorMatcher,
    context::ObjectId,
)
    return _resolve_object_ids(
        model,
        selector,
        matcher;
        context=context,
        default_to_context=true,
        default_scope=_default_dependency_scope(model, context),
    )
end

function _carrier_hint(selector::AbstractObjectMultiplicity, policy, window)
    !isnothing(window) && return :temporal_stream
    policy isa HoldLast || return :temporal_stream
    selector isa Many && return :ref_vector
    return :shared_ref
end

function _status_ref_or_nothing(status, var::Symbol)
    status isa Status || return nothing
    var in propertynames(status) || return nothing
    return refvalue(status, var)
end

function _input_carrier(model::CompositeModel, selector::AbstractObjectMultiplicity, source_ids::Vector{ObjectId}, source_var::Symbol)
    refs = Base.RefValue[]
    selector isa Many && sizehint!(refs, length(source_ids) + 1)
    for source_id in source_ids
        object = _model_object(model, source_id)
        source_ref = _status_ref_or_nothing(object.status, source_var)
        isnothing(source_ref) && return nothing
        push!(refs, source_ref)
    end
    if selector isa Many
        isempty(refs) && return RefVector{Any}()
        return _ref_vector_carrier(refs)
    end
    return isempty(refs) ? nothing : only(refs)
end

function _has_stream_only_input_source(
    source_application_ids,
    source_var::Symbol,
    applications_by_id,
)
    return any(source_application_ids) do application_id
        application = applications_by_id[application_id]
        _publish_mode_for_output(application.spec, source_var) ==
            :stream_only
    end
end

function _stream_only_initial_reference(
    model::CompositeModel,
    source_id::ObjectId,
    source_application_ids,
    source_var::Symbol,
    applications_by_id,
)
    matching_applications = CompiledModelApplication[
        applications_by_id[application_id]
        for application_id in source_application_ids
        if source_id in applications_by_id[application_id].target_ids
    ]
    if length(matching_applications) == 1
        application = only(matching_applications)
        if _publish_mode_for_output(application.spec, source_var) ==
           :stream_only
            initial, _, _ = _materialize_status_value(
                model,
                source_var,
                getproperty(outputs_(application.spec), source_var);
                object_id=source_id,
                application_id=application.id,
                origin=:stream_only_source_default,
                private_copy=true,
                reuse=true,
            )
            return Ref(initial)
        end
    end
    return _status_ref_or_nothing(
        _model_object(model, source_id).status,
        source_var,
    )
end

function _stream_only_initial_carrier(
    model::CompositeModel,
    selector::AbstractObjectMultiplicity,
    source_ids,
    source_application_ids,
    source_var::Symbol,
    applications_by_id,
)
    references = Base.RefValue[]
    for source_id in source_ids
        reference = _stream_only_initial_reference(
            model,
            source_id,
            source_application_ids,
            source_var,
            applications_by_id,
        )
        isnothing(reference) && return nothing
        push!(references, reference)
    end
    if selector isa Many
        isempty(references) && return RefVector{Any}()
        return _ref_vector_carrier(references)
    end
    return isempty(references) ? nothing : only(references)
end

function _ref_vector_carrier(refs)
    T = typeof(refs[1][])
    typed_refs = Base.RefValue{T}[]
    sizehint!(typed_refs, length(refs) + 1)
    for source_ref in refs
        source_ref isa Base.RefValue{T} || return ObjectRefVector(refs)
        push!(typed_refs, source_ref)
    end
    return RefVector(typed_refs)
end

function _status_with_reference(status::Status, variable::Symbol, reference::Base.RefValue)
    names = propertynames(status)
    if variable in names
        references = ntuple(
            index -> names[index] == variable ? reference : refvalue(status, names[index]),
            length(names),
        )
        return Status(NamedTuple{names}(references))
    end
    extended_names = (names..., variable)
    references = (ntuple(index -> refvalue(status, names[index]), length(names))..., reference)
    return Status(NamedTuple{extended_names}(references))
end

function _status_with_default(
    model::CompositeModel,
    status::Status,
    object_id::ObjectId,
    variable::Symbol,
    value;
    application_id=nothing,
    origin=:model_default,
)
    variable in propertynames(status) && return status
    initial, _, _ = _materialize_status_value(
        model,
        variable,
        value;
        object_id=object_id,
        application_id=application_id,
        origin=origin,
        private_copy=true,
    )
    return _status_with_reference(status, variable, Ref(initial))
end

function _ensure_model_object_status!(model::CompositeModel, object_id::ObjectId)
    object = _model_object(model, object_id)
    isnothing(object.status) && _replace_model_object_status!(model, object, Status())
    object.status isa Status || error(
        "Model object `$(object_id.value)` uses model applications but its status has type ",
        "`$(typeof(object.status))`. Use `Status(...)` or leave status as `nothing`."
    )
    return object.status
end

function _prepare_model_output_statuses!(model::CompositeModel, applications)
    for application in applications
        defaults = outputs_(application.spec)
        for object_id in application.target_ids
            status = _ensure_model_object_status!(model, object_id)
            for (variable, value) in pairs(defaults)
                _publish_mode_for_output(application.spec, variable) ==
                    :canonical || continue
                status = _status_with_default(
                    model,
                    status,
                    object_id,
                    variable,
                    value;
                    application_id=application.id,
                    origin=:model_output_default,
                )
            end
            _replace_model_object_status!(model, object_id, status)
        end
    end
    return model
end

function _validate_required_model_output_destinations!(
    model::CompositeModel,
    resolved_destinations,
)
    missing = NamedTuple[]
    for resolved in resolved_destinations
        for destination_id in resolved.destination_ids
            for (variable_, declaration) in pairs(resolved.plan.declarations)
                declaration isa Required || continue
                variable = Symbol(variable_)
                _status_has_variable(model, destination_id, variable) && continue
                push!(
                    missing,
                    (
                        application_id=resolved.plan.application_id,
                        execution_object_id=resolved.execution_object_id.value,
                        group=resolved.plan.group,
                        destination_id=destination_id.value,
                        variable=variable,
                    ),
                )
            end
        end
    end
    isempty(missing) && return nothing
    details = join(
        [
            "`$(row.application_id).$(row.group)` requires `$(row.variable)` on " *
            "destination object `$(row.destination_id)`"
            for row in missing
        ],
        "; ",
    )
    error(
        "Missing required distributed-output destination variable(s): ",
        details,
        ". Add the variable to each destination `Status` or declare it with ",
        "`Default(value)` in `OutputTo(...; vars=...)`.",
    )
end

function _validate_model_output_destination_statuses!(
    model::CompositeModel,
    resolved_destinations,
)
    for resolved in resolved_destinations
        for destination_id in resolved.destination_ids
            status = _model_object(model, destination_id).status
            (isnothing(status) || status isa Status) && continue
            error(
                "Output destination `$(resolved.plan.application_id).$(resolved.plan.group)` " *
                "selected object `$(destination_id.value)` with status type " *
                "`$(typeof(status))`. Use `Status(...)` or leave status as `nothing`.",
            )
        end
    end
    return nothing
end

function _prepare_model_output_destination_statuses!(
    model::CompositeModel,
    resolved_destinations,
)
    staged = Dict{ObjectId,Status}()
    staged_order = ObjectId[]
    records_before = copy(model.status_conversion_records)
    try
        for resolved in resolved_destinations
            for destination_id in resolved.destination_ids
                status = get(staged, destination_id, nothing)
                if isnothing(status)
                    current = _model_object(model, destination_id).status
                    status = isnothing(current) ? Status() : current
                    status isa Status || error(
                        "Output destination `$(destination_id.value)` status must be " *
                        "a `Status` or `nothing`, got `$(typeof(status))`.",
                    )
                    push!(staged_order, destination_id)
                end
                for (variable_, declaration) in pairs(resolved.plan.declarations)
                    declaration isa Default || continue
                    variable = Symbol(variable_)
                    status = _status_with_default(
                        model,
                        status,
                        destination_id,
                        variable,
                        _input_default(declaration);
                        application_id=resolved.plan.application_id,
                        origin=:distributed_output_default,
                    )
                end
                staged[destination_id] = status
            end
        end
    catch
        empty!(model.status_conversion_records)
        merge!(model.status_conversion_records, records_before)
        rethrow()
    end
    for destination_id in staged_order
        _replace_model_object_status!(model, destination_id, staged[destination_id])
    end
    return model
end

function _model_output_destination_columns(
    model::CompositeModel,
    resolved::ResolvedModelOutputDestination,
)
    declarations = resolved.plan.declarations
    names = Tuple(Symbol.(keys(declarations)))
    columns = map(names) do variable
        refs = Base.RefValue[
            refvalue(
                _model_object(model, destination_id).status,
                variable,
            )
            for destination_id in resolved.destination_ids
        ]
        isempty(refs) ? RefVector{Any}() : _ref_vector_carrier(refs)
    end
    return NamedTuple{names}(Tuple(columns))
end

function _model_output_destination_index(destination_ids)
    index = Dict{ObjectId,Int}()
    sizehint!(index, length(destination_ids))
    for (position, object_id) in pairs(destination_ids)
        haskey(index, object_id) && error(
            "Compiled output destination membership contains duplicate object " *
            "ID `$(object_id.value)`.",
        )
        index[object_id] = position
    end
    return index
end

function _compile_model_output_destination_bindings(
    model::CompositeModel,
    resolved_destinations,
)
    bindings = Any[]
    sizehint!(bindings, length(resolved_destinations))
    by_execution_pairs = Dict{
        Tuple{Symbol,ObjectId},
        Vector{Pair{Symbol,Any}},
    }()
    for resolved in resolved_destinations
        binding = CompiledModelOutputDestinationBinding(
            resolved.plan,
            resolved.execution_object_id,
            resolved.destination_ids,
            _model_output_destination_columns(model, resolved),
            _model_output_destination_index(resolved.destination_ids),
            UInt64(model.revision),
        )
        push!(bindings, binding)
        push!(
            get!(
                by_execution_pairs,
                (
                    resolved.plan.application_id,
                    resolved.execution_object_id,
                ),
                Pair{Symbol,Any}[],
            ),
            resolved.plan.group => binding,
        )
    end
    by_execution_target = Dict{Tuple{Symbol,ObjectId},Any}()
    for (key, group_bindings) in by_execution_pairs
        names = Tuple(first(pair) for pair in group_bindings)
        values = Tuple(last(pair) for pair in group_bindings)
        by_execution_target[key] = NamedTuple{names}(values)
    end
    # Keep the cache shell type stable across lifecycle refreshes. Membership
    # can change both the number of bindings and an initially empty column's
    # concrete carrier type. Concrete bindings are installed on execution
    # targets later; the scene-wide lifecycle cache deliberately stays widened.
    return bindings, by_execution_target
end

function _index_model_output_destination_ids(bindings)
    index = Dict{Tuple{Symbol,Symbol},Vector{ObjectId}}()
    merged_keys = Set{Tuple{Symbol,Symbol}}()
    for binding in bindings
        for variable_ in keys(binding.declarations)
            variable = Symbol(variable_)
            key = (binding.application_id, variable)
            destination_ids = get(index, key, nothing)
            if isnothing(destination_ids)
                # Destination IDs are already sorted by the compiled selector.
                # Share that immutable membership in the common one-binding case.
                index[key] = binding.destination_ids
                continue
            end
            if !(key in merged_keys)
                destination_ids = copy(destination_ids)
                index[key] = destination_ids
                push!(merged_keys, key)
            end
            append!(destination_ids, binding.destination_ids)
        end
    end
    for key in merged_keys
        destination_ids = index[key]
        _sort_object_ids!(destination_ids)
        unique!(destination_ids)
    end
    return index
end

function _compile_model_distributed_outputs(
    model::CompositeModel,
    applications,
    manual_application_ids,
    ::NoCompiledDistributedOutputPlans,
)
    _validate_model_writer_groups!(
        _model_writer_groups(applications, manual_application_ids),
    )
    _prepare_model_output_statuses!(model, applications)
    return NoCompiledDistributedOutputs()
end

function _compile_model_distributed_outputs(
    model::CompositeModel,
    applications,
    manual_application_ids,
    plans::CompiledDistributedOutputPlans,
)
    _validate_manual_model_output_destination_plans!(
        plans,
        manual_application_ids,
    )
    resolved = _resolve_model_output_destinations(
        model,
        applications,
        plans,
    )
    ownership = _compile_model_writer_ownership(
        applications,
        manual_application_ids,
        resolved,
    )
    # All fallible ownership/required-state validation happens before any
    # status initialization, so an invalid declaration cannot leave partial
    # destination state behind.
    _validate_model_output_destination_statuses!(model, resolved)
    _validate_required_model_output_destinations!(model, resolved)
    _prepare_model_output_statuses!(model, applications)
    _prepare_model_output_destination_statuses!(model, resolved)
    bindings, by_execution_target =
        _compile_model_output_destination_bindings(model, resolved)
    return CompiledDistributedOutputs(
        bindings,
        by_execution_target,
        ownership,
        _index_model_output_destination_ids(bindings),
    )
end

function _prepare_model_input_defaults!(model::CompositeModel, applications)
    for application in applications
        schema = _input_schema(application.spec)
        defaults = _input_default_values(schema)
        for object_id in application.target_ids
            status = _ensure_model_object_status!(model, object_id)
            for (variable, value) in pairs(defaults)
                variable = Symbol(variable)
                variable in propertynames(status) && continue
                status = _status_with_default(
                    model,
                    status,
                    object_id,
                    variable,
                    value;
                    application_id=application.id,
                    origin=:model_input_default,
                )
                push!(
                    get!(
                        model.input_default_status_variables,
                        object_id,
                        Set{Symbol}(),
                    ),
                    variable,
                )
            end
            _replace_model_object_status!(model, object_id, status)
        end
    end
    return model
end

function _wire_model_input_carriers!(model::CompositeModel, bindings)
    for binding in bindings
        binding.carrier_hint == :temporal_stream && continue
        isnothing(binding.carrier) && continue
        object = _model_object(model, binding.consumer_id)
        status = object.status
        status isa Status || continue
        reference = binding.carrier isa Base.RefValue ? binding.carrier : Ref(binding.carrier)
        _replace_model_object_status!(
            model,
            object,
            _status_with_reference(status, binding.input, reference),
        )
        delete!(
            get!(
                model.input_default_status_variables,
                binding.consumer_id,
                Set{Symbol}(),
            ),
            binding.input,
        )
    end
    return model
end

function _private_temporal_value(value)
    value isa AbstractArray && return copy(value)
    return value
end

function _temporal_input_initial(binding::CompiledModelInputBinding, status::Status)
    initial = _input_value(binding.carrier)
    if isnothing(initial)
        binding.input in propertynames(status) || error(
            "Temporal input `$(binding.input)` on application ",
            "`$(binding.application_id)` has neither a resolved source carrier nor an ",
            "initialized status value. Resolved source objects: ",
            "`$(Tuple(id.value for id in binding.source_ids))`.",
        )
        initial = status[binding.input]
    end
    if binding.multiplicity == :many
        initial isa AbstractVector || error(
            "Temporal `Many` input `$(binding.input)` on application ",
            "`$(binding.application_id)` requires a vector-like initialized value; got ",
            "`$(typeof(initial))`.",
        )
        if length(initial) == length(binding.source_ids)
            return Any[_private_temporal_value(value) for value in initial]
        end
        binding.policy isa PreviousTimeStep && error(
            "Temporal `Many` input `$(binding.input)` on application ",
            "`$(binding.application_id)` resolved $(length(binding.source_ids)) source ",
            "objects but has $(length(initial)) initialized values.",
        )
        isempty(binding.source_ids) && return Any[]
        isempty(initial) && error(
            "Temporal `Many` input `$(binding.input)` on application ",
            "`$(binding.application_id)` needs an initialized element to preallocate ",
            "$(length(binding.source_ids)) temporal values.",
        )
        return Any[
            _private_temporal_value(first(initial))
            for _ in binding.source_ids
        ]
    end
    return _private_temporal_value(initial)
end

function _private_temporal_storage(binding::CompiledModelInputBinding, initial)
    binding.multiplicity == :many ||
        return _private_temporal_value(initial)
    isempty(initial) && return RefVector{Any}()
    references = Base.RefValue[Ref(_private_temporal_value(value)) for value in initial]
    return _ref_vector_carrier(references)
end

function _temporal_source_application(
    binding::CompiledModelInputBinding,
    source_id::ObjectId,
    applications_by_id,
    application_positions,
    distributed_outputs=NoCompiledDistributedOutputs(),
)
    isempty(binding.source_application_ids) && return nothing
    length(binding.source_application_ids) == 1 &&
        return only(binding.source_application_ids)
    matches = Symbol[
        application_id for application_id in binding.source_application_ids
        if _application_writes_object_variable(
            distributed_outputs,
            applications_by_id[application_id],
            source_id,
            binding.source_var,
        )
    ]
    canonical_application = _distributed_temporal_source_application(
        distributed_outputs,
        source_id,
        binding.source_var,
        matches,
    )
    isnothing(canonical_application) || return canonical_application
    if length(matches) == 1
        return only(matches)
    elseif isempty(matches)
        binding.policy isa PreviousTimeStep && return nothing
        error(
            "Temporal model input `$(binding.input)` from ",
            "`$(source_id.value).$(binding.source_var)` has no source application ",
            "matching object `$(source_id.value)`.",
        )
    elseif binding.policy isa PreviousTimeStep
        return last(sort!(matches; by=application_id -> application_positions[application_id]))
    end
    error(
        "Temporal model input `$(binding.input)` from ",
        "`$(source_id.value).$(binding.source_var)` has ambiguous source ",
        "applications `$(matches)`. Add `application=...` to the `inputs=...` selector.",
    )
end

_distributed_temporal_source_application(
    ::NoCompiledDistributedOutputs,
    ::ObjectId,
    ::Symbol,
    matches,
) = nothing

function _distributed_temporal_source_application(
    distributed_outputs::CompiledDistributedOutputs,
    source_id::ObjectId,
    source_var::Symbol,
    matches,
)
    isempty(matches) && return nothing
    matching_ids = Set(matches)
    owners = get(
        distributed_outputs.writer_ownership,
        (source_id, source_var),
        (),
    )
    for owner in Iterators.reverse(owners)
        owner.application_id in matching_ids && return owner.application_id
    end
    return nothing
end

function _validate_temporal_input_output_overlap!(
    application::CompiledModelApplication,
    temporal_bindings,
)
    output_names = Set(Symbol.(keys(outputs_(application.spec))))
    for binding in temporal_bindings
        binding.input in output_names || continue
        error(
            "Application `$(application.id)` declares `$(binding.input)` as both a ",
            "temporal input and an output. A temporal input uses application-local ",
            "storage while outputs publish through canonical status, so this overlap ",
            "is ambiguous. Use distinct names such as `previous_$(binding.input)` for ",
            "the lagged input and `$(binding.input)` for the current output, then map ",
            "the source explicitly.",
        )
    end
    return nothing
end

function _compile_model_status_view(
    model::CompositeModel,
    application::CompiledModelApplication,
    object_id::ObjectId,
    input_bindings,
    applications_by_id,
    application_positions,
    distributed_outputs=NoCompiledDistributedOutputs(),
)
    canonical_status = _ensure_model_object_status!(model, object_id)
    temporal_bindings = Tuple(
        binding for binding in input_bindings
        if binding.carrier_hint == :temporal_stream
    )
    _validate_temporal_input_output_overlap!(application, temporal_bindings)
    temporal_inputs = Tuple(begin
        initial = _temporal_input_initial(binding, canonical_status)
        CompiledTemporalInput(
            binding,
            Union{Nothing,Symbol}[
                _temporal_source_application(
                    binding,
                    source_id,
                    applications_by_id,
                    application_positions,
                    distributed_outputs,
                )
                for source_id in binding.source_ids
            ],
            initial,
            Ref(_private_temporal_storage(binding, initial)),
        )
    end for binding in temporal_bindings)
    temporal_by_name = Dict(
        temporal_input.binding.input => temporal_input
        for temporal_input in temporal_inputs
    )
    output_defaults = outputs_(application.spec)
    private_output_names = Tuple(
        Symbol(variable) for variable in keys(output_defaults)
        if _publish_mode_for_output(application.spec, variable) ==
           :stream_only
    )
    private_outputs = NamedTuple{private_output_names}(Tuple(begin
        initial, _, _ = _materialize_status_value(
            model,
            name,
            getproperty(output_defaults, name);
            object_id=object_id,
            application_id=application.id,
            origin=:stream_only_private_default,
            private_copy=true,
            reuse=true,
        )
        Ref(initial)
    end for name in private_output_names))
    canonical_names = propertynames(canonical_status)
    private_names = Tuple(
        name for name in private_output_names
        if !(name in canonical_names)
    )
    temporal_names = Tuple(
        input.binding.input
        for input in temporal_inputs
        if !(input.binding.input in canonical_names) &&
           !(input.binding.input in private_output_names)
    )
    names = (canonical_names..., private_names..., temporal_names...)
    references = ntuple(length(names)) do index
        name = names[index]
        temporal_input = get(temporal_by_name, name, nothing)
        isnothing(temporal_input) || return temporal_input.reference
        hasproperty(private_outputs, name) &&
            return getproperty(private_outputs, name)
        return refvalue(canonical_status, name)
    end
    status = Status(NamedTuple{names}(references))
    return CompiledModelStatusView(
        status,
        canonical_status,
        temporal_inputs,
        private_outputs,
        _compiled_bound_many_inputs(input_bindings, status),
    )
end

function _compile_model_status_views(
    model::CompositeModel,
    applications,
    applications_by_id,
    input_bindings_by_target,
    application_order,
    distributed_outputs=NoCompiledDistributedOutputs(),
)
    views = Dict{Tuple{Symbol,ObjectId},Any}()
    positions = Dict(
        application_id => index
        for (index, application_id) in pairs(application_order)
    )
    for application in applications
        for object_id in application.target_ids
            key = (application.id, object_id)
            views[key] = _compile_model_status_view(
                model,
                application,
                object_id,
                get(input_bindings_by_target, key, ()),
                applications_by_id,
                positions,
                distributed_outputs,
            )
        end
    end
    return views
end

input_carrier(binding::CompiledModelInputBinding) = binding.carrier
has_reference_carrier(binding::CompiledModelInputBinding) = !isnothing(binding.carrier)
input_value(binding::CompiledModelInputBinding) = _input_value(binding.carrier)
_input_value(::Nothing) = nothing
_input_value(carrier::Base.RefValue) = carrier[]
_input_value(carrier::RefVector) = carrier
_input_value(carrier::ObjectRefVector) = carrier

function _matching_input_source_applications(
    applications_by_object,
    source_ids,
    source_var::Symbol,
    process_filter,
    application_filter,
    distributed_outputs=NoCompiledDistributedOutputs();
    applications_by_id=nothing,
    allow_empty::Bool=false,
)
    matches = Symbol[]
    for source_id in source_ids
        for application in get(applications_by_object, source_id, Any[])
            source_var in _model_output_names(application) || continue
            isnothing(process_filter) || application.process == process_filter || continue
            isnothing(application_filter) || application.id == application_filter || continue
            push!(matches, application.id)
        end
        _append_distributed_input_source_applications!(
            matches,
            distributed_outputs,
            source_id,
            source_var,
            process_filter,
            application_filter,
            applications_by_id,
        )
    end
    unique!(matches)
    if !allow_empty &&
       (!isnothing(process_filter) || !isnothing(application_filter)) &&
       isempty(matches)
        error(
            "Input selector for source variable `$(source_var)` requested",
            isnothing(process_filter) ? "" : " process `$(process_filter)`",
            isnothing(application_filter) ? "" : " application `$(application_filter)`",
            ", but no matching source application was found."
        )
    end
    return matches
end

_append_distributed_input_source_applications!(
    matches,
    ::NoCompiledDistributedOutputs,
    args...,
) = matches

function _append_distributed_input_source_applications!(
    matches,
    distributed_outputs::CompiledDistributedOutputs,
    source_id::ObjectId,
    source_var::Symbol,
    process_filter,
    application_filter,
    applications_by_id,
)
    owners = get(
        distributed_outputs.writer_ownership,
        (source_id, source_var),
        (),
    )
    isempty(owners) && return matches
    for owner in owners
        isnothing(applications_by_id) && error(
            "Distributed output producer matching requires the compiled application index.",
        )
        application = get(applications_by_id, owner.application_id, nothing)
        isnothing(application) && continue
        isnothing(process_filter) ||
            application.process == process_filter || continue
        isnothing(application_filter) ||
            application.id == application_filter || continue
        push!(matches, application.id)
    end
    return matches
end

function _application_writes_object_variable(
    ::NoCompiledDistributedOutputs,
    application,
    object_id::ObjectId,
    variable::Symbol,
)
    return object_id in application.target_ids &&
           variable in _model_output_names(application)
end

function _application_writes_object_variable(
    distributed_outputs::CompiledDistributedOutputs,
    application,
    object_id::ObjectId,
    variable::Symbol,
)
    object_id in application.target_ids &&
        variable in _model_output_names(application) && return true
    return any(
        owner -> owner.application_id == application.id,
        get(distributed_outputs.writer_ownership, (object_id, variable), ()),
    )
end

_selector_constraint_values(value) =
    isnothing(value) ? () : value isa Tuple ? value : (value,)

# Scenario plans can disprove overlap only when immutable fixed-label domains
# are disjoint. Scope, topology, relations, and object membership may change at
# lifecycle barriers, so every unresolved case remains a potential overlap.
# Object-level multiplicity and writer ambiguity are still validated when
# concrete targets exist.
function _selector_labels_may_overlap(left, right)
    for key in (:scale, :kind, :species, :name)
        left_values = _selector_constraint_values(
            _criteria_value(criteria(left), key),
        )
        right_values = _selector_constraint_values(
            _criteria_value(criteria(right), key),
        )
        isempty(left_values) && continue
        isempty(right_values) && continue
        any(value -> value in right_values, left_values) || return false
    end
    return true
end

function _potential_input_source_application_ids(
    applications,
    consumer_application,
    selector,
    source_var::Symbol,
    process_filter,
    application_filter,
    origin::Symbol,
    distributed_output_plans,
)
    _selector_from_status(selector) && return ()
    source_selector = origin == :inferred_same_object ?
                      consumer_application.applies_to : selector
    return Tuple(
        application.id for application in applications
        if _application_may_output_variable(
               application,
               source_var,
               source_selector,
               distributed_output_plans,
           ) &&
           (isnothing(process_filter) ||
            application.process == process_filter) &&
           (isnothing(application_filter) ||
            application.id == application_filter)
    )
end

function _application_may_output_variable(
    application,
    variable::Symbol,
    source_selector,
    ::NoCompiledDistributedOutputPlans,
)
    return variable in _model_output_names(application) &&
           _selector_labels_may_overlap(
        source_selector,
        application.applies_to,
    )
end

function _application_may_output_variable(
    application,
    variable::Symbol,
    source_selector,
    plans::CompiledDistributedOutputPlans,
)
    variable in _model_output_names(application) &&
        _selector_labels_may_overlap(
            source_selector,
            application.applies_to,
        ) && return true
    return any(
        plan -> variable in keys(plan.declarations) &&
                _selector_labels_may_overlap(source_selector, plan.selector),
        _application_plans(plans.by_application, application.slot),
    )
end

_application_declares_distributed_output(
    application,
    variable::Symbol,
    source_selector,
    ::NoCompiledDistributedOutputPlans,
) = false

function _application_declares_distributed_output(
    application,
    variable::Symbol,
    source_selector,
    plans::CompiledDistributedOutputPlans,
)
    return any(
        plan -> variable in keys(plan.declarations) &&
                _selector_labels_may_overlap(source_selector, plan.selector),
        _application_plans(plans.by_application, application.slot),
    )
end

function _potential_call_application_ids(
    applications,
    selector,
    process_filter,
    application_filter,
)
    return Tuple(
        application.id for application in applications
        if (isnothing(process_filter) || application.process == process_filter) &&
           (isnothing(application_filter) || application.id == application_filter) &&
           _selector_labels_may_overlap(selector, application.applies_to)
    )
end

function _compiled_model_input_plan(
    plans,
    model,
    applications,
    application,
    input::Symbol,
    selector,
    origin::Symbol,
    applications_by_id,
    distributed_output_plans,
)
    source_var = _selector_var(selector, input)
    process_filter = _criteria_get(criteria(selector), :process, nothing)
    application_filter = _selector_application(selector)
    order_after_application_ids = _validate_from_status_selector!(
        selector,
        process_filter,
        application_filter,
        applications_by_id,
        application.id,
    )
    potential_source_application_ids =
        _potential_input_source_application_ids(
        applications,
        application,
        selector,
        source_var,
        process_filter,
        application_filter,
        origin,
        distributed_output_plans,
    )
    for producer_id in potential_source_application_ids
        _validate_model_variable_contract!(
            application,
            input,
            applications_by_id[producer_id],
            source_var,
        )
    end
    policy = _selector_has_policy(selector) ? _selector_policy(selector) : nothing
    breaks_same_step_cycle = policy isa PreviousTimeStep
    if breaks_same_step_cycle && policy.variable != input
        error(
            "PreviousTimeStep marker for input `$(input)` on application ",
            "`$(application.id)` names `$(policy.variable)`. Use ",
            "`PreviousTimeStep(:$(input))`."
        )
    end
    return CompiledModelInputPlan(
        length(plans) + 1,
        application.plan.slot,
        application.id,
        input,
        selector,
        _compile_selector_matcher(model, selector),
        origin,
        Tuple(order_after_application_ids),
        source_var,
        process_filter,
        application_filter,
        multiplicity(selector),
        potential_source_application_ids,
        breaks_same_step_cycle,
        _selector_window(selector),
    )
end

function _compile_model_input_plans(
    model::CompositeModel,
    applications,
    distributed_output_plans=_compile_model_output_destination_plans(
        model,
        applications,
    ),
)
    plans = CompiledModelInputPlan[]
    applications_by_id = Dict(
        application.id => application for application in applications
    )
    for application in applications
        _variable_contract_schema(application.spec)
        declared_inputs = value_inputs(application.spec)
        declared_inputs isa NamedTuple || (declared_inputs = NamedTuple())
        declared_names = Set(Symbol.(keys(declared_inputs)))
        for (input_name, selector) in pairs(declared_inputs)
            input = Symbol(input_name)
            _validate_declared_model_input_name!(application, input)
            selector isa AbstractObjectMultiplicity || error(
                "Input binding `$(input)` on application `$(application.id)` must use an object selector."
            )
            push!(
                plans,
                _compiled_model_input_plan(
                    plans,
                    model,
                    applications,
                    application,
                    input,
                    selector,
                    get(input_origins(application.spec), input, :model_spec),
                    applications_by_id,
                    distributed_output_plans,
                ),
            )
        end
        for input in _model_input_names(application)
            input in declared_names && continue
            for producer in applications
                producer.id == application.id && continue
                local_output = input in _model_canonical_output_names(producer) &&
                               _selector_labels_may_overlap(
                    application.applies_to,
                    producer.applies_to,
                )
                distributed_output = _application_declares_distributed_output(
                    producer,
                    input,
                    application.applies_to,
                    distributed_output_plans,
                )
                (local_output || distributed_output) || continue
                selector = One(
                    within=Self(),
                    process=producer.process,
                    application=producer.id,
                    var=input,
                )
                push!(
                    plans,
                    _compiled_model_input_plan(
                        plans,
                        model,
                        applications,
                        application,
                        input,
                        selector,
                        :inferred_same_object,
                        applications_by_id,
                        distributed_output_plans,
                    ),
                )
            end
        end
    end
    return plans
end

function _compile_model_call_plans(model::CompositeModel, applications)
    plans = CompiledModelCallPlan[]
    for application in applications
        calls = model_calls(application.spec)
        calls isa NamedTuple || continue
        for (call_name, declaration) in pairs(calls)
            call = Symbol(call_name)
            selector = _call_binding_selector(declaration)
            mode = _call_binding_mode(declaration)
            potential_callee_application_ids =
                _potential_call_application_ids(
                    applications,
                    selector,
                    _criteria_get(criteria(selector), :process, nothing),
                    _selector_application(selector),
                )
            push!(
                plans,
                CompiledModelCallPlan(
                    length(plans) + 1,
                    application.plan.slot,
                    application.id,
                    call,
                    mode,
                    selector,
                    _compile_selector_matcher(model, selector),
                    get(call_origins(application.spec), call, :model_spec),
                    _criteria_get(criteria(selector), :process, nothing),
                    _selector_application(selector),
                    multiplicity(selector),
                    potential_callee_application_ids,
                ),
            )
        end
    end
    return plans
end

function _compile_model_output_destination_plans(
    model::CompositeModel,
    applications,
)
    plans = CompiledModelOutputDestinationPlan[]
    for application in applications
        destinations = outputs_to(application.spec)
        destinations isa NamedTuple || continue
        for (group_name, destination) in pairs(destinations)
            selector = getproperty(destination, :selector)
            selector isa AbstractObjectMultiplicity || error(
                "Output destination `$(group_name)` on application `$(application.id)` " *
                "must use an object selector.",
            )
            push!(
                plans,
                CompiledModelOutputDestinationPlan(
                    length(plans) + 1,
                    application.plan.slot,
                    application.id,
                    Symbol(group_name),
                    selector,
                    _compile_selector_matcher(model, selector),
                    getproperty(destination, :vars),
                    multiplicity(selector),
                    getproperty(destination, :coverage),
                ),
            )
        end
    end
    isempty(plans) && return NoCompiledDistributedOutputPlans()
    return CompiledDistributedOutputPlans(
        Tuple(plans),
        _plans_by_application(applications, plans),
    )
end

_application_plans(plans_by_application, application_slot::Integer) =
    getfield(plans_by_application, application_slot)

function _potential_input_source_applications(
    applications_by_id,
    source_var::Symbol,
    process_filter,
    application_filter,
)
    matches = Symbol[
        application.id
        for application in values(applications_by_id)
        if _application_declares_output_name(application, source_var) &&
           (isnothing(process_filter) || application.process == process_filter) &&
           (isnothing(application_filter) || application.id == application_filter)
    ]
    sort!(matches)
    return matches
end

function _application_declares_output_name(application, variable::Symbol)
    variable in _model_output_names(application) && return true
    destinations = outputs_to(application.spec)
    destinations isa NamedTuple || return false
    return any(
        destination -> variable in keys(destination.vars),
        values(destinations),
    )
end

function _final_canonical_source_application(
    applications_by_object,
    source_ids,
    source_application_ids,
    source_var::Symbol,
    ::NoCompiledDistributedOutputs=NoCompiledDistributedOutputs(),
)
    length(source_ids) == 1 || return source_application_ids
    matching_ids = Set(source_application_ids)
    canonical_ids = Symbol[
        application.id
        for application in get(applications_by_object, only(source_ids), Any[])
        if application.id in matching_ids &&
           _publish_mode_for_output(application.spec, source_var) == :canonical
    ]
    isempty(canonical_ids) && return source_application_ids
    return Symbol[last(canonical_ids)]
end

function _final_canonical_source_application(
    applications_by_object,
    source_ids,
    source_application_ids,
    source_var::Symbol,
    distributed_outputs::CompiledDistributedOutputs,
)
    length(source_ids) == 1 || return source_application_ids
    matching_ids = Set(source_application_ids)
    owners = get(
        distributed_outputs.writer_ownership,
        (only(source_ids), source_var),
        (),
    )
    canonical_ids = Symbol[
        owner.application_id for owner in owners
        if owner.application_id in matching_ids
    ]
    isempty(canonical_ids) && return _final_canonical_source_application(
        applications_by_object,
        source_ids,
        source_application_ids,
        source_var,
        NoCompiledDistributedOutputs(),
    )
    return Symbol[last(canonical_ids)]
end

function _compile_model_input_bindings(
    model::CompositeModel,
    applications,
    manual_application_ids=Set{Symbol}(),
    plans_by_application=nothing,
    distributed_outputs=NoCompiledDistributedOutputs(),
)
    if isnothing(plans_by_application)
        plans_by_application = _plans_by_application(
            applications,
            _compile_model_input_plans(model, applications),
        )
    end
    bindings = CompiledModelInputBinding[]
    by_object = _applications_by_object(applications)
    by_id = Dict(application.id => application for application in applications)
    for application in applications
        for consumer_id in application.target_ids
            _compile_added_consumer_bindings!(
                bindings,
                model,
                application,
                consumer_id,
                _application_plans(plans_by_application, application.slot),
                manual_application_ids,
                by_object,
                by_id,
                distributed_outputs,
            )
        end
    end
    return bindings
end

function _push_model_input_binding!(
    bindings,
    model::CompositeModel,
    application::CompiledModelApplication,
    consumer_id::ObjectId,
    plan::CompiledModelInputPlan,
    applications_by_object,
    applications_by_id,
    source_ids_override=nothing,
    distributed_outputs=NoCompiledDistributedOutputs(),
)
    input_sym = plan.input
    selector = plan.selector
    source_var = plan.source_var
    process_filter = plan.process
    application_filter = plan.application
    source_ids = isnothing(source_ids_override) ?
                 _dependency_object_ids(
        model,
        selector,
        plan.matcher,
        consumer_id,
    ) : source_ids_override
    _filter_many_input_sources_by_writer!(
        source_ids,
        selector,
        source_var,
        process_filter,
        application_filter,
        applications_by_id,
        distributed_outputs,
    )
    selector isa Many && sizehint!(source_ids, length(source_ids) + 1)
    source_application_ids = if _selector_from_status(selector)
        Symbol[]
    else
        _matching_input_source_applications(
            applications_by_object,
            source_ids,
            source_var,
            process_filter,
            application_filter,
            distributed_outputs;
            applications_by_id=applications_by_id,
            allow_empty=selector isa OptionalOne ||
                        (selector isa Many && isempty(source_ids)),
        )
    end
    if selector isa Many &&
       isempty(source_ids) &&
       (!isnothing(process_filter) || !isnothing(application_filter))
        source_application_ids = _potential_input_source_applications(
            applications_by_id,
            source_var,
            process_filter,
            application_filter,
        )
        isempty(source_application_ids) && error(
            "Input selector for source variable `$(source_var)` requested",
            isnothing(process_filter) ? "" : " process `$(process_filter)`",
            isnothing(application_filter) ? "" : " application `$(application_filter)`",
            ", but no matching source application was found.",
        )
    end
    if !(selector isa Many) &&
       isnothing(process_filter) &&
       isnothing(application_filter) &&
       length(source_application_ids) > 1
        source_application_ids = _final_canonical_source_application(
            applications_by_object,
            source_ids,
            source_application_ids,
            source_var,
            distributed_outputs,
        )
    end
    if selector isa Many && length(source_application_ids) > 1
        source_application_ids = _final_many_source_applications(
            source_ids,
            source_application_ids,
            source_var,
            applications_by_id,
            distributed_outputs,
        )
    end
    if !(selector isa Many) && length(source_application_ids) > 1
        error(
            "Input `$(input_sym)` on application `$(application.id)` matched several " *
            "source applications `$(source_application_ids)`. Add one of those canonical " *
            "identifiers as `application=...` to the `inputs=...` selector.",
        )
    end
    if selector isa OptionalOne &&
       (!isnothing(process_filter) || !isnothing(application_filter)) &&
       isempty(source_application_ids)
        source_ids = ObjectId[]
    end
    policy = _model_selector_policy(selector, applications_by_id, source_application_ids, source_var)
    if policy isa PreviousTimeStep
        policy.variable == input_sym || error(
            "PreviousTimeStep marker for input `$(input_sym)` on application ",
            "`$(application.id)` names `$(policy.variable)`. Use ",
            "`PreviousTimeStep(:$(input_sym))`."
        )
    else
        _validate_policy_instance(
            _model_object(model, consumer_id).scale,
            application.process,
            input_sym,
            policy,
        )
    end
    stream_only_source = _has_stream_only_input_source(
        source_application_ids,
        source_var,
        applications_by_id,
    )
    carrier = if stream_only_source
        _stream_only_initial_carrier(
            model,
            selector,
            source_ids,
            source_application_ids,
            source_var,
            applications_by_id,
        )
    else
        _input_carrier(model, selector, source_ids, source_var)
    end
    carrier_hint = if isempty(source_ids) && selector isa OptionalOne
        :optional_default
    elseif stream_only_source
        :temporal_stream
    else
        _carrier_hint(selector, policy, plan.window)
    end
    _validate_model_input_source!(
        model,
        application,
        consumer_id,
        input_sym,
        source_var,
        source_ids,
        carrier,
        carrier_hint,
    )
    push!(
        bindings,
        CompiledModelInputBinding(
            plan,
            consumer_id,
            source_ids,
            source_application_ids,
            policy,
            carrier_hint,
            carrier,
        ),
    )
    return bindings
end

_final_many_source_applications(
    source_ids,
    source_application_ids,
    source_var,
    applications_by_id,
    ::NoCompiledDistributedOutputs,
) = source_application_ids

function _final_many_source_applications(
    source_ids,
    source_application_ids,
    source_var::Symbol,
    applications_by_id,
    distributed_outputs::CompiledDistributedOutputs,
)
    matching_ids = Set(source_application_ids)
    canonical_ids = Symbol[]
    for source_id in source_ids
        owners = get(
            distributed_outputs.writer_ownership,
            (source_id, source_var),
            (),
        )
        final_owner = nothing
        for owner in Iterators.reverse(owners)
            if owner.application_id in matching_ids
                final_owner = owner.application_id
                break
            end
        end
        if isnothing(final_owner)
            for application_id in source_application_ids
                application = applications_by_id[application_id]
                source_id in application.target_ids || continue
                source_var in _model_output_names(application) || continue
                application_id in canonical_ids ||
                    push!(canonical_ids, application_id)
            end
        elseif !(final_owner in canonical_ids)
            push!(canonical_ids, final_owner)
        end
    end
    return isempty(canonical_ids) ? source_application_ids : canonical_ids
end

_filter_many_input_sources_by_writer!(
    source_ids,
    selector,
    source_var,
    process_filter,
    application_filter,
    applications_by_id,
    ::NoCompiledDistributedOutputs,
) = source_ids

function _filter_many_input_sources_by_writer!(
    source_ids,
    selector,
    source_var::Symbol,
    process_filter,
    application_filter,
    applications_by_id,
    distributed_outputs::CompiledDistributedOutputs,
)
    selector isa Many || return source_ids
    _selector_from_status(selector) && return source_ids
    isnothing(process_filter) && isnothing(application_filter) &&
        return source_ids
    filter!(source_ids) do source_id
        owners = get(
            distributed_outputs.writer_ownership,
            (source_id, source_var),
            (),
        )
        any(owners) do owner
            source_application = get(
                applications_by_id,
                owner.application_id,
                nothing,
            )
            isnothing(source_application) && return false
            isnothing(process_filter) ||
                source_application.process == process_filter || return false
            isnothing(application_filter) ||
                source_application.id == application_filter || return false
            return true
        end
    end
    return source_ids
end

function _model_input_names(application::CompiledModelApplication)
    return Symbol[Symbol(var) for var in keys(_input_schema(application.spec))]
end

function _validate_model_input_source!(
    model::CompositeModel,
    application::CompiledModelApplication,
    consumer_id::ObjectId,
    input_sym::Symbol,
    source_var::Symbol,
    source_ids::Vector{ObjectId},
    carrier,
    carrier_hint::Symbol,
)
    !isnothing(carrier) && return nothing
    status_source_ids = ObjectId[
        source_id for source_id in source_ids
        if _model_object(model, source_id).status isa Status
    ]
    isempty(status_source_ids) && return nothing
    error(
        "Input binding `$(input_sym)` on application `$(application.id)` for object ",
        "`$(consumer_id.value)` reads `$(source_var)` from objects ",
        "`$([id.value for id in status_source_ids])`, but no source `Status` reference is available."
    )
end

function _validate_declared_model_input_name!(application::CompiledModelApplication, input_sym::Symbol)
    input_names = Set(_model_input_names(application))
    input_sym in input_names && return nothing
    error(
        "Input binding `$(input_sym)` on application `$(application.id)` is not declared by ",
        "`inputs_` for process `$(application.process)`. Declared model inputs are ",
        "`$(sort!(collect(input_names)))`."
    )
end

function _bound_model_inputs(input_bindings)
    bound = Set{Tuple{Symbol,ObjectId,Symbol}}()
    for binding in input_bindings
        binding.policy isa PreviousTimeStep && continue
        binding.carrier_hint == :optional_default &&
            isnothing(binding.carrier) &&
            continue
        push!(bound, (binding.application_id, binding.consumer_id, binding.input))
    end
    return bound
end

function _status_has_variable(model::CompositeModel, object_id::ObjectId, variable::Symbol)
    object = _model_object(model, object_id)
    object.status isa Status || return false
    return variable in propertynames(object.status)
end

function _validate_model_required_inputs!(model::CompositeModel, applications, input_bindings)
    bound = _bound_model_inputs(input_bindings)
    missing = NamedTuple[]
    for application in applications
        schema = _input_schema(application.spec)
        for object_id in application.target_ids
            for (input_, declaration) in pairs(schema)
                declaration isa Required || continue
                input = Symbol(input_)
                (application.id, object_id, input) in bound && continue
                _status_has_variable(model, object_id, input) && continue
                push!(
                    missing,
                    (
                        application_id=application.id,
                        object_id=object_id.value,
                        input=input,
                        process=application.process,
                    ),
                )
            end
        end
    end
    isempty(missing) && return nothing
    details = join(
        [
            "`$(row.application_id)` on object `$(row.object_id)` requires `$(row.input)`"
            for row in missing
        ],
        "; ",
    )
    error(
        "Missing required composite-model/object input(s): ",
        details,
        ". Provide the variable on object `Status`, add a `ModelSpec(...; inputs=...)` binding, ",
        "or add an unambiguous same-object producer."
    )
end

function _applications_by_object(applications)
    by_object = Dict{ObjectId,Vector{Any}}()
    for application in applications
        for object_id in application.target_ids
            push!(get!(by_object, object_id, Any[]), application)
        end
    end
    return by_object
end

function _matching_callee_applications(applications, object_id::ObjectId, proc, application_name_filter)
    matches = Symbol[]
    for application in get(applications, object_id, Any[])
        isnothing(proc) || application.process == proc || continue
        isnothing(application_name_filter) || application.id == application_name_filter || continue
        push!(matches, application.id)
    end
    return matches
end

function _compile_model_call_bindings(
    model::CompositeModel,
    applications,
    lookup_applications=applications,
    ;
    by_object=nothing,
    plans_by_application=nothing,
)
    if isnothing(plans_by_application)
        plans_by_application = _plans_by_application(
            applications,
            _compile_model_call_plans(model, applications),
        )
    end
    bindings = CompiledModelCallBinding[]
    for application in applications
        for consumer_id in application.target_ids
            for plan in _application_plans(
                plans_by_application,
                application.slot,
            )
                call_sym = plan.call
                selector = plan.selector
                proc = plan.process
                app_name = plan.application
                mode = _compiled_call_mode(plan)
                callee_object_ids, callee_application_ids = if mode === :initializer
                    # Initializers never cache or track pre-existing target objects.
                    # Their one scheduled application is statically validated, and
                    # run_initializer! resolves only its explicit newborn identity.
                    (
                        ObjectId[],
                        Symbol[plan.potential_callee_application_ids...],
                    )
                else
                    isnothing(by_object) &&
                        (by_object = _applications_by_object(lookup_applications))
                    object_ids = _dependency_object_ids(
                        model,
                        selector,
                        plan.matcher,
                        consumer_id,
                    )
                    application_ids = Symbol[]
                    for object_id in object_ids
                        append!(
                            application_ids,
                            _matching_callee_applications(
                                by_object,
                                object_id,
                                proc,
                                app_name,
                            ),
                        )
                    end
                    unique!(application_ids)
                    (object_ids, application_ids)
                end
                if mode === :manual &&
                   isempty(callee_application_ids) && selector isa One
                    error(
                        "Call `$(call_sym)` on application `$(application.id)` matched objects ",
                        "$([id.value for id in callee_object_ids]) but no model application",
                        isnothing(proc) ? "." : " with process `$(proc)`.",
                    )
                end
                if mode === :manual && selector isa One &&
                   length(callee_application_ids) != 1
                    error(
                        "Call `$(call_sym)` on application `$(application.id)` expected one callee application, ",
                        "got `$(callee_application_ids)`. Add `application=:name` to disambiguate."
                    )
                elseif selector isa OptionalOne && length(callee_application_ids) > 1
                    error(
                        "Call `$(call_sym)` on application `$(application.id)` expected zero or one callee application, ",
                        "got `$(callee_application_ids)`. Add `application=:name` to disambiguate."
                    )
                end
                push!(
                    bindings,
                    CompiledModelCallBinding(
                        plan,
                        consumer_id,
                        callee_object_ids,
                        callee_application_ids,
                    ),
                )
            end
        end
    end
    return bindings
end

function _model_call_owners(call_bindings)
    owners = Dict{Symbol,Set{Symbol}}()
    for binding in call_bindings
        _compiled_call_mode(binding) === :manual || continue
        for callee_id in binding.callee_application_ids
            push!(get!(owners, callee_id, Set{Symbol}()), binding.application_id)
        end
    end
    return owners
end

function _add_model_application_edge!(children, parent::Symbol, child::Symbol)
    parent == child && return nothing
    push!(get!(children, parent, Set{Symbol}()), child)
    return nothing
end

function _model_input_order_edges!(children, input_bindings, call_owners)
    for binding in input_bindings
        binding.policy isa PreviousTimeStep && continue
        ordering_sources = (
            binding.source_application_ids...,
            binding.order_after_application_ids...,
        )
        for source_id in ordering_sources
            owners = get(call_owners, source_id, nothing)
            if isnothing(owners)
                _add_model_application_edge!(children, source_id, binding.application_id)
            else
                for owner_id in owners
                    _add_model_application_edge!(children, owner_id, binding.application_id)
                end
            end
        end
    end
    return children
end

function _model_update_order_edges!(children, applications)
    any(application -> !isempty(updates(application.spec)), applications) ||
        return children
    for indexed_writers in values(_model_writer_groups(applications))
        length(indexed_writers) > 1 || continue
        sort!(indexed_writers; by=first)
        for index in 2:length(indexed_writers)
            previous_application = indexed_writers[index - 1][2]
            application = indexed_writers[index][2]
            _add_model_application_edge!(children, previous_application.id, application.id)
        end
    end
    return children
end

function _stable_topological_application_order(applications, children)
    application_ids = Symbol[application.id for application in applications]
    positions = Dict(application_id => index for (index, application_id) in pairs(application_ids))
    indegree = Dict(application_id => 0 for application_id in application_ids)
    for child_ids in values(children)
        for child_id in child_ids
            indegree[child_id] = get(indegree, child_id, 0) + 1
        end
    end
    ready = Symbol[application_id for application_id in application_ids if indegree[application_id] == 0]
    order = Symbol[]
    while !isempty(ready)
        sort!(ready; by=application_id -> positions[application_id])
        application_id = popfirst!(ready)
        push!(order, application_id)
        child_ids = sort!(collect(get(children, application_id, Set{Symbol}())); by=child_id -> positions[child_id])
        for child_id in child_ids
            indegree[child_id] -= 1
            indegree[child_id] == 0 && push!(ready, child_id)
        end
    end
    if length(order) != length(application_ids)
        remaining = Symbol[application_id for application_id in application_ids if indegree[application_id] > 0]
        error(
            "Composite model application dependency cycle detected among applications `$(remaining)`. ",
            "Break the same-timestep cycle with a temporal policy or revise `inputs=...`/`updates=...`."
        )
    end
    return order
end

function _compile_model_application_children(
    applications,
    input_bindings,
    call_bindings,
    call_owners,
)
    children = Dict{Symbol,Set{Symbol}}()
    _model_input_order_edges!(children, input_bindings, call_owners)
    _scenario_initializer_order_edges!(
        children,
        input_bindings,
        call_bindings,
        call_owners,
    )
    _model_update_order_edges!(children, applications)
    return children
end

function _compile_model_application_order(applications, input_bindings, call_bindings)
    children = _compile_model_application_children(
        applications,
        input_bindings,
        call_bindings,
        _model_call_owners(call_bindings),
    )
    return _stable_topological_application_order(applications, children)
end

function _ordered_model_applications(compiled::CompiledCompositeModel)
    return compiled.ordered_applications
end

function explain_applications(compiled::CompiledCompositeModel)
    return [
        (
            application_slot=application.plan.slot,
            application_id=application.id,
            process=application.process,
            name=application.name,
            input_plan_count=length(
                _application_plans(
                    compiled.scenario_plan.input_plans_by_application,
                    application.slot,
                ),
            ),
            call_plan_count=length(
                _application_plans(
                    compiled.scenario_plan.call_plans_by_application,
                    application.slot,
                ),
            ),
            output_destination_plan_count=
                compiled.scenario_plan.distributed_output_plans isa
                NoCompiledDistributedOutputPlans ?
                0 :
                length(
                    _application_plans(
                        compiled.scenario_plan.distributed_output_plans.by_application,
                        application.slot,
                    ),
                ),
            current_target_count=length(application.target_ids),
            target_ids=[id.value for id in application.target_ids],
            target_scales=sort!(unique!(Symbol[
                _model_object(compiled.model, id).scale
                for id in application.target_ids
                if !isnothing(_model_object(compiled.model, id).scale)
            ]); by=string),
            applies_to=application.applies_to,
            inputs=Tuple(Symbol.(keys(_input_schema(application.spec)))),
            outputs=Tuple(Symbol.(keys(outputs_(application.spec)))),
            environment_inputs=Tuple(Symbol.(keys(environment_inputs_(application.spec)))),
            environment_outputs=Tuple(Symbol.(keys(environment_outputs_(application.spec)))),
            timestep=application.timestep,
            clock=application.clock,
            model_type=typeof(_application_default_model(application)),
            model_storage=isnothing(application.model_overrides) ? :shared_application : :per_object_override,
            model_dispatch=_application_model_dispatch(application),
            object_overrides=isnothing(application.model_overrides) ?
                             NamedTuple[] :
                             [
                                 (
                                     object_id=object_id.value,
                                     model_type=typeof(model),
                                 )
                                 for (object_id, model) in sort!(
                                     collect(application.model_overrides);
                                     by=pair -> string(first(pair).value),
                                 )
                             ],
        )
        for application in compiled.applications
    ]
end

explain_applications(model::CompositeModel) =
    explain_applications(refresh_bindings!(model))

function _application_model_dispatch(application::CompiledModelApplication)
    isnothing(application.model_overrides) && return :concrete_shared
    override_type = valtype(typeof(application.model_overrides))
    default_type = typeof(_application_default_model(application))
    return isconcretetype(override_type) && default_type == override_type ?
           :concrete_per_object :
           :heterogeneous_per_object
end

function explain_schedule(compiled::CompiledCompositeModel)
    timeline = compiled.scenario_plan.timeline
    manual_application_ids = _manual_call_application_ids(compiled)
    initializer_application_ids = _initializer_call_application_ids(
        compiled.scenario_plan.call_plans,
    )
    execution_positions = Dict(application_id => index for (index, application_id) in pairs(compiled.application_order))
    schedule_entries = Dict(
        entry.application_id => entry
        for entry in compiled.scenario_plan.application_schedule.entries
    )
    return [
        let entry = get(schedule_entries, application.id, nothing)
        (
            application_id=application.id,
            process=application.process,
            execution_index=execution_positions[application.id],
            timestep=application.timestep,
            clock=application.clock,
            dt_steps=application.clock.dt,
            phase=application.clock.phase,
            dt_seconds=float(application.clock.dt) * timeline.base_step_seconds,
            target_ids=[id.value for id in application.target_ids],
            root_scheduled=!(application.id in manual_application_ids),
            manual_call_only=application.id in manual_application_ids,
            initializer_target=application.id in initializer_application_ids,
            schedule_entry_index=isnothing(entry) ? nothing : entry.slot,
            schedule_kind=isnothing(entry) ? :manual_call_only : entry.kind,
            period_steps=isnothing(entry) ? nothing : entry.period_steps,
            phase_step=isnothing(entry) ? nothing : entry.phase_step,
            event_driven=!isnothing(entry) && entry.kind !== :generic,
        )
        end
        for application in _ordered_model_applications(compiled)
    ]
end

explain_schedule(model::CompositeModel) = explain_schedule(refresh_bindings!(model))

function _model_binding_carrier_kind(binding::CompiledModelInputBinding)
    binding.carrier_hint == :temporal_stream && return :temporal_stream
    binding.carrier_hint == :optional_default && return :optional_default
    carrier = binding.carrier
    isnothing(carrier) && return :unresolved
    carrier isa Base.RefValue && return :ref
    carrier isa RefVector && return :ref_vector
    carrier isa ObjectRefVector && return :object_ref_vector
    return :custom
end

function _model_binding_copy_semantics(binding::CompiledModelInputBinding)
    kind = _model_binding_carrier_kind(binding)
    kind in (:ref, :ref_vector, :object_ref_vector) && return :live_references
    kind == :temporal_stream && return :materialized_temporal_value
    kind == :optional_default && return :consumer_default
    kind == :unresolved && return :not_materialized
    return :backend_defined
end

    function explain_bindings(compiled::CompiledCompositeModel)
    return [
        (
            input_plan_slot=binding.plan.slot,
            application_slot=binding.plan.application_slot,
            application_id=binding.application_id,
            consumer_id=binding.consumer_id.value,
            input=binding.input,
            origin=binding.origin,
            source_ids=[id.value for id in binding.source_ids],
        source_application_ids=binding.source_application_ids,
        potential_source_application_ids=
            binding.plan.potential_source_application_ids,
        breaks_same_step_cycle=binding.plan.breaks_same_step_cycle,
            order_after_application_ids=binding.order_after_application_ids,
            source_var=binding.source_var,
            process=binding.process,
            application=binding.application,
            multiplicity=binding.multiplicity,
            policy=binding.policy,
            window=binding.window,
            carrier_hint=binding.carrier_hint,
            carrier_kind=_model_binding_carrier_kind(binding),
            copy_semantics=_model_binding_copy_semantics(binding),
            has_reference_carrier=has_reference_carrier(binding),
            carrier_type=isnothing(binding.carrier) ? nothing : typeof(binding.carrier),
            selector=binding.selector,
        )
        for binding in compiled.input_bindings
    ]
end

explain_bindings(model::CompositeModel) = explain_bindings(refresh_bindings!(model))

function explain_calls(compiled::CompiledCompositeModel)
    return [
        (
            call_plan_slot=binding.plan.slot,
            application_slot=binding.plan.application_slot,
            application_id=binding.application_id,
            consumer_id=binding.consumer_id.value,
            call=binding.call,
            mode=_compiled_call_mode(binding),
            origin=binding.origin,
            callee_object_ids=[id.value for id in binding.callee_object_ids],
        callee_application_ids=binding.callee_application_ids,
        potential_callee_application_ids=
            binding.plan.potential_callee_application_ids,
            process=binding.process,
            application=binding.application,
            multiplicity=binding.multiplicity,
            publication_policy=_compiled_call_mode(binding) === :initializer ?
                               :canonical_status_only : :explicit_accept,
            default_publish=false,
            accepted_publish=_compiled_call_mode(binding) === :manual,
            resolved=!isempty(binding.callee_application_ids),
            selector=binding.selector,
        )
        for binding in compiled.call_bindings
    ]
end

explain_calls(model::CompositeModel) = explain_calls(refresh_bindings!(model))

"""
    Diagnostics.explain_output_bindings(model_or_compiled)

Return one structured row per compiled cross-object output destination. Rows
separate the application execution object from current destination object IDs
and report declared variables, carrier types, coverage, and lifecycle
generation.
"""
function explain_output_bindings(compiled::CompiledCompositeModel)
    return _explain_output_bindings(compiled.distributed_outputs)
end

_explain_output_bindings(::NoCompiledDistributedOutputs) = NamedTuple[]

function _explain_output_bindings(outputs::CompiledDistributedOutputs)
    rows = NamedTuple[]
    for binding in outputs.bindings
        push!(
            rows,
            (
                output_plan_slot=binding.plan.slot,
                application_slot=binding.plan.application_slot,
                application_id=binding.application_id,
                execution_object_id=binding.execution_object_id.value,
                group=binding.group,
                destination_ids=[id.value for id in binding.destination_ids],
                destination_count=length(binding.destination_ids),
                variables=Tuple(Symbol.(keys(binding.declarations))),
                column_types=NamedTuple{Tuple(keys(binding.columns))}(
                    Tuple(typeof(column) for column in values(binding.columns)),
                ),
                multiplicity=binding.multiplicity,
                coverage=binding.coverage,
                membership_generation=binding.membership_generation,
                selector=binding.selector,
            ),
        )
    end
    sort!(rows; by=row -> (
        string(row.application_id),
        string(row.execution_object_id),
        string(row.group),
    ))
    return rows
end

explain_output_bindings(model::CompositeModel) =
    explain_output_bindings(refresh_bindings!(model))

function explain_writers(compiled::CompiledCompositeModel)
    return _explain_writers(compiled, compiled.distributed_outputs)
end

function _explain_writers(
    compiled::CompiledCompositeModel,
    ::NoCompiledDistributedOutputs,
)
    groups = _model_writer_groups(compiled.applications, _manual_call_application_ids(compiled))
    rows = NamedTuple[]
    for ((object_id, variable), indexed_writers) in groups
        sort!(indexed_writers; by=first)
        applications = [application for (_, application) in indexed_writers]
        push!(
            rows,
            (
                object_id=object_id.value,
                variable=variable,
                application_ids=[application.id for application in applications],
                processes=[application.process for application in applications],
                update_application_ids=[
                    application.id for application in applications
                    if !isempty(_matching_updates(application.spec, variable))
                ],
                update_after=[
                    application.id => _update_after_labels(application.spec, variable)
                    for application in applications
                    if !isempty(_matching_updates(application.spec, variable))
                ],
                duplicate=length(applications) > 1,
            ),
        )
    end
    sort!(rows; by=row -> (string(row.object_id), string(row.variable)))
    return rows
end

function _explain_writers(
    compiled::CompiledCompositeModel,
    distributed_outputs::CompiledDistributedOutputs,
)
    rows = NamedTuple[]
    for ((object_id, variable), owners) in distributed_outputs.writer_ownership
        sorted_owners = sort!(copy(owners); by=owner -> owner.application_slot)
        applications = [
            compiled.applications[owner.application_slot]
            for owner in sorted_owners
        ]
        push!(
            rows,
            (
                object_id=object_id.value,
                variable=variable,
                application_ids=[owner.application_id for owner in sorted_owners],
                processes=[application.process for application in applications],
                owner_kinds=[owner.kind for owner in sorted_owners],
                execution_object_ids=[
                    owner.execution_object_id.value for owner in sorted_owners
                ],
                output_groups=[owner.group for owner in sorted_owners],
                update_application_ids=[
                    application.id for application in applications
                    if !isempty(_matching_updates(application.spec, variable))
                ],
                update_after=[
                    application.id => _update_after_labels(application.spec, variable)
                    for application in applications
                    if !isempty(_matching_updates(application.spec, variable))
                ],
                duplicate=length(applications) > 1,
            ),
        )
    end
    sort!(rows; by=row -> (string(row.object_id), string(row.variable)))
    return rows
end

explain_writers(model::CompositeModel) = explain_writers(refresh_bindings!(model))

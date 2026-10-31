# Resolved-call capability experiment. Included inside CompiledRegionsExperiment.
# It adds dispatch only for a new RunContext.calls type; ordinary PSE contexts
# and methods keep their existing execution paths.

"""
    resolved_call_effects(::Type) = :ordered

`:stable_calls` is an audited promise that a model and its indirect callbacks
do not change topology, model applications, bindings, or call membership while
it executes. It excludes nested advancement of this Simulation and mutation of
RunContext internals during an invocation. It may use
public RunContext operations, mutate scientific state, publish accepted state,
and throw. It must not inspect or dispatch on RunContext's internal type
parameters. Unknown models retain ordinary calls. This promise is deliberately
different from the region compiler's stronger row-local/nonthrowing contract.
"""
resolved_call_effects(::Type) = :ordered

mutable struct ResolvedCallCounters
    root_invocations::Int
    fast_calls::Int
    fast_targets::Int
    model_lookups::Int
    fallback_calls::Int
    evaluation_fallbacks::Int
    environment_fallbacks::Int
    stale_fallbacks::Int
    reentrant_fallbacks::Int
    selected_roots::Int
    selected_edges::Int
    fallback_edges::Int
    prepared_contexts::Int
    reasons::Dict{Symbol,Int}
end
ResolvedCallCounters() = ResolvedCallCounters(0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, Dict{Symbol,Int}())

struct ResolvedTargetPlan{T,A,C}
    owner::T
    application::A
    context::C
end

struct ResolvedCallBatchPlan{P}
    # Membership length is data. Do not turn millions of resolved objects into
    # a tuple type or unrolled generated source.
    targets::P
end

struct ResolvedCallEntry{Fast,T,P}
    targets::T
    plans::P
    membership_generation::UInt64
    reason::Symbol
end

struct ResolvedCallTable{Names,E,O,F,C}
    entries::NamedTuple{Names,E}
    original_calls::O
    fallback_context::F
    counters::C
    compiled::Any
    environment_bindings::Any
    model_revision::Int
    runtime_revision::Int
    environment_revision::Int
end

# Existing diagnostics and error paths iterate context.calls to show the public
# CallTargets objects. Keeping that shape also preserves evaluate_call!, whose
# original implementation uses the original caches and publication journals.
Base.length(table::ResolvedCallTable) = length(table.original_calls)
Base.isempty(table::ResolvedCallTable) = isempty(table.original_calls)
Base.iterate(table::ResolvedCallTable, state...) = iterate(table.original_calls, state...)

@inline @generated function _resolved_entry(table::ResolvedCallTable{Names},
    ::Val{Name}) where {Names,Name}
    index = findfirst(==(Name), Names)
    return isnothing(index) ? :(nothing) : :(getfield(table.entries, $index))
end

@inline function PSE._find_call_targets(table::ResolvedCallTable, name::Val,
    context::PSE.RunContext)
    return PSE._find_call_targets(table.original_calls, name, context)
end
@inline function PSE._find_manual_call_targets(table::ResolvedCallTable, name::Val,
    context::PSE.RunContext)
    return PSE._find_manual_call_targets(table.original_calls, name, context)
end

function PSE._prepare_runtime_call_targets!(table::ResolvedCallTable, args...)
    return PSE._prepare_runtime_call_targets!(table.original_calls, args...)
end

@inline function _resolved_synchronize_view!(targets, context)
    targets.time = context.time
    targets.publication_allowed = context.publication_allowed
    targets.environment = context.environment
    return targets
end

@inline function _resolved_fallback_context!(context)
    original = context.calls.fallback_context
    # Same PSE RunContext layout and original call tuple. Backend overrides and
    # evaluated calls are deliberately delegated to this ordinary shell.
    original.compiled = context.compiled
    original.environment_bindings = context.environment_bindings
    original.application = context.application
    original.object_id = context.object_id
    original.bound_inputs = context.bound_inputs
    original.output_targets = context.output_targets
    original.temporal_streams = context.temporal_streams
    original.output_retention = context.output_retention
    original.time = context.time
    original.constants = context.constants
    original.publication_allowed = context.publication_allowed
    original.environment = context.environment
    return original
end

@inline function _resolved_context_current(table, context)
    compiled = context.compiled
    # The supported local-context lowering erases this field's type while
    # retaining the actual compiler object. Other thin capability contexts
    # must take ordinary execution instead of failing on a `.model` access.
    compiled isa PSE.CompiledCompositeModel || return false
    model = compiled.model
    return table.compiled === compiled &&
        table.environment_bindings === context.environment_bindings &&
        model.revision == table.model_revision &&
        model.runtime_revision == table.runtime_revision &&
        model.environment_revision == table.environment_revision &&
        !PSE.bindings_dirty(model) && !PSE.environment_bindings_dirty(model)
end

# Select the same model-facing status as the source executor. The frozen
# original engine predates the experimental narrow interface helper; this
# benchmark-only feature probe keeps comparisons on its actual full Status.
include("call_status_abi.jl")

@inline function _resolved_call_current(entry, context)
    return _resolved_context_current(context.calls, context) &&
        PSE._compiled_call_membership_generation(entry.targets.binding) ==
            entry.membership_generation
end

@inline _resolved_leases_available(::Tuple{}) = true
@inline function _resolved_leases_available(plans::Tuple)
    for target in first(plans).targets
        !target.owner.call_context_cache.in_use || return false
    end
    return _resolved_leases_available(Base.tail(plans))
end

@inline _resolved_target_count(::Tuple{}) = 0
@inline _resolved_target_count(plans::Tuple) =
    length(first(plans).targets) + _resolved_target_count(Base.tail(plans))

@inline function _resolved_prepare_callee!(child, parent, publication_allowed)
    child.time = parent.time
    child.constants = parent.constants
    child.publication_allowed = publication_allowed
    child.environment = parent.environment
    return child
end

@inline function _resolved_run_target!(plan::ResolvedTargetPlan, parent,
    publish, sampled_environment)
    owner = plan.owner
    cache = owner.call_context_cache
    # This is the SAME original cache revision used by CallEvaluation tokens.
    # A later fast run must invalidate a token saved by a previous evaluation.
    PSE._record_call_execution!(cache, nothing)
    environment = sampled_environment isa PSE.UnspecifiedModelEnvironment ?
        PSE._model_environment_for_binding(parent.environment_bindings,
            plan.application, owner.environment_binding, parent.time,
            parent.environment) : sampled_environment
    context = _resolved_prepare_callee!(plan.context, parent,
        publish && parent.publication_allowed)
    cache.in_use = true
    try
        # Original selected Status ABI and original scientific method. No source or
        # equation rewriting, carrier copies, or accepted-kernel replay.
        PSE._run_call_kernel!(owner.model, _resolved_kernel_status(owner), environment, context,
            owner.output_bindings)
    finally
        cache.in_use = false
    end
    return nothing
end

@inline _resolved_run_targets!(::Tuple{}, parent, publish, environment) = nothing
@inline function _resolved_run_targets!(plans::Tuple, parent, publish, environment)
    for target in first(plans).targets
        _resolved_run_target!(target, parent, publish, environment)
    end
    _resolved_run_targets!(Base.tail(plans), parent, publish, environment)
    return nothing
end

@noinline function _resolved_fallback_call!(context, name;
    environment, sampled_environment, publish, objects)
    original = _resolved_fallback_context!(context)
    return PSE.run_call!(original, name; environment, sampled_environment,
        publish, objects)
end

@inline function _resolved_run_entry!(entry::ResolvedCallEntry{false}, context,
    name, environment, sampled_environment, publish, objects)
    context.calls.counters.fallback_calls += 1
    return _resolved_fallback_call!(context, name;
        environment, sampled_environment, publish, objects)
end

@inline function _resolved_run_entry!(entry::ResolvedCallEntry{true}, context,
    name, environment, sampled_environment, publish, objects)
    counters = context.calls.counters
    frame = PSE._active_call_evaluation()
    if frame !== nothing
        counters.fallback_calls += 1
        counters.evaluation_fallbacks += 1
    elseif !(environment isa PSE.NoEnvironmentOverride) ||
           !(context.environment isa PSE.NoEnvironmentOverride) || objects !== nothing
        counters.fallback_calls += 1
        counters.environment_fallbacks += 1
    elseif !_resolved_call_current(entry, context)
        counters.fallback_calls += 1
        counters.stale_fallbacks += 1
    elseif !_resolved_leases_available(entry.plans)
        counters.fallback_calls += 1
        counters.reentrant_fallbacks += 1
    else
        targets = _resolved_synchronize_view!(entry.targets, context)
        counters.fast_calls += 1
        counters.fast_targets += _resolved_target_count(entry.plans)
        _resolved_run_targets!(entry.plans, context, publish, sampled_environment)
        if publish && context.publication_allowed
            # Preserve completion clocks for empty OptionalOne/Many selections.
            for application_id in targets.binding.potential_callee_application_ids
                PSE._record_evaluated_call_clock!(nothing,
                    context.output_retention, application_id, context.time)
            end
        end
        return targets
    end
    return _resolved_fallback_call!(context, name;
        environment, sampled_environment, publish, objects)
end

@inline Base.@constprop :aggressive function PSE.run_call!(
    context::PSE.RunContext{CS,A,CT}, name::Symbol;
    environment=PSE._NO_ENVIRONMENT_OVERRIDE,
    sampled_environment=PSE._UNSPECIFIED_SCENE_ENVIRONMENT,
    publish::Bool=false, objects=nothing,
) where {CS,A,CT<:ResolvedCallTable}
    if !(environment isa PSE.NoEnvironmentOverride) &&
       !(sampled_environment isa PSE.UnspecifiedModelEnvironment)
        throw(ArgumentError(
            "`environment` and `sampled_environment` are mutually exclusive hard-call overrides.",
        ))
    end
    entry = _resolved_entry(context.calls, Val(name))
    if entry === nothing
        context.calls.counters.fallback_calls += 1
        return _resolved_fallback_call!(context, name;
            environment, sampled_environment, publish, objects)
    end
    return _resolved_run_entry!(entry, context, name, environment,
        sampled_environment, publish, objects)
end

@inline function _resolved_call_model(entry::ResolvedCallEntry{true}, context,
    name::Val{Name}) where {Name}
    if _resolved_call_current(entry, context) && _resolved_target_count(entry.plans) == 1
        context.calls.counters.model_lookups += 1
        return _resolved_single_model(entry.plans)
    end
    return PSE._call_model(_resolved_fallback_context!(context), name)
end

@inline _resolved_single_model(plans::Tuple{B}) where {B} =
    first(first(plans).targets).owner.model
function _resolved_single_model(plans::Tuple)
    for batch in plans
        isempty(batch.targets) || return first(batch.targets).owner.model
    end
    error("Resolved singular model lookup has no target.")
end
@inline _resolved_call_model(entry, context, name) =
    PSE._call_model(_resolved_fallback_context!(context), name)

@inline function PSE._call_model(context::PSE.RunContext{CS,A,CT},
    name::Val) where {CS,A,CT<:ResolvedCallTable}
    return _resolved_call_model(_resolved_entry(context.calls, name), context, name)
end

function _resolved_original_context(simulation, application, owner)
    context = owner.context
    if context isa PSE.RunContext
        # Manual owners can survive an incremental compiler refresh while
        # their context is refreshed lazily by ordinary execution. Prove all
        # assignments before touching this typed shell, then prepare it once
        # at our cold boundary. Incompatible schemas need a fresh shell.
        fields = (
            compiled=simulation.compiled,
            environment_bindings=simulation.environment_bindings,
            application=application,
            object_id=owner.object_id,
            bound_inputs=owner.bound_inputs,
            output_targets=owner.output_targets,
            temporal_streams=simulation.temporal_streams,
            output_retention=simulation.output_retention,
            constants=simulation.constants,
            environment=PSE._NO_ENVIRONMENT_OVERRIDE,
        )
        compatible = all(pairs(fields)) do field
            last(field) isa fieldtype(typeof(context), first(field))
        end
        if compatible
            for (name, value) in pairs(fields)
                setfield!(context, name, value)
            end
            context.time = float(simulation.current_step)
            context.publication_allowed = true
            PSE._prepare_runtime_call_targets!(context.calls,
                simulation.compiled, simulation.environment_bindings,
                simulation.temporal_streams, simulation.output_retention,
                float(simulation.current_step), simulation.constants, true,
                PSE._NO_ENVIRONMENT_OVERRIDE)
            return context
        end
    end
    return PSE._prepare_model_execution_context!(nothing, simulation.compiled,
        simulation.environment_bindings, application, owner.object_id,
        owner.bound_inputs, owner.output_targets, simulation.temporal_streams,
        simulation.output_retention, simulation.current_step,
        simulation.constants)
end

include("call_context_abi.jl")

function _resolved_fallback_entry(targets, reason, counters)
    counters.fallback_edges += 1
    counters.reasons[reason] = get(counters.reasons, reason, 0) + 1
    return ResolvedCallEntry{false,typeof(targets),Tuple{}}(targets, (),
        PSE._compiled_call_membership_generation(targets.binding), reason)
end

function _prepare_resolved_context(simulation, application, owner, counters,
    contexts, ancestors)
    haskey(contexts, owner) && return contexts[owner]
    original = _resolved_original_context(simulation, application, owner)
    isempty(original.calls) && return original
    key = (application.id, owner.object_id)
    key in ancestors && return original
    push!(ancestors, key)
    entries = Any[]
    names = Symbol[]
    try
        for targets in original.calls
            push!(names, PSE._compiled_call_name(targets.binding))
            if PSE._compiled_call_mode(targets.binding) !== :manual
                push!(entries, _resolved_fallback_entry(targets,
                    :initializer, counters))
                continue
            end
            batches = PSE._materialize_call_execution_batches!(targets)
            reason = :eligible
            for batch in batches, child in batch.targets
                if resolved_call_effects(typeof(child.model)) !== :stable_calls
                    reason = :unknown_callee_effects
                    break
                elseif !isempty(child.input_bindings)
                    reason = :temporal_materialization
                    break
                elseif (batch.application.id, child.object_id) in ancestors
                    reason = :recursive_call_graph
                    break
                end
            end
            if reason !== :eligible
                push!(entries, _resolved_fallback_entry(targets, reason, counters))
                continue
            end
            plans = Any[]
            for batch in batches
                rows = Any[]
                for child in batch.targets
                    child_context = _prepare_resolved_context(simulation,
                        batch.application, child, counters, contexts, ancestors)
                    push!(rows, ResolvedTargetPlan(child, batch.application, child_context))
                end
                isempty(rows) && continue
                Row = typeof(first(rows))
                if !all(row -> typeof(row) === Row, rows)
                    reason = :heterogeneous_context_shape
                    break
                end
                typed_rows = Vector{Row}(undef, length(rows))
                copyto!(typed_rows, rows)
                push!(plans, ResolvedCallBatchPlan(typed_rows))
            end
            if reason !== :eligible
                push!(entries, _resolved_fallback_entry(targets, reason, counters))
                continue
            end
            tuple = Tuple(plans)
            entry = ResolvedCallEntry{true,typeof(targets),typeof(tuple)}(
                targets, tuple,
                PSE._compiled_call_membership_generation(targets.binding), :eligible)
            counters.selected_edges += 1
            push!(entries, entry)
        end
    finally
        delete!(ancestors, key)
    end
    named = NamedTuple{Tuple(names)}(Tuple(entries))
    model = simulation.model
    table = ResolvedCallTable(named, original.calls, original, counters,
        simulation.compiled, simulation.environment_bindings, model.revision,
        model.runtime_revision, model.environment_revision)
    context = _resolved_context_with_calls(original, table)
    contexts[owner] = context
    counters.prepared_contexts += 1
    return context
end

struct ResolvedRootRow{O,C}
    owner::O
    context::C
end

struct ResolvedRootBatch{B,R,C}
    batch::B
    rows::R
    counters::C
    compiled::Any
    environment_bindings::Any
end

_resolved_has_fast_entries(context) = context isa PSE.RunContext &&
    context.calls isa ResolvedCallTable &&
    any(entry -> entry isa ResolvedCallEntry{true}, values(context.calls.entries))

function _resolved_live_selection!(seen, reasons, context)
    if !(context isa PSE.RunContext && context.calls isa ResolvedCallTable) ||
       haskey(seen, context)
        return (0, 0)
    end
    seen[context] = nothing
    selected = fallback = 0
    for entry in values(context.calls.entries)
        if entry isa ResolvedCallEntry{true}
            selected += 1
            for batch in entry.plans, target in batch.targets
                child_selected, child_fallback =
                    _resolved_live_selection!(seen, reasons, target.context)
                selected += child_selected
                fallback += child_fallback
            end
        else
            fallback += 1
            reasons[entry.reason] = get(reasons, entry.reason, 0) + 1
        end
    end
    return selected, fallback
end

"""Prepare concrete call capabilities for audited root controllers, or return nothing."""
function prepare_resolved_root(simulation, batch)
    isempty(batch.targets) && return nothing
    all(target -> resolved_call_effects(typeof(target.model)) === :stable_calls &&
        !isempty(target.call_bindings), batch.targets) || return nothing
    isnothing(simulation.performance) || return nothing
    PSE._synchronize_model_execution_batch_contexts!(batch, simulation.compiled,
        simulation.environment_bindings, simulation.temporal_streams,
        simulation.output_retention, float(simulation.current_step), simulation.constants)
    counters = ResolvedCallCounters()
    contexts = IdDict{Any,Any}()
    ancestors = Set{Tuple{Symbol,PSE.ObjectId}}()
    rows = Any[]
    for target in batch.targets
        context = _prepare_resolved_context(simulation, batch.application,
            target, counters, contexts, ancestors)
        push!(rows, ResolvedRootRow(target, context))
    end
    any(row -> _resolved_has_fast_entries(row.context), rows) || return nothing
    counters.selected_roots = length(rows)
    first_row = first(rows)
    all(row -> typeof(row) === typeof(first_row), rows) || return nothing
    typed_rows = Vector{typeof(first_row)}(undef, length(rows))
    copyto!(typed_rows, rows)
    seen = IdDict{Any,Nothing}()
    reasons = Dict{Symbol,Int}()
    counters.selected_edges = counters.fallback_edges = 0
    for row in typed_rows
        selected, fallback = _resolved_live_selection!(seen, reasons, row.context)
        counters.selected_edges += selected
        counters.fallback_edges += fallback
    end
    counters.reasons = reasons
    return ResolvedRootBatch(batch, typed_rows, counters,
        simulation.compiled, simulation.environment_bindings)
end

function execute_resolved_root!(payload::ResolvedRootBatch, simulation, step)
    batch = payload.batch
    if payload.compiled !== simulation.compiled ||
       payload.environment_bindings !== simulation.environment_bindings
        payload.counters.stale_fallbacks += 1
        return GP._program_run_original_batch!(batch, simulation, step)
    end
    shared = PSE._model_execution_batch_environment(batch.environment_provider,
        simulation.environment_bindings, batch.application, step)
    for row in payload.rows
        owner = row.owner
        isempty(owner.input_bindings) ||
            PSE._materialize_model_inputs!(owner.status, owner.input_bindings,
                simulation.compiled, batch.application,
                simulation.temporal_streams, step)
        status = _resolved_kernel_status(owner)
        environment = shared isa PSE.UnspecifiedModelEnvironment ?
            PSE._model_environment_for_binding(simulation.environment_bindings,
                batch.application, owner.environment_binding, step) : shared
        context = row.context
        context.time = float(step)
        context.constants = simulation.constants
        context.publication_allowed = true
        context.environment = PSE._NO_ENVIRONMENT_OVERRIDE
        payload.counters.root_invocations += 1
        PSE.run!(owner.model, status, environment, simulation.constants, context)
        if batch.output_publication.enabled
            PSE._model_publish_runtime_outputs!(owner.output_bindings, step)
        end
    end
    return nothing
end

function resolved_root_report(payload::ResolvedRootBatch)
    counters = payload.counters
    return (
        selected_roots=counters.selected_roots,
        selected_edges=counters.selected_edges,
        fallback_edges=counters.fallback_edges,
        prepared_contexts=counters.prepared_contexts,
        root_invocations=counters.root_invocations,
        fast_calls=counters.fast_calls,
        fast_targets=counters.fast_targets,
        model_lookups=counters.model_lookups,
        fallback_calls=counters.fallback_calls,
        evaluation_fallbacks=counters.evaluation_fallbacks,
        environment_fallbacks=counters.environment_fallbacks,
        stale_fallbacks=counters.stale_fallbacks,
        reentrant_fallbacks=counters.reentrant_fallbacks,
        fallback_edge_reasons=copy(counters.reasons),
        original_callee_caches_shared=true,
        original_contexts_retained=true,
        controller_context_type=string(nameof(typeof(first(payload.rows).context))),
        controller_calls_type=string(nameof(typeof(first(payload.rows).context.calls))),
        typed_call_capabilities=fieldtype(typeof(first(payload.rows).context), :calls) <: ResolvedCallTable,
    )
end

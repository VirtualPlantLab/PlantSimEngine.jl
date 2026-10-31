# Second call strategy: validate graph invariants at the root invocation
# boundary, not during every nested sampled-environment trial. Included after
# resolved_calls.jl. Original contexts/CallTargets/journals remain fallbacks.

mutable struct ResolvedInvocationEpoch
    running::Bool
    active::Bool
    task_id::UInt
    root_context::Any
    validations::Int
    revalidations::Int
    invalidations::Int
    validation_failures::Int
    trusted_calls::Int
    task_fallbacks::Int
end
ResolvedInvocationEpoch() = ResolvedInvocationEpoch(false, false, UInt(0),
    nothing, 0, 0, 0, 0, 0, 0)

struct EpochCallTable{Names,E,B,S}
    entries::NamedTuple{Names,E}
    metadata::B
    epoch::S
end

@inline Base.@constprop :aggressive function Base.getproperty(table::EpochCallTable,
    name::Symbol)
    name === :entries && return getfield(table, :entries)
    name === :metadata && return getfield(table, :metadata)
    name === :epoch && return getfield(table, :epoch)
    return getproperty(getfield(table, :metadata), name)
end
Base.length(table::EpochCallTable) = length(table.original_calls)
Base.isempty(table::EpochCallTable) = isempty(table.original_calls)
Base.iterate(table::EpochCallTable, state...) = iterate(table.original_calls, state...)

@inline @generated function _epoch_entry(table::EpochCallTable{Names},
    ::Val{Name}) where {Names,Name}
    index = findfirst(==(Name), Names)
    return isnothing(index) ? :(nothing) : :(getfield(table.entries, $index))
end

@inline function _invalidate_call_epoch!(epoch::ResolvedInvocationEpoch)
    if epoch.active
        epoch.active = false
        epoch.invalidations += 1
    end
    return nothing
end

# Public target access may lead to arbitrary selected-target execution, an
# evaluation, or a callback. Leave that work on ordinary PSE views and revoke
# the optimized invocation until a later structural revalidation succeeds.
@inline function PSE._find_call_targets(table::EpochCallTable, name::Val,
    context::PSE.RunContext)
    _invalidate_call_epoch!(table.epoch)
    return PSE._find_call_targets(table.original_calls, name, context)
end
@inline function PSE._find_manual_call_targets(table::EpochCallTable, name::Val,
    context::PSE.RunContext)
    _invalidate_call_epoch!(table.epoch)
    return PSE._find_manual_call_targets(table.original_calls, name, context)
end
function PSE._prepare_runtime_call_targets!(table::EpochCallTable, args...)
    _invalidate_call_epoch!(table.epoch)
    return PSE._prepare_runtime_call_targets!(table.original_calls, args...)
end

_epoch_graph_current(context) = true
function _epoch_graph_current(context::PSE.RunContext{CS,A,CT}) where {CS,A,CT<:EpochCallTable}
    table = context.calls
    table.compiled === context.compiled &&
        table.environment_bindings === context.environment_bindings || return false
    for entry in values(table.entries)
        entry isa ResolvedCallEntry{true} || continue
        PSE._compiled_call_membership_generation(entry.targets.binding) ==
            entry.membership_generation || return false
        for batch in entry.plans, target in batch.targets
            _epoch_graph_current(target.context) || return false
        end
    end
    return true
end

function _validate_call_epoch!(epoch, root_context; revalidation=false)
    epoch.validations += 1
    revalidation && (epoch.revalidations += 1)
    valid = _resolved_context_current(root_context.calls.metadata, root_context) &&
        _epoch_graph_current(root_context)
    epoch.active = valid
    valid || (epoch.validation_failures += 1)
    return valid
end

@inline function _trusted_call_epoch(context)
    epoch = context.calls.epoch
    epoch.running || return false
    if epoch.task_id != objectid(current_task())
        epoch.task_fallbacks += 1
        return false
    end
    epoch.active && return true
    root_context = epoch.root_context
    root_context === nothing && return false
    return _validate_call_epoch!(epoch, root_context; revalidation=true)
end

@noinline function _epoch_fallback_call!(context, name;
    environment, sampled_environment, publish, objects)
    _invalidate_call_epoch!(context.calls.epoch)
    return _resolved_fallback_call!(context, name;
        environment, sampled_environment, publish, objects)
end

@inline function _epoch_run_entry!(entry::ResolvedCallEntry{false}, context,
    name, environment, sampled_environment, publish, objects)
    context.calls.counters.fallback_calls += 1
    return _epoch_fallback_call!(context, name;
        environment, sampled_environment, publish, objects)
end
@inline function _epoch_run_entry!(entry::ResolvedCallEntry{true}, context,
    name, environment, sampled_environment, publish, objects)
    counters = context.calls.counters
    # Evaluation state and per-owner reentrancy leases remain live checks even
    # in a trusted epoch. Their semantics are not structural invariants.
    if PSE._active_call_evaluation() !== nothing
        counters.fallback_calls += 1
        counters.evaluation_fallbacks += 1
    elseif !(environment isa PSE.NoEnvironmentOverride) ||
           !(context.environment isa PSE.NoEnvironmentOverride) || objects !== nothing
        counters.fallback_calls += 1
        counters.environment_fallbacks += 1
    elseif !_trusted_call_epoch(context)
        counters.fallback_calls += 1
        counters.stale_fallbacks += 1
    elseif !_resolved_leases_available(entry.plans)
        counters.fallback_calls += 1
        counters.reentrant_fallbacks += 1
    else
        targets = _resolved_synchronize_view!(entry.targets, context)
        counters.fast_calls += 1
        counters.fast_targets += _resolved_target_count(entry.plans)
        context.calls.epoch.trusted_calls += 1
        _resolved_run_targets!(entry.plans, context, publish, sampled_environment)
        if publish && context.publication_allowed
            for application_id in targets.binding.potential_callee_application_ids
                PSE._record_evaluated_call_clock!(nothing,
                    context.output_retention, application_id, context.time)
            end
        end
        return targets
    end
    return _epoch_fallback_call!(context, name;
        environment, sampled_environment, publish, objects)
end

@inline Base.@constprop :aggressive function PSE.run_call!(
    context::PSE.RunContext{CS,A,CT}, name::Symbol;
    environment=PSE._NO_ENVIRONMENT_OVERRIDE,
    sampled_environment=PSE._UNSPECIFIED_SCENE_ENVIRONMENT,
    publish::Bool=false, objects=nothing,
) where {CS,A,CT<:EpochCallTable}
    if !(environment isa PSE.NoEnvironmentOverride) &&
       !(sampled_environment isa PSE.UnspecifiedModelEnvironment)
        throw(ArgumentError(
            "`environment` and `sampled_environment` are mutually exclusive hard-call overrides.",
        ))
    end
    entry = _epoch_entry(context.calls, Val(name))
    if entry === nothing
        context.calls.counters.fallback_calls += 1
        return _epoch_fallback_call!(context, name;
            environment, sampled_environment, publish, objects)
    end
    return _epoch_run_entry!(entry, context, name, environment,
        sampled_environment, publish, objects)
end

@inline function _epoch_call_model(entry::ResolvedCallEntry{true}, context, name)
    if PSE._active_call_evaluation() === nothing && _trusted_call_epoch(context) &&
       _resolved_target_count(entry.plans) == 1
        context.calls.counters.model_lookups += 1
        return _resolved_single_model(entry.plans)
    end
    _invalidate_call_epoch!(context.calls.epoch)
    return PSE._call_model(_resolved_fallback_context!(context), name)
end
@inline function _epoch_call_model(entry, context, name)
    _invalidate_call_epoch!(context.calls.epoch)
    return PSE._call_model(_resolved_fallback_context!(context), name)
end
@inline function PSE._call_model(context::PSE.RunContext{CS,A,CT},
    name::Val) where {CS,A,CT<:EpochCallTable}
    return _epoch_call_model(_epoch_entry(context.calls, name), context, name)
end

function _epoch_clone_context(context, epoch, contexts)
    context isa PSE.RunContext && context.calls isa ResolvedCallTable || return context
    haskey(contexts, context) && return contexts[context]
    original = context.calls
    entries = map(values(original.entries)) do entry
        entry isa ResolvedCallEntry{true} || return entry
        plans = map(entry.plans) do batch
            rows = [ResolvedTargetPlan(target.owner, target.application,
                _epoch_clone_context(target.context, epoch, contexts))
                for target in batch.targets]
            # Each original logical batch already proved a homogeneous context
            # shape. Reify the rows again after replacing their capability CT.
            Row = typeof(first(rows))
            typed_rows = Vector{Row}(undef, length(rows))
            copyto!(typed_rows, rows)
            ResolvedCallBatchPlan(typed_rows)
        end
        ResolvedCallEntry{true,typeof(entry.targets),typeof(plans)}(entry.targets,
            plans, entry.membership_generation, entry.reason)
    end
    named = NamedTuple{keys(original.entries)}(entries)
    # Retain the original fallback shell and public target views, but do not
    # retain the guarded strategy's prepared contexts through metadata.entries.
    metadata = ResolvedCallTable(NamedTuple(), original.original_calls,
        original.fallback_context, original.counters, original.compiled,
        original.environment_bindings, original.model_revision,
        original.runtime_revision, original.environment_revision)
    table = EpochCallTable(named, metadata, epoch)
    cloned = _resolved_context_with_calls(context, table)
    contexts[context] = cloned
    return cloned
end

struct EpochResolvedRootBatch{B,R,C,S}
    batch::B
    rows::R
    counters::C
    epoch::S
    compiled::Any
    environment_bindings::Any
    transient_guarded_contexts::Int
end

"""
    prepare_epoch_resolved_root(simulation, batch)

Prepare a synchronous stable-call invocation epoch. Callbacks/selected views,
evaluations, overrides and reentrancy retain ordinary PSE behavior. The audited
stable-call promise includes indirect effects and excludes nested advancement
of this Simulation or context-internal mutation during a root invocation.
"""
function prepare_epoch_resolved_root(simulation, batch)
    guarded = prepare_resolved_root(simulation, batch)
    guarded === nothing && return nothing
    epoch = ResolvedInvocationEpoch()
    contexts = IdDict{Any,Any}()
    rows = [ResolvedRootRow(row.owner,
        _epoch_clone_context(row.context, epoch, contexts)) for row in guarded.rows]
    Row = typeof(first(rows))
    typed_rows = Vector{Row}(undef, length(rows))
    copyto!(typed_rows, rows)
    return EpochResolvedRootBatch(batch, typed_rows, guarded.counters, epoch,
        guarded.compiled, guarded.environment_bindings,
        guarded.counters.prepared_contexts)
end

function _epoch_run_current_application!(payload, simulation, step)
    application = get(simulation.compiled.applications_by_id,
        payload.batch.application.id, nothing)
    application === nothing && return nothing
    group = simulation.execution_plan.groups_by_application_slot[application.slot]
    group === nothing && return nothing
    PSE._run_model_execution_group!(group, simulation, step, simulation.performance)
    return nothing
end

function execute_resolved_root!(payload::EpochResolvedRootBatch, simulation, step)
    if payload.compiled !== simulation.compiled ||
       payload.environment_bindings !== simulation.environment_bindings
        payload.counters.stale_fallbacks += 1
        return _epoch_run_current_application!(payload, simulation, step)
    end
    batch = payload.batch
    shared = PSE._model_execution_batch_environment(batch.environment_provider,
        simulation.environment_bindings, batch.application, step)
    epoch = payload.epoch
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
        epoch.running = true
        epoch.task_id = objectid(current_task())
        epoch.root_context = context
        try
            _validate_call_epoch!(epoch, context)
            payload.counters.root_invocations += 1
            PSE.run!(owner.model, status, environment, simulation.constants, context)
            if batch.output_publication.enabled
                PSE._model_publish_runtime_outputs!(owner.output_bindings, step)
            end
        finally
            epoch.active = false
            epoch.running = false
            epoch.task_id = UInt(0)
            epoch.root_context = nothing
        end
    end
    return nothing
end

function resolved_root_report(payload::EpochResolvedRootBatch)
    # Reuse the guarded report shape without retaining guarded contexts.
    base = ResolvedRootBatch(payload.batch, payload.rows, payload.counters,
        payload.compiled, payload.environment_bindings)
    epoch = payload.epoch
    return merge(resolved_root_report(base), (
        call_strategy=:epoch,
        typed_call_capabilities=true,
        epoch_validations=epoch.validations,
        epoch_revalidations=epoch.revalidations,
        epoch_invalidations=epoch.invalidations,
        epoch_validation_failures=epoch.validation_failures,
        epoch_trusted_calls=epoch.trusted_calls,
        epoch_task_fallbacks=epoch.task_fallbacks,
        epoch_active_after_invocation=epoch.active,
        epoch_guarded_contexts_constructed_cold=payload.transient_guarded_contexts,
        epoch_guarded_contexts_retained=false,
    ))
end

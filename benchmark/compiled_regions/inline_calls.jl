# Additive guarded-call strategy. The source scientific method is inlined only
# at this private invocation boundary. All call eligibility, fallback, lease,
# evaluation, environment, revision and publication logic remains guarded.
isdefined(@__MODULE__, :_resolved_context_with_calls) || include("call_context_abi.jl")

struct InlineResolvedTargetPlan{O,A,C}
    owner::O
    application::A
    context::C
end

@noinline function _inline_resolved_call_kernel!(owner, environment, context)
    Base.@inline PSE.run!(owner.model, _resolved_kernel_status(owner), environment,
        context.constants, context)
    if context.publication_allowed
        isempty(owner.output_bindings) ||
            PSE._model_publish_runtime_outputs!(owner.output_bindings, context.time)
        PSE._record_model_call_publication!(context.output_retention,
            context.application.id, context.time)
    end
    return nothing
end

@inline function _resolved_run_target!(plan::InlineResolvedTargetPlan, parent,
    publish, sampled_environment)
    owner = plan.owner
    cache = owner.call_context_cache
    PSE._record_call_execution!(cache, nothing)
    environment = sampled_environment isa PSE.UnspecifiedModelEnvironment ?
        PSE._model_environment_for_binding(parent.environment_bindings,
            plan.application, owner.environment_binding, parent.time,
            parent.environment) : sampled_environment
    context = _resolved_prepare_callee!(plan.context, parent,
        publish && parent.publication_allowed)
    cache.in_use = true
    try
        _inline_resolved_call_kernel!(owner, environment, context)
    finally
        cache.in_use = false
    end
    return nothing
end

function _inline_clone_resolved_context(context, contexts)
    context isa PSE.RunContext && context.calls isa ResolvedCallTable || return context
    haskey(contexts, context) && return contexts[context]
    original = context.calls
    entries = map(values(original.entries)) do entry
        entry isa ResolvedCallEntry{true} || return entry
        plans = map(entry.plans) do batch
            rows = [InlineResolvedTargetPlan(target.owner, target.application,
                _inline_clone_resolved_context(target.context, contexts))
                for target in batch.targets]
            Row = typeof(first(rows))
            typed_rows = Vector{Row}(undef, length(rows))
            copyto!(typed_rows, rows)
            ResolvedCallBatchPlan(typed_rows)
        end
        ResolvedCallEntry{true,typeof(entry.targets),typeof(plans)}(entry.targets,
            plans, entry.membership_generation, entry.reason)
    end
    named = NamedTuple{keys(original.entries)}(entries)
    table = ResolvedCallTable(named, original.original_calls,
        original.fallback_context, original.counters, original.compiled,
        original.environment_bindings, original.model_revision,
        original.runtime_revision, original.environment_revision)
    cloned = _resolved_context_with_calls(context, table)
    contexts[context] = cloned
    return cloned
end

struct InlineResolvedRootBatch{P}
    base::P
end
@inline function Base.getproperty(payload::InlineResolvedRootBatch, name::Symbol)
    name === :base && return getfield(payload, :base)
    return getproperty(getfield(payload, :base), name)
end
Base.propertynames(payload::InlineResolvedRootBatch, private::Bool=false) =
    (:base, propertynames(getfield(payload, :base), private)...)

"""Prepare guarded call rows with an isolated inlined scientific boundary."""
function prepare_inline_resolved_root(simulation, batch)
    guarded = prepare_resolved_root(simulation, batch)
    guarded === nothing && return nothing
    contexts = IdDict{Any,Any}()
    rows = [ResolvedRootRow(row.owner,
        _inline_clone_resolved_context(row.context, contexts)) for row in guarded.rows]
    Row = typeof(first(rows))
    typed_rows = Vector{Row}(undef, length(rows))
    copyto!(typed_rows, rows)
    base = ResolvedRootBatch(batch, typed_rows, guarded.counters,
        guarded.compiled, guarded.environment_bindings)
    return InlineResolvedRootBatch(base)
end

@inline execute_resolved_root!(payload::InlineResolvedRootBatch, simulation, step) =
    execute_resolved_root!(getfield(payload, :base), simulation, step)

function resolved_root_report(payload::InlineResolvedRootBatch)
    return merge(resolved_root_report(getfield(payload, :base)), (
        call_strategy=:inline,
        inline_scientific_boundary=true,
        inline_guarded_contexts_constructed_cold=payload.counters.prepared_contexts,
        inline_guarded_contexts_retained=false,
    ))
end

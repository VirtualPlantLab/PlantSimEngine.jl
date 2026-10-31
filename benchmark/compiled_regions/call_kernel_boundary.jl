# Allocation diagnosis and composition-safe kernel interface. No measured call
# strategy is changed merely by including this file.

@inline selected_call_kernel_status(owner) = _resolved_kernel_status(owner)

# PSE's existing materialized-call executor uses the same ownership principle:
# cross a potentially erased environment boundary with the mutable execution
# owner, then extract model/status/output tuples inside the typed function.
@noinline function call_owner_kernel_boundary!(owner, environment, context)
    PSE._run_call_kernel!(owner.model, selected_call_kernel_status(owner),
        environment, context, owner.output_bindings)
    return nothing
end

@noinline function _probe_call_owner_boundary!(target, context, environment,
    repetitions)
    child = _resolved_prepare_callee!(target.context, context, false)
    for _ in 1:repetitions
        call_owner_kernel_boundary!(target.owner, environment, child)
    end
    return nothing
end

function probe_call_owner_boundary(payload::ResolvedRootBatch, environment;
    repetitions=512, depth=1)
    context = first(payload.rows).context
    context.time = max(context.time, 1.0)
    target = nothing
    for level in 1:depth
        entries = [entry for entry in values(context.calls.entries)
            if entry isa ResolvedCallEntry{true} && _resolved_target_count(entry.plans) > 0]
        isempty(entries) && error("No nonempty resolved call at requested depth")
        target = first(first(first(entries).plans).targets)
        level == depth || (context = target.context)
    end
    _probe_call_owner_boundary!(target, context, environment, repetitions)
    measured = @timed _probe_call_owner_boundary!(target, context, environment, repetitions)
    status = selected_call_kernel_status(target.owner)
    return (; depth, repetitions, phase=_probe_call_phase(measured),
        selected_status_matches_full=status === target.owner.status,
        selected_status_fields=length(keys(getfield(status, :vars))),
        full_status_fields=length(keys(target.owner.status)))
end

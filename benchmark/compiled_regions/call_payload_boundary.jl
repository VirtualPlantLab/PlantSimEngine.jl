# Diagnostic only: isolate specialization on the scientific payload from the
# source owner's unrelated context/cache/binding type parameters.
mutable struct CallKernelPayload{M,S,OB}
    model::M
    status::S
    output_bindings::OB
end

@noinline function call_payload_kernel_boundary!(payload, environment, context)
    PSE._run_call_kernel!(payload.model, payload.status, environment, context,
        payload.output_bindings)
    return nothing
end

@noinline function call_payload_inlined_boundary!(payload, environment, context)
    Base.@inline PSE.run!(payload.model, payload.status, environment,
        context.constants, context)
    if context.publication_allowed
        isempty(payload.output_bindings) ||
            PSE._model_publish_runtime_outputs!(payload.output_bindings, context.time)
        PSE._record_model_call_publication!(context.output_retention,
            context.application.id, context.time)
    end
    return nothing
end

@noinline function _probe_call_payload_boundary!(boundary::F, payload, target,
    parent, environment, repetitions) where {F}
    child = _resolved_prepare_callee!(target.context, parent, false)
    for _ in 1:repetitions
        boundary(payload, environment, child)
    end
    return nothing
end

function probe_call_payload_boundaries(resolved::ResolvedRootBatch, environment;
    repetitions=512, depth=1, ir_prefix=nothing)
    parent = first(resolved.rows).context
    parent.time = max(parent.time, 1.0)
    target = nothing
    for level in 1:depth
        entries = [entry for entry in values(parent.calls.entries)
            if entry isa ResolvedCallEntry{true} && _resolved_target_count(entry.plans) > 0]
        isempty(entries) && error("No nonempty resolved call at requested depth")
        target = first(first(first(entries).plans).targets)
        level == depth || (parent = target.context)
    end
    owner = target.owner
    payload = CallKernelPayload(owner.model, _resolved_kernel_status(owner),
        owner.output_bindings)
    reports = map((call_payload_kernel_boundary!,
        call_payload_inlined_boundary!)) do boundary
        _probe_call_payload_boundary!(boundary, payload, target, parent,
            environment, repetitions)
        measured = @timed _probe_call_payload_boundary!(boundary, payload,
            target, parent, environment, repetitions)
        inference = if isdefined(@__MODULE__, :_call_probe_typed_summary)
            _call_probe_typed_summary(boundary,
                Tuple{typeof(payload),typeof(environment),typeof(target.context)};
                ir_path=isnothing(ir_prefix) ? nothing :
                    string(ir_prefix, "-", nameof(boundary), ".txt"))
        else
            nothing
        end
        (; boundary=nameof(boundary), phase=_probe_call_phase(measured),
            bytes_per_kernel=measured.bytes / repetitions, inference)
    end
    return (; repetitions, depth, reports,
        payload_bytes=sizeof(payload),
        note=:minimal_mutable_payload_original_science_status_context_publication)
end

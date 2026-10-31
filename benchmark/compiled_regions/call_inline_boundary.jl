# Isolated call-site inlining diagnostic. Scientific run! definitions remain
# untouched, and the normal executor/resolved strategies are not replaced.

@noinline function call_inlined_science_boundary!(owner, environment, context)
    # Force only this private invocation to inline. The compiler is otherwise
    # free to retain each original scientific method's normal call boundaries.
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

@noinline function _probe_call_inline_boundary!(target, parent, environment,
    repetitions)
    child = _resolved_prepare_callee!(target.context, parent, false)
    for _ in 1:repetitions
        call_inlined_science_boundary!(target.owner, environment, child)
    end
    return nothing
end

function probe_call_inline_boundary(payload::ResolvedRootBatch, environment;
    repetitions=512, depth=1, ir_prefix=nothing)
    parent = first(payload.rows).context
    parent.time = max(parent.time, 1.0)
    target = nothing
    for level in 1:depth
        entries = [entry for entry in values(parent.calls.entries)
            if entry isa ResolvedCallEntry{true} && _resolved_target_count(entry.plans) > 0]
        isempty(entries) && error("No nonempty resolved call at requested depth")
        target = first(first(first(entries).plans).targets)
        level == depth || (parent = target.context)
    end
    _probe_call_inline_boundary!(target, parent, environment, repetitions)
    measured = @timed _probe_call_inline_boundary!(target, parent, environment,
        repetitions)
    boundary = if isdefined(@__MODULE__, :_call_probe_typed_summary)
        _call_probe_typed_summary(call_inlined_science_boundary!,
            Tuple{typeof(target.owner),typeof(environment),typeof(target.context)};
            ir_path=isnothing(ir_prefix) ? nothing : string(ir_prefix, "-inline.txt"))
    else
        nothing
    end
    return (; repetitions, depth, phase=_probe_call_phase(measured),
        bytes_per_kernel=measured.bytes / repetitions, boundary,
        note=:generic_callsite_inline_original_science_and_publication)
end

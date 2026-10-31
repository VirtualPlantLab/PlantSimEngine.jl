# Isolated explicit-method-selection diagnostic. Included after
# call_allocation_probes.jl; it does not alter either measured call strategy.

@noinline function call_invoked_science_boundary!(owner::O, environment::E,
    context::C) where {O,E,C}
    model = owner.model
    status = _resolved_kernel_status(owner)
    constants = context.constants
    invoke(PSE.run!, Tuple{typeof(model),typeof(status),E,typeof(constants),C},
        model, status, environment, constants, context)
    if context.publication_allowed
        isempty(owner.output_bindings) ||
            PSE._model_publish_runtime_outputs!(owner.output_bindings, context.time)
        PSE._record_model_call_publication!(context.output_retention,
            context.application.id, context.time)
    end
    return nothing
end

@noinline function call_inlined_invoked_science_boundary!(owner::O, environment::E,
    context::C) where {O,E,C}
    model = owner.model
    status = _resolved_kernel_status(owner)
    constants = context.constants
    Base.@inline invoke(PSE.run!,
        Tuple{typeof(model),typeof(status),E,typeof(constants),C},
        model, status, environment, constants, context)
    if context.publication_allowed
        isempty(owner.output_bindings) ||
            PSE._model_publish_runtime_outputs!(owner.output_bindings, context.time)
        PSE._record_model_call_publication!(context.output_retention,
            context.application.id, context.time)
    end
    return nothing
end

@noinline function _probe_call_invoked_boundary!(boundary::F, target, parent,
    environment, repetitions) where {F}
    child = _resolved_prepare_callee!(target.context, parent, false)
    for _ in 1:repetitions
        boundary(target.owner, environment, child)
    end
    return nothing
end

function probe_call_invoke_boundaries(payload::ResolvedRootBatch, environment;
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
    reports = map((call_invoked_science_boundary!,
        call_inlined_invoked_science_boundary!)) do boundary
        _probe_call_invoked_boundary!(boundary, target, parent, environment,
            repetitions)
        measured = @timed _probe_call_invoked_boundary!(boundary, target, parent,
            environment, repetitions)
        inference = if isdefined(@__MODULE__, :_call_probe_typed_summary)
            _call_probe_typed_summary(boundary,
                Tuple{typeof(target.owner),typeof(environment),typeof(target.context)};
                ir_path=isnothing(ir_prefix) ? nothing :
                    string(ir_prefix, "-", nameof(boundary), ".txt"))
        else
            nothing
        end
        (; boundary=nameof(boundary), phase=_probe_call_phase(measured),
            bytes_per_kernel=measured.bytes / repetitions, inference)
    end
    return (; repetitions, depth, reports,
        note=:generic_explicit_method_selection_original_science_and_publication)
end

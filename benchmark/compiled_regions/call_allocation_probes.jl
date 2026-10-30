# Diagnostic only. Use a separately built, already executed PB fixture so these
# unpublished repeated calls do not alter a scientific comparison sample.

@noinline function _probe_resolved_guards!(entry, context, repetitions)
    result = true
    for _ in 1:repetitions
        result &= _resolved_call_current(entry, context)
    end
    return result
end

@noinline function _probe_resolved_view!(entry, context, repetitions)
    for _ in 1:repetitions
        _resolved_synchronize_view!(entry.targets, context)
    end
    return nothing
end

@noinline function _probe_resolved_target!(target, context, environment, repetitions)
    for _ in 1:repetitions
        _resolved_run_target!(target, context, false, environment)
    end
    return nothing
end

@noinline function _probe_resolved_kernel!(target, context, environment, repetitions)
    child = _resolved_prepare_callee!(target.context, context, false)
    for _ in 1:repetitions
        PSE._run_call_kernel!(target.owner.model, _resolved_kernel_status(target.owner),
            environment, child, target.owner.output_bindings)
    end
    return nothing
end

@noinline function _probe_resolved_named!(context, ::Val{Name}, environment,
    repetitions) where {Name}
    for _ in 1:repetitions
        PSE.run_call!(context, Name; sampled_environment=environment, publish=false)
    end
    return nothing
end

@noinline function _probe_resolved_model!(context, ::Val{Name}, repetitions) where {Name}
    model = PSE.call_model(context, Name)
    for _ in 1:repetitions
        model = PSE.call_model(context, Name)
    end
    return model
end

_probe_call_phase(m) = (seconds=m.time, bytes=m.bytes,
    compilation_seconds=m.compile_time, gc_seconds=m.gctime)

function probe_call_allocations(payload::ResolvedRootBatch, environment;
    repetitions=512, depth=1)
    context = first(payload.rows).context
    context.time = max(context.time, 1.0)
    depth > 0 || error("depth must be positive")
    name = nothing
    entry = target = nothing
    for level in 1:depth
        context.calls isa ResolvedCallTable || error("Requested call depth is unavailable.")
        entries = [(name, entry) for (name, entry) in pairs(context.calls.entries)
            if entry isa ResolvedCallEntry{true} && _resolved_target_count(entry.plans) > 0]
        isempty(entries) && error("Allocation probe needs one nonempty resolved call.")
        name, entry = first(entries)
        target = first(first(entry.plans).targets)
        level == depth || (context = target.context)
    end
    # Each phase is warmed independently before bytes are captured. Guards/view
    # probes have observable return values so the loop is not wholly dead work.
    _probe_resolved_guards!(entry, context, repetitions)
    _probe_resolved_view!(entry, context, repetitions)
    _probe_resolved_target!(target, context, environment, repetitions)
    _probe_resolved_kernel!(target, context, environment, repetitions)
    _probe_resolved_named!(context, Val(name), environment, repetitions)
    single = _resolved_target_count(entry.plans) == 1
    single && _probe_resolved_model!(context, Val(name), repetitions)
    guards = @timed _probe_resolved_guards!(entry, context, repetitions)
    view = @timed _probe_resolved_view!(entry, context, repetitions)
    target_run = @timed _probe_resolved_target!(target, context, environment, repetitions)
    kernel = @timed _probe_resolved_kernel!(target, context, environment, repetitions)
    named = @timed _probe_resolved_named!(context, Val(name), environment, repetitions)
    model = single ? (@timed _probe_resolved_model!(context, Val(name), repetitions)) : nothing
    status = _resolved_kernel_status(target.owner)
    return (; repetitions, depth, name, phases=(guards=_probe_call_phase(guards),
        view=_probe_call_phase(view), target=_probe_call_phase(target_run),
        kernel=_probe_call_phase(kernel), named=_probe_call_phase(named),
        model_lookup=isnothing(model) ? nothing : _probe_call_phase(model)),
        status_container_bytes=sizeof(status),
        full_status_container_bytes=sizeof(target.owner.status),
        selected_status_matches_full=status === target.owner.status,
        model_container_bytes=sizeof(target.owner.model),
        sampled_environment_bytes=sizeof(environment),
        capability_table_bytes=sizeof(context.calls),
        entry_bytes=sizeof(entry),
        target_plan_bytes=sizeof(target),
        plan_type=string(nameof(typeof(target))),
        note=:unpublished_diagnostic_mutates_separate_fixture)
end

# Read-only structure diagnostics and unpublished kernel probes on ACTUAL
# prepared strategy contexts. Run only on separate fixtures after measurements;
# repeated scientific calls mutate their live state. No executor is changed.

_call_diagnostic_base(payload::ResolvedRootBatch) = payload
_call_diagnostic_base(payload::InlineResolvedRootBatch) = getfield(payload, :base)

function _call_diagnostic_target(payload, depth)
    depth > 0 || error("depth must be positive")
    parent = first(_call_diagnostic_base(payload).rows).context
    target = entry = name = nothing
    for level in 1:depth
        choices = [(name, entry) for (name, entry) in pairs(parent.calls.entries)
            if entry isa ResolvedCallEntry{true} && _resolved_target_count(entry.plans) > 0]
        isempty(choices) && error("No nonempty resolved call at requested depth")
        name, entry = first(choices)
        target = first(first(entry.plans).targets)
        level == depth || (parent = target.context)
    end
    return (; parent, target, entry, name)
end

function _call_diagnostic_context_shape(context)
    Type = typeof(context)
    table_type = typeof(context.calls)
    table_erased = context.calls isa ResolvedCallTable ?
        (original_calls=fieldtype(table_type, :original_calls) === Any,
            fallback_context=fieldtype(table_type, :fallback_context) === Any) : nothing
    fallback_erased = if context.calls isa ResolvedCallTable
        fallback_type = typeof(context.calls.fallback_context)
        (compiled=fieldtype(fallback_type, :compiled) === Any,
            application=fieldtype(fallback_type, :application) === Any,
            temporal_streams=fieldtype(fallback_type, :temporal_streams) === Any)
    else
        nothing
    end
    return (context_kind=nameof(Type),
        context_parameter_count=length(Type.parameters),
        erased=(compiled=fieldtype(Type, :compiled) === Any,
            application=fieldtype(Type, :application) === Any,
            temporal_streams=fieldtype(Type, :temporal_streams) === Any,
            constants=fieldtype(Type, :constants) === Any,
            environment=fieldtype(Type, :environment) === Any),
        call_table_kind=nameof(table_type),
        call_table_erased=table_erased, fallback_erased)
end

@noinline function _probe_actual_call_target!(target, parent, environment, repetitions)
    for _ in 1:repetitions
        _resolved_run_target!(target, parent, false, environment)
    end
    return nothing
end

@noinline function _probe_actual_ordinary_kernel!(target, parent, environment, repetitions)
    child = _resolved_prepare_callee!(target.context, parent, false)
    for _ in 1:repetitions
        PSE._run_call_kernel!(target.owner.model,
            _resolved_kernel_status(target.owner), environment, child,
            target.owner.output_bindings)
    end
    return nothing
end

@noinline function _probe_actual_inline_kernel!(target, parent, environment, repetitions)
    child = _resolved_prepare_callee!(target.context, parent, false)
    for _ in 1:repetitions
        _inline_resolved_call_kernel!(target.owner, environment, child)
    end
    return nothing
end

function _measure_actual_call_boundary(probe::F, target, parent, environment,
    repetitions) where {F}
    probe(target, parent, environment, repetitions)
    measured = @timed probe(target, parent, environment, repetitions)
    return (; boundary=nameof(probe), phase=_probe_call_phase(measured),
        bytes_per_kernel=measured.bytes / repetitions)
end

function _actual_call_small_inference(function_, arguments; ir_path=nothing)
    summaries = _call_probe_typed_summary(function_, arguments; ir_path)
    return map(summaries) do summary
        (; return_type=summary.return_type, any_values=summary.any_values,
            direct_calls=summary.direct_calls, dynamic_calls=summary.dynamic_calls,
            run_invokes=hasproperty(summary, :run_invokes) ? summary.run_invokes : missing,
            run_generic_calls=hasproperty(summary, :run_generic_calls) ?
                summary.run_generic_calls : missing)
    end
end

function _probe_actual_call_boundaries(selected, environment, repetitions, ir_prefix)
    target, parent = selected.target, selected.parent
    phases = map((_probe_actual_call_target!, _probe_actual_ordinary_kernel!,
        _probe_actual_inline_kernel!)) do probe
        _measure_actual_call_boundary(probe, target, parent, environment, repetitions)
    end
    inference = if isdefined(@__MODULE__, :_call_probe_typed_summary)
        owner = target.owner
        context = target.context
        status = _resolved_kernel_status(owner)
        boundary = _actual_call_small_inference(_inline_resolved_call_kernel!,
            Tuple{typeof(owner),typeof(environment),typeof(context)};
            ir_path=isnothing(ir_prefix) ? nothing : string(ir_prefix, "-actual-inline.txt"))
        scientific = _actual_call_small_inference(PSE.run!,
            Tuple{typeof(owner.model),typeof(status),typeof(environment),
                typeof(context.constants),typeof(context)};
            ir_path=isnothing(ir_prefix) ? nothing : string(ir_prefix, "-science.txt"))
        (; boundary, scientific)
    else
        nothing
    end
    return (; phases, inference)
end

function _actual_root_science_inference(payload, environment, ir_path)
    isdefined(@__MODULE__, :_call_probe_typed_summary) || return nothing
    row = first(_call_diagnostic_base(payload).rows)
    context = row.context
    owner = row.owner
    return _actual_call_small_inference(PSE.run!,
        Tuple{typeof(owner.model),typeof(_resolved_kernel_status(owner)),
            typeof(environment),typeof(context.constants),typeof(context)}; ir_path)
end

"""Compare guarded and inline payloads from actual prepared application plans."""
function compare_call_application_boundaries(guarded_payload, inline_payload, environment;
    depth=1, repetitions=256, ir_prefix=nothing)
    repetitions > 0 || error("repetitions must be positive")
    guarded = _call_diagnostic_target(guarded_payload, depth)
    inlined = _call_diagnostic_target(inline_payload, depth)
    guarded.parent.time = max(guarded.parent.time, 1.0)
    inlined.parent.time = max(inlined.parent.time, 1.0)
    left, right = guarded.target, inlined.target
    field_types_equal = NamedTuple{fieldnames(typeof(left.context))}(Tuple(
        fieldtype(typeof(left.context), name) === fieldtype(typeof(right.context), name)
        for name in fieldnames(typeof(left.context))))
    guarded_probe = _probe_actual_call_boundaries(guarded, environment, repetitions,
        isnothing(ir_prefix) ? nothing : string(ir_prefix, "-guarded"))
    inline_probe = _probe_actual_call_boundaries(inlined, environment, repetitions,
        isnothing(ir_prefix) ? nothing : string(ir_prefix, "-cloned"))
    root_inference = (
        guarded=_actual_root_science_inference(guarded_payload, environment,
            isnothing(ir_prefix) ? nothing : string(ir_prefix, "-guarded-root.txt")),
        inlined=_actual_root_science_inference(inline_payload, environment,
            isnothing(ir_prefix) ? nothing : string(ir_prefix, "-cloned-root.txt")))
    return (; depth, repetitions, guarded_name=guarded.name, inline_name=inlined.name,
        scientific_model=nameof(typeof(left.owner.model)),
        actual_plan_kinds=(guarded=nameof(typeof(left)), inlined=nameof(typeof(right))),
        same_owner_type=typeof(left.owner) === typeof(right.owner),
        same_selected_status_type=typeof(_resolved_kernel_status(left.owner)) ===
            typeof(_resolved_kernel_status(right.owner)),
        same_context_type=typeof(left.context) === typeof(right.context),
        context_field_types_equal=field_types_equal,
        guarded_context=_call_diagnostic_context_shape(left.context),
        inline_context=_call_diagnostic_context_shape(right.context),
        guarded_probe, inline_probe, root_inference,
        note=:actual_strategy_contexts_unpublished_diagnostic_mutates_separate_fixtures)
end

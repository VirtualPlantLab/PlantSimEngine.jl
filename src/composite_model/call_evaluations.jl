@inline function _publish_evaluated_call!(::Nothing, outputs, context)
    isempty(outputs) || _model_publish_runtime_outputs!(outputs, context.time)
    _record_model_call_publication!(context.output_retention, context.application.id, context.time)
    return nothing
end

function _capture_call_output!(frame, output::RuntimeOutputStream, time)
    value = deepcopy(output.reference[])
    push!(frame.events, CapturedCallOutput(output, output.stream, value, time))
    return nothing
end

function _capture_call_output!(frame, output::RuntimeDistributedOutputStream, time)
    for index in eachindex(output.references, output.streams)
        value = deepcopy(output.references[index])
        push!(frame.events, CapturedCallOutput(output, output.streams[index], value, time))
    end
    return nothing
end

function _publish_evaluated_call!(frame::CallEvaluationFrame, outputs, context)
    for output in outputs
        _capture_call_output!(frame, output, context.time)
    end
    _record_evaluated_call_clock!(context.output_retention, context.application.id, context.time)
    return nothing
end

function _evaluated_temporal_source(frame::CallEvaluationFrame, stream::S) where {S<:AbstractVector}
    source = frame.parent === nothing ? stream :
        _evaluated_temporal_source(frame.parent, stream)
    for event in frame.events
        if event isa CapturedCallOutput && event.stream === stream
            # Build a private read view only when a staged publication affects
            # this input. Ancestor views are already private and can be reused.
            source === stream && (source = collect(stream))
            _model_publish_runtime_output_value!(event.output, source, event.value,
                event.time; copy_value=false)
        end
    end
    return source::Union{S,Vector{eltype(S)}}
end

@inline function _evaluated_temporal_sample_value(stream, time, policy, t_start, timeline)
    frame = _active_call_evaluation()
    frame === nothing && return _model_temporal_sample_value(stream, time, policy, t_start, timeline)
    source = _evaluated_temporal_source(frame, stream)
    return _model_temporal_sample_value(source, time, policy, t_start, timeline)
end

@inline function _record_evaluated_call_clock!(plan, application, time)
    frame = _active_call_evaluation()
    if frame === nothing
        _record_model_call_publication!(plan, application, time)
    elseif plan isa OutputRetentionPlan && haskey(plan.accepted_call_times, application)
        push!(frame.events, CapturedCallClock(plan, application, time))
    end
    return nothing
end

function _evaluation_frame!(targets::CallTargets)
    frame = targets.evaluation
    if frame === nothing
        frame = CallEvaluationFrame()
        targets.evaluation = frame
    end
    # Recursive evaluation needs independent working storage.
    return frame.in_use ? CallEvaluationFrame() : frame
end

function _evaluation_frame!(target::CallTarget)
    cache = target.context_cache
    frame = cache.evaluation
    if frame === nothing
        frame = CallEvaluationFrame()
        cache.evaluation = frame
    end
    return frame.in_use ? CallEvaluationFrame() : frame
end

function _evaluation_target(target::CallTarget)
    return CallTarget(target.execution_target, target.compiled, target.environment_bindings,
        target.application, target.object_id, target.calls, target.temporal_streams,
        target.output_retention, target.time, target.constants, true, target.environment)
end

function _evaluate_call_targets!(targets::CallTargets, sampled_environment, environment)
    previous_permission = targets.publication_allowed
    try
        targets.publication_allowed = true
        _run_call_targets!(targets, true, sampled_environment, environment)
    finally
        targets.publication_allowed = previous_permission
    end
    return nothing
end

function _evaluate_call_targets!(targets::AbstractVector{<:CallTarget}, sampled_environment, environment)
    # Targeted newborn execution has lightweight individual views before the
    # lifecycle barrier installs the ordinary compiled batch.
    for target in targets
        _run_call!(_evaluation_target(target), true, sampled_environment, environment)
    end
    return nothing
end

function _begin_call_evaluation!(frame, compiled, time, permission)
    frame.generation += UInt64(1)
    frame.pending = false
    frame.in_use = true
    empty!(frame.events)
    empty!(frame.executions)
    frame.task = current_task()
    frame.compiled = compiled
    frame.model_revision = compiled.model.revision
    frame.runtime_revision = compiled.model.runtime_revision
    frame.environment_revision = compiled.model.environment_revision
    frame.lifecycle_delta = lifecycle_delta(compiled.model)
    frame.lifecycle_generation = frame.lifecycle_delta.mutation_generation
    frame.binding_flags = (compiled.model.bindings_dirty, compiled.model.environment_bindings_dirty)
    frame.execution_generation = compiled.execution_generation
    frame.time = time
    frame.parent = _active_call_evaluation()
    frame.parent_generation = frame.parent === nothing ? UInt64(0) : frame.parent.generation
    frame.publication_allowed = permission
    return frame
end

function _with_call_evaluation(f, frame)
    storage = task_local_storage()
    present = haskey(storage, _CALL_EVALUATION_TLS_KEY)
    previous = get(storage, _CALL_EVALUATION_TLS_KEY, nothing)
    storage[_CALL_EVALUATION_TLS_KEY] = frame
    try
        result = f()
        frame.pending = true
        return result
    catch
        empty!(frame.events)
        empty!(frame.executions)
        rethrow()
    finally
        frame.in_use = false
        if present
            storage[_CALL_EVALUATION_TLS_KEY] = previous
        else
            delete!(storage, _CALL_EVALUATION_TLS_KEY)
        end
    end
end

"""
    evaluate_call!(context::RunContext, name::Symbol;
                   environment, sampled_environment, objects=nothing)
    evaluate_call!(target::CallTarget; environment, sampled_environment)

Evaluate a declared hard call once and return a [`CallEvaluation`](@ref).
[`accept_call!`](@ref) records that evaluation without executing its kernels
again. Environment keywords have the same meaning as in [`run_call!`](@ref).

Evaluation mutates live statuses, just like an unpublished `run_call!`. It
captures only publication-intended retained/dependency outputs, environment
commit requests and call-clock events. Nested `publish=false` calls remain
unpublished; nested `publish=true` calls stage their events instead of exposing
them. Child evaluations accepted within a parent evaluation stage into that
parent. All calls in an evaluation must be synchronous on the current task.

Accept only the latest evaluation for a selection, before changing its live
inputs/status, running the same targets again, advancing the simulation or
changing topology, bindings or models. Earlier candidates need caller-owned
scientific state/inputs and a new evaluation; this API does not roll status
back. Workspace vectors are reused, while retained mutable output values are
snapshotted at publication intent so later writers cannot change them.

Deferred environment commits are not a speculative backend overlay. Pass trial
state explicitly with `environment=state` when descendants need it. Acceptance
publishes the evaluated state, not a subsequently proposed numerical iterate.
"""
function evaluate_call!(context::RunContext, name::Symbol;
    environment=_NO_ENVIRONMENT_OVERRIDE,
    sampled_environment=_UNSPECIFIED_SCENE_ENVIRONMENT, objects=nothing)
    if !(environment isa NoEnvironmentOverride) &&
       !(sampled_environment isa UnspecifiedModelEnvironment)
        throw(ArgumentError("`environment` and `sampled_environment` are mutually exclusive hard-call overrides."))
    end
    targets = isnothing(objects) ? call_targets(context, name) : call_targets(context, name; objects=objects)
    workspace = targets isa CallTargets ? targets : _model_call_targets(context, name)
    frame = _evaluation_frame!(workspace)
    permission = context.publication_allowed
    compiled = targets isa CallTargets ? targets.compiled :
        isempty(targets) ? context.compiled : first(targets).compiled
    _begin_call_evaluation!(frame, compiled, context.time, permission)
    selected_environment = environment isa NoEnvironmentOverride ? context.environment : environment
    # Logical publication is captured by the journal; it never reaches a
    # stream/backend until acceptance permits it.
    _with_call_evaluation(frame) do
        _evaluate_call_targets!(targets, sampled_environment, selected_environment)
    end
    return CallEvaluation(frame, frame.generation, targets)
end

function evaluate_call!(target::CallTarget;
    environment=_NO_ENVIRONMENT_OVERRIDE, sampled_environment=_UNSPECIFIED_SCENE_ENVIRONMENT)
    if !(environment isa NoEnvironmentOverride) &&
       !(sampled_environment isa UnspecifiedModelEnvironment)
        throw(ArgumentError("`environment` and `sampled_environment` are mutually exclusive hard-call overrides."))
    end
    frame = _evaluation_frame!(target)
    _begin_call_evaluation!(frame, target.compiled, target.time, target.publication_allowed)
    selected_environment = environment isa NoEnvironmentOverride ? target.environment : environment
    # A materialized view carries the same execution owner and cache, with
    # journal-local logical publication permission.
    logical = _evaluation_target(target)
    _with_call_evaluation(frame) do
        _run_call!(logical, true, sampled_environment, selected_environment)
    end
    return CallEvaluation(frame, frame.generation, (target,))
end

call_targets(evaluation::CallEvaluation) = evaluation.targets

function _validate_call_evaluation(evaluation::CallEvaluation)
    frame = evaluation.frame
    frame.task === current_task() || throw(ArgumentError("Accept a call evaluation on its originating task."))
    frame.pending && frame.generation == evaluation.generation ||
        throw(ArgumentError("Call evaluation is stale or has already been accepted."))
    model = frame.compiled.model
    model.revision == frame.model_revision && model.runtime_revision == frame.runtime_revision &&
        model.environment_revision == frame.environment_revision &&
        lifecycle_delta(model) === frame.lifecycle_delta &&
        frame.lifecycle_delta.mutation_generation == frame.lifecycle_generation &&
        frame.compiled.execution_generation == frame.execution_generation &&
        (model.bindings_dirty, model.environment_bindings_dirty) == frame.binding_flags ||
        throw(ArgumentError("Call evaluation is stale after a simulation, model or binding change."))
    for (cache, revision) in frame.executions
        cache.execution_revision == revision ||
            throw(ArgumentError("Call evaluation is stale after another execution of its targets."))
    end
    frame.parent === _active_call_evaluation() ||
        throw(ArgumentError("Accept a nested evaluation inside its originating parent evaluation."))
    if frame.parent !== nothing
        frame.parent.in_use && frame.parent.generation == frame.parent_generation ||
            throw(ArgumentError("Nested call evaluation belongs to an earlier parent candidate."))
    end
    return frame
end

function _accept_call_event!(event::CapturedCallOutput)
    _model_publish_runtime_output_value!(event.output, event.stream, event.value, event.time;
        copy_value=false)
    return nothing
end

function _accept_call_event!(event::CapturedCallClock)
    _record_model_call_publication!(event.plan, event.application, event.time)
    return nothing
end

function _accept_call_event!(event::CapturedEnvironmentCommit)
    commit_environment!(event.backend, event.handle, event.state, event.time)
    return nothing
end

"""
    accept_call!(evaluation::CallEvaluation)

Publish one latest successful [`evaluate_call!`](@ref) without rerunning models.
Validate the whole token before any publication. Within an outer evaluation,
append the child's events to its parent's journal; under an unpublished caller,
consume the token without publishing. Return the same token.

This is an acceptance/publication operation, not model-state rollback or an
atomic transaction across arbitrary backend side effects. Backend commit
methods must provide their own exception semantics.
"""
function accept_call!(evaluation::CallEvaluation)
    frame = _validate_call_evaluation(evaluation)
    frame.pending = false
    try
        if frame.publication_allowed
            parent = _active_call_evaluation()
            if parent === nothing
                for event in frame.events
                    _accept_call_event!(event)
                end
            else
                append!(parent.events, frame.events)
            end
        end
    finally
        # Keep prepared capacity, but release consumed snapshots. Published
        # streams or the parent journal now own the captured values.
        empty!(frame.events)
        empty!(frame.executions)
    end
    return evaluation
end

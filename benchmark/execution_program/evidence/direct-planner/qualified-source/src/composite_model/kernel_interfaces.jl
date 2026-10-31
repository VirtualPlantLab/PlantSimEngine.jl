# The local interface is lowered once while preparing an execution target.
# Keep the full status for temporal materialization, publication and public
# CallTarget access; scientific kernels receive this local reference view.
function _kernel_execution_status(compiled, application, model, status::Status)
    compiled.execution_policy.narrow_status || return status
    names = Symbol[]
    for schema in (inputs_(model), outputs_(model))
        for name in keys(schema)
            name = Symbol(name)
            hasproperty(status, name) && !(name in names) && push!(names, name)
        end
    end
    references = Ref[refvalue(status, name) for name in names]
    local_fields = NamedTuple{Tuple(names)}(Tuple(references))
    return Status(local_fields, _status_identity(status), status)
end

@inline function _execution_kernel_status(target)
    stored = target.kernel_status
    return isnothing(stored) ? target.status : stored
end

# Untimed diagnostics for the experiment harness. Do not materialize lazy call
# batches merely to count them: this reports prepared scheduled root payloads.
function _execution_policy_summary(simulation)
    rich = shared = narrow = full = local_context = broad_context = absent_context = 0
    for group in simulation.execution_plan.groups
        for batch in group.batches
            for target in batch.targets
                target isa CompiledExecutionTarget ? (rich += 1) : (shared += 1)
                _execution_kernel_status(target) === target.status ?
                    (full += 1) : (narrow += 1)
                context = target.context
                if context isa RunContext
                    fieldtype(typeof(context), :compiled) === Any ?
                        (local_context += 1) : (broad_context += 1)
                else
                    absent_context += 1
                end
            end
        end
    end
    policy = simulation.compiled.execution_policy
    return (
        policy=(narrow_status=policy.narrow_status, local_context=policy.local_context,
                shared_plans=policy.shared_plans),
        rich_targets=rich, shared_targets=shared, narrow_statuses=narrow,
        full_statuses=full, local_contexts=local_context,
        broad_contexts=broad_context, absent_contexts=absent_context,
    )
end

function _execution_run_context(
    compiled, environment_bindings, application, object_id, calls, bound_inputs,
    output_targets, temporal_streams, output_retention, time, constants,
    publication_allowed, environment,
)
    if compiled.execution_policy.local_context
        # Calls are control-plane capabilities. Nonempty CallTargets themselves
        # contain scene-wide types, so retaining their exact tuple type here
        # would move rather than sever that dependency. Empty calls stay exact.
        Calls = isempty(calls) ? typeof(calls) : Any
        return RunContext{
            Any,Any,Calls,typeof(bound_inputs),typeof(output_targets),Any,
            typeof(output_retention),typeof(constants),typeof(environment),
        }(
            compiled, environment_bindings, application, object_id, calls,
            bound_inputs, output_targets, temporal_streams, output_retention,
            float(time), constants, publication_allowed, environment,
        )
    end
    return RunContext(
        compiled, environment_bindings, application, object_id, calls,
        bound_inputs, output_targets, temporal_streams, output_retention,
        float(time), constants, publication_allowed, environment,
    )
end

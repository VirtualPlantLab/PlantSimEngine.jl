abstract type ExecutionTopology end
struct DynamicExecution <: ExecutionTopology end
struct FixedExecution <: ExecutionTopology end

# Both container representations enter the same group/batch executor. Scalar
# metadata dispatch keeps a closed tuple's group concrete inside the callback.
@inline function _run_execution_slot!(groups::G, slot::Int, simulation::Simulation, step::Integer) where {G<:Union{AbstractVector,Tuple}}
    return _with_metadata_entry(groups, slot) do group
        isnothing(group) && return false
        _run_model_execution_group!(group, simulation, step, simulation.performance)
        return true
    end
end

function _refresh_timeline!(simulation::Simulation, ::DynamicExecution)
    lifecycle = _pending_output_request_lifecycle_delta(simulation.model)
    _refresh_simulation_runtime!(simulation)
    _refresh_output_request_targets!(simulation, lifecycle)
    return simulation
end

@inline function _refresh_timeline!(simulation::Simulation, ::FixedExecution)
    _simulation_runtime_dirty(simulation, nothing) && throw(ArgumentError(
        "Compiled simulation topology and bindings must stay fixed.",
    ))
    return simulation
end

"""Close schedule container schemas without copying the live execution payloads."""
function _fixed_execution_plan(plan::CompiledExecutionPlan)
    groups = Tuple(_close_execution_group_cohorts(group; batches=Tuple(group.batches)) for group in plan.groups)
    groups_by_id = Dict(group.application.id => group for group in groups)
    groups_by_slot = Tuple(isnothing(group) ? nothing : groups_by_id[group.application.id]
        for group in plan.groups_by_application_slot)
    batches = Tuple(batch for group in groups for batch in group.batches)
    return CompiledExecutionPlan(
        plan.cohorts,
        FixedExecution(),
        groups,
        batches,
        groups_by_slot,
        plan.schedule,
        plan.model_revision,
        plan.environment_revision,
    )
end

"""Replace only the execution-plan schema in a freshly prepared simulation."""
function _simulation_with_execution_plan(simulation::Simulation, plan::CompiledExecutionPlan)
    return Simulation(
        simulation.model,
        simulation.compiled,
        simulation.environment_bindings,
        plan,
        simulation.output_retention,
        simulation.temporal_streams,
        simulation.output_datetimes,
        simulation.output_requests,
        simulation.output_request_matchers,
        simulation.output_request_targets,
        simulation.output_request_model_revision,
        simulation.runtime_revision,
        simulation.current_step,
        simulation.constants,
        simulation.performance,
    )
end

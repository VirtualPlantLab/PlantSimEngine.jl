module ClosedGroupLayoutPreflightTests
using PlantSimEngine, Test
const PSE = PlantSimEngine
@process "closed_layout_count" verbose=false
struct Count{T} <: AbstractClosed_Layout_CountModel
    increment::T
end
PSE.inputs_(::Count) = NamedTuple()
PSE.outputs_(model::Count) = (count=zero(model.increment),)
PSE.run!(model::Count,status,environment,constants,context) = (status.count += model.increment; nothing)

function fixture()
    model = CompositeModel(Object(:a;scale=:A,status=Status(count=0f0)),
        Object(:b;scale=:B,status=Status(count=0.0)),
        Object(:c;scale=:C,status=Status(count=0f0)); applications=(
            ModelSpec(Count(1f0);name=:a,on=Many(scale=:A)),
            ModelSpec(Count(1.0);name=:b,on=Many(scale=:B)),
            ModelSpec(Count(1f0);name=:c,on=Many(scale=:C))))
    simulation = run!(model;steps=0,outputs=:none)
    plan = simulation.execution_plan
    closed = PSE.CompiledExecutionPlan(plan.cohorts,plan.topology,Tuple(plan.groups),
        plan.batches,Tuple(plan.groups_by_application_slot),plan.schedule,
        plan.model_revision,plan.environment_revision)
    return simulation,closed
end

# Host-only metadata projection uses the canonical scheduler definition and the
# genuine application plans. Scientific objects, statuses and refs are shared.
function with_order(compiled,order)
    order = Tuple(order) # canonical D application-order representation
    scenario = compiled.scenario_plan
    definition = PSE._compiled_application_schedule(compiled.applications_by_id,
        order,scenario.manual_application_ids)
    plans = Tuple(compiled.applications_by_id[id].plan for id in order)
    fields = ntuple(fieldcount(typeof(scenario))) do index
        name = fieldname(typeof(scenario),index)
        name === :application_schedule && return definition
        name === :application_order && return order
        name === :ordered_application_plans && return plans
        return getfield(scenario,index)
    end
    current_scenario = PSE.CompiledScenarioPlan(fields...)
    fields = ntuple(fieldcount(typeof(compiled))) do index
        name = fieldname(typeof(compiled),index)
        name === :scenario_plan && return current_scenario
        name === :application_order && return order
        name === :ordered_applications && return Tuple(compiled.applications_by_id[id] for id in order)
        return getfield(compiled,index)
    end
    return PSE.CompiledCompositeModel(fields...)
end

function membership_snapshot(plan)
    return [(membership=group.membership,ids=copy(group.membership.object_ids),
        locations=copy(group.membership.locations),
        runs=copy(group.membership.runs),
        indices=[copy(run.indices) for run in group.membership.runs],
        refs=[PSE.refvalue(target.status_view.status,:count)
            for run in group.membership.runs for target in run]) for group in plan.groups]
end

@testset "known incompatible closed layout rejects before a newborn changes live rows" begin
    simulation,previous = fixture()
    before = membership_snapshot(previous)
    locations = copy(previous.cohorts.locations)
    newborn = register_object!(simulation.model,
        Object(:newborn;scale=:A,status=Status(count=7f0)))
    current = PSE.Advanced.refresh_bindings!(simulation.model)
    incompatible = with_order(current,[:a,:c,:b])
    @test_throws "prepared tuple schema" PSE._refresh_model_execution_plan(previous,
        incompatible,simulation.environment_bindings,simulation.temporal_streams,
        simulation.output_retention,simulation.constants)
    @test previous.cohorts.locations == locations
    @test newborn.status.count == 7f0
    for (group,snapshot) in zip(previous.groups,before)
        @test group.membership === snapshot.membership
        @test group.membership.object_ids == snapshot.ids
        @test group.membership.locations == snapshot.locations
        @test group.membership.runs == snapshot.runs
        @test [run.indices for run in group.membership.runs] == snapshot.indices
        current_refs = [PSE.refvalue(target.status_view.status,:count)
            for run in group.membership.runs for target in run]
        @test length(current_refs) == length(snapshot.refs)
        @test all(first === second for (first,second) in zip(current_refs,snapshot.refs))
    end
    # A compatible CURRENT A/B/A permutation is admitted and keeps that order.
    compatible = with_order(current,[:c,:b,:a])
    environment = PSE.Advanced.refresh_environment_bindings!(simulation.model,current)
    result = PSE._refresh_model_execution_plan(previous,compatible,
        environment,simulation.temporal_streams,
        simulation.output_retention,simulation.constants)
    @test [group.application.id for group in result.plan.groups] == [:c,:b,:a]
    @test only(group for group in result.plan.groups if group.application.id === :a).membership.object_ids ==
        [ObjectId(:a),ObjectId(:newborn)]
end
end

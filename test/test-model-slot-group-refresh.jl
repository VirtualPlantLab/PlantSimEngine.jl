module SlotGroupRefreshChecks

using PlantSimEngine, Test
const PSE = PlantSimEngine

PSE.@process "slot_group_counter" verbose=false
struct SlotCounter{T} <: AbstractSlot_Group_CounterModel
    increment::T
end
PSE.inputs_(::SlotCounter) = NamedTuple()
PSE.outputs_(model::SlotCounter) = (count=zero(model.increment),)
function PSE.run!(model::SlotCounter, status, environment, constants, context)
    status.count += model.increment
    return nothing
end

function six_group_simulation()
    increments = (1.0f0, 1.0, Int8(1), Int16(1), Int32(1), Int64(1))
    ids = (:first, :second, :third, :fourth, :fifth, :sixth)
    applications = ntuple(6) do index
        ModelSpec(SlotCounter(increments[index]); name=ids[index], on=One(id=ids[index]))
    end
    objects = ntuple(index -> Object(ids[index];
        status=Status(count=zero(increments[index]))), 6)
    return run!(CompositeModel(objects...; applications); steps=0, outputs=:none)
end

@testset "runtime slot dispatch stays inside six concrete group schemas" begin
    simulation = six_group_simulation()
    previous = simulation.execution_plan
    groups = Tuple(previous.groups)
    slots = Tuple(previous.groups_by_application_slot)
    @test length(groups) == length(slots) == 6
    @test length(unique(typeof.(groups))) == 6
    runtime_slot = parse(Int, "6")
    @test (@inferred PSE._with_metadata_entry(group -> group.application.id,
        slots, runtime_slot)) === :sixth
    @test PSE._with_metadata_entry(group -> group.application.id,
        previous.groups_by_application_slot, runtime_slot) === :sixth
    @test_throws BoundsError PSE._with_metadata_entry(identity, slots, 0)
    @test_throws BoundsError PSE._with_metadata_entry(identity, slots, 7)
    @test_throws BoundsError PSE._with_metadata_entry(identity,
        previous.groups_by_application_slot, 7)
    @test all(group -> model_status(simulation.model,
        only(group.membership.object_ids)).count == 0, groups)

    closed = PSE.CompiledExecutionPlan(previous.cohorts, previous.topology,
        groups, previous.batches, slots, previous.schedule,
        previous.model_revision, previous.environment_revision)
    simulation = PSE._simulation_with_execution_plan(simulation, closed)
    step!(simulation)
    @test current_step(simulation) == 1
    @test all(group -> model_status(simulation.model,
        only(group.membership.object_ids)).count == 1, groups)
    @test simulation.execution_plan.groups === groups
    @test simulation.execution_plan.groups_by_application_slot === slots
end

@testset "previous group matching preserves owner identity after slot changes" begin
    simulation = six_group_simulation()
    first_group, second_group = simulation.execution_plan.groups[1:2]
    reordered = (second_group, nothing, first_group)
    visited = falses(3)
    counts = PSE._with_previous_execution_group(reordered,
        first_group.application.id, 1, visited) do group
        @test group === first_group
        return (2, 3, 1)
    end
    @test counts === (2, 3, 1)
    @test visited == Bool[false, false, true]
    preferred_counts = PSE._with_previous_execution_group(reordered,
        second_group.application.id, 1, visited) do group
        @test group === second_group
        return (0, 0, 1)
    end
    @test preferred_counts === (0, 0, 1)
    @test visited == Bool[true, false, true]

    missing_visited = falses(3)
    missing_counts = PSE._with_previous_execution_group(reordered,
        :missing, 9, missing_visited) do group
        @test isnothing(group)
        return (0, 0, 0)
    end
    @test missing_counts === (0, 0, 0)
    @test !any(missing_visited)
    @test all(group -> model_status(simulation.model,
        only(group.membership.object_ids)).count == 0,
        simulation.execution_plan.groups)
end

end

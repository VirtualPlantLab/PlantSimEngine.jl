module ExecutionTargetIdentityChecks

using Dates, Test, PlantSimEngine
const PSE = PlantSimEngine

PSE.@process "execution_identity_scan" verbose=false
struct IdentityScanModel <: AbstractExecution_Identity_ScanModel end
PSE.inputs_(::IdentityScanModel) = NamedTuple()
PSE.outputs_(::IdentityScanModel) = (visits=0,)
PSE.run!(::IdentityScanModel, status, environment, constants, context) =
    (status.visits += 1; nothing)

struct IdentityScanTargets{T,V<:AbstractVector{T},I} <: AbstractVector{T}
    rows::V
    ids::I
    retired::Set{PSE.ObjectId}
    materialized::Vector{PSE.ObjectId}
end
Base.size(targets::IdentityScanTargets) = size(targets.rows)
Base.IndexStyle(::Type{<:IdentityScanTargets}) = IndexLinear()
function Base.getindex(targets::IdentityScanTargets, index::Int)
    id = targets.ids[index]
    id in targets.retired && error("A retired execution snapshot was materialized")
    push!(targets.materialized, id)
    return targets.rows[index]
end
PSE._model_execution_target_id(targets::IdentityScanTargets, index) = targets.ids[index]

struct IdentityScanBatches <: AbstractVector{PSE.AbstractExecutionBatch}
    batches::Vector{PSE.AbstractExecutionBatch}
end
Base.size(batches::IdentityScanBatches) = size(batches.batches)
Base.IndexStyle(::Type{IdentityScanBatches}) = IndexLinear()
Base.getindex(batches::IdentityScanBatches, index::Int) = batches.batches[index]

# This test container behaves like a compact executor: changed groups require
# the generic rebuild, not mutations of its lazily inspected old row vector.
function PSE._model_execution_group_reusable(
    group::PSE.CompiledApplicationExecutionGroup{A,IdentityScanBatches},
    compiled::PSE.CompiledCompositeModel, environment::PSE.CompiledEnvironmentBindings,
    application::PSE.CompiledModelApplication, output_retention=nothing,
    temporal_streams=nothing,
) where {A}
    return false
end
function PSE._refresh_model_execution_group_delta!(
    group::PSE.CompiledApplicationExecutionGroup{A,IdentityScanBatches},
    compiled::PSE.CompiledCompositeModel, environment::PSE.CompiledEnvironmentBindings,
    application::PSE.CompiledModelApplication, streams, retention, constants,
    performance, changed_ids, shared_cache=nothing,
) where {A}
    return nothing
end

function fixture()
    return CompositeModel((Object(id; kind=:scan_unit) for id in 1:4)...;
        applications=(ModelSpec(IdentityScanModel(); name=:scan,
            on=Many(kind=:scan_unit), every=Hour(1)),),
        environment=(duration=Hour(1),))
end

function install_identity_scan!(simulation)
    previous = simulation.execution_plan
    original_group = only(previous.groups)
    original_batch = only(original_group.batches)
    rows = original_batch.targets
    targets = IdentityScanTargets(rows, [row.object_id for row in rows],
        Set{PSE.ObjectId}(), PSE.ObjectId[])
    batch = PSE.CompiledExecutionBatch(original_batch.application, targets,
        original_batch.environment_provider, original_batch.output_publication)
    group = PSE.CompiledApplicationExecutionGroup(original_group.application,
        IdentityScanBatches(PSE.AbstractExecutionBatch[batch]))
    groups = PSE.CompiledApplicationExecutionGroup[group]
    simulation.execution_plan = PSE.CompiledExecutionPlan(groups,
        PSE.AbstractExecutionBatch[batch],
        PSE._execution_groups_by_application_slot(groups, 1), previous.schedule,
        previous.model_revision, previous.environment_revision, previous.shared_target_plans)
    return targets
end

@testset "Cold refresh inspects identity before execution snapshots" begin
    ordinary = [(object_id=ObjectId(id),) for id in (1, 3, 4)]
    @test PSE._model_execution_target_id(ordinary, 2) == ObjectId(3)
    @test PSE._sorted_execution_target_position(ordinary, ObjectId(3)) == (true, 2)
    @test PSE._sorted_execution_target_position(ordinary, ObjectId(2)) == (false, 2)

    for mode in (:public_continuation, :full_general_refresh)
        simulation = run!(fixture(); steps=0, outputs=:all)
        reference = run!(fixture(); steps=0, outputs=:all)
        targets = install_identity_scan!(simulation)
        @test PSE._sorted_execution_target_position(targets, ObjectId(3)) == (true, 3)
        @test PSE._sorted_execution_target_position(targets, ObjectId(9)) == (false, 5)
        @test isempty(targets.materialized)
        continue!(simulation; steps=1)
        continue!(reference; steps=1)
        empty!(targets.materialized)
        push!(targets.retired, ObjectId(2))
        remove_object!(simulation.model, 2)
        remove_object!(reference.model, 2)
        if mode === :public_continuation
            continue!(simulation; steps=1)
            continue!(reference; steps=1)
            @test all(final_state(simulation, id) == final_state(reference, id)
                for id in (1, 3, 4))
            @test Dict(key => collect(stream) for (key, stream) in pairs(outputs(simulation))) ==
                Dict(key => collect(stream) for (key, stream) in pairs(outputs(reference)))
        else
            # A full refresh has no changed-application shortcut. It must also
            # skip retired identities before requesting rich old snapshots.
            compiled = PSE.refresh_bindings!(simulation.model)
            environment = PSE.refresh_environment_bindings!(simulation.model, compiled)
            refreshed = PSE._refresh_model_execution_plan(simulation.execution_plan,
                compiled, environment, simulation.temporal_streams,
                simulation.output_retention, simulation.constants)
            @test [target.object_id for batch in refreshed.plan.batches
                for target in batch.targets] == ObjectId.([1, 3, 4])
        end
        @test !(ObjectId(2) in targets.materialized)
        @test ObjectId(3) in targets.materialized
    end
end

end

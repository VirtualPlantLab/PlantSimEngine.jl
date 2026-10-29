module CallTargetCardinalityChecks

using Dates, PlantSimEngine, Test
const PSE = PlantSimEngine

PSE.@process "cardinality_owner_probe" verbose=false
PSE.@process "cardinality_leaf_probe" verbose=false

struct Owner{C} <: AbstractCardinality_Owner_ProbeModel
    capture::C
end
PSE.inputs_(::Owner) = NamedTuple()
PSE.outputs_(::Owner) = (visits=0,)
function PSE.run!(model::Owner, status, environment, constants, context)
    model.capture[] = context
    status.visits += 1
    return nothing
end

struct Leaf{T} <: AbstractCardinality_Leaf_ProbeModel
    increment::T
end
PSE.inputs_(::Leaf) = NamedTuple()
PSE.outputs_(model::Leaf) = (value=zero(model.increment), calls=0)
function PSE.run!(model::Leaf, status, environment, constants, context)
    status.value += model.increment
    status.calls += 1
    return nothing
end

target_length(targets::T) where {T} = length(targets)
function length_allocations(targets::T) where {T}
    target_length(targets)
    return @allocated target_length(targets)
end

@testset "call target counts preserve lazy, filtered and singular views" begin
    capture = Ref{Any}()
    model = CompositeModel(
        Object(:owner; scale=:Scene),
        Object(:a1; scale=:Leaf, kind=:a, parent=:owner),
        Object(:a2; scale=:Leaf, kind=:a, parent=:owner),
        Object(:b1; scale=:Leaf, kind=:b, parent=:owner),
        Object(:b2; scale=:Leaf, kind=:b, parent=:owner),
        Object(:b3; scale=:Leaf, kind=:b, parent=:owner);
        applications=(
            ModelSpec(Owner(capture); name=:owner, on=One(id=:owner), calls=(
                all=Many(scale=:Leaf, within=SceneScope(), process=:cardinality_leaf_probe),
                empty=Many(id=:missing, within=SceneScope(), application=:leaves_a),
                one=One(id=:a1, within=SceneScope(), application=:leaves_a),
                optional_present=OptionalOne(id=:a1, within=SceneScope(), application=:leaves_a),
                optional_absent=OptionalOne(id=:missing, within=SceneScope(), application=:leaves_a),
            )),
            ModelSpec(Leaf(Float32(1)); name=:leaves_a, on=Many(kind=:a)),
            ModelSpec(Leaf(2.0); name=:leaves_b, on=Many(kind=:b)),
        ),
        environment=(duration=Hour(1),),
    )
    run!(model; outputs=:none)
    context = capture[]
    all_targets = call_targets(context, :all)
    @test all_targets.execution_batches isa PSE.LazyCallExecutionBatches
    @test all_targets.execution_batches.target_count == 0
    @test !PSE._call_execution_batches_materialized(all_targets)

    selected = call_targets(context, :all; objects=(:a1, :b1, :b2))
    @test !selected.execution_batches.tracks_full_membership
    @test !PSE._call_execution_batches_materialized(selected)
    @test length(selected) == 3
    @test selected.execution_batches.target_count == 3
    @test length(selected.execution_batches) == 2
    @test !PSE._call_execution_batches_materialized(all_targets)
    @test run_call!(context, :all; objects=(:a1, :b1, :b2)) isa PSE.CallTargets
    @test model_status(model, :a1).calls == 1
    @test model_status(model, :a2).calls == 0
    @test model_status(model, :b3).calls == 0

    # Batch count and target count differ, including heterogeneous model/status
    # types. Repeated length queries reuse the same current materialization.
    @test length(all_targets) == 5
    @test all_targets.execution_batches.target_count == 5
    @test length(all_targets.execution_batches) == 2
    batches = PSE._cached_call_execution_batches(all_targets)
    @test typeof(first(batches).targets) !== typeof(last(batches).targets)
    @test length(all_targets) == length(collect(all_targets)) == 5
    @test PSE._cached_call_execution_batches(all_targets) === batches
    @test run_call!(context, :all) === all_targets
    @test length(all_targets) == 5
    @test model_status(model, :a2).calls == 1
    @test model_status(model, :b3).calls == 1

    empty_targets = call_targets(context, :empty)
    @test !PSE._call_execution_batches_materialized(empty_targets)
    @test empty_targets.execution_batches.target_count == 0
    @test length(empty_targets) == 0
    @test isempty(empty_targets)
    @test PSE._call_execution_batches_materialized(empty_targets)
    @test empty_targets.execution_batches.target_count == 0
    @test length(empty_targets.execution_batches) == 0
    @test length(collect(empty_targets)) == 0

    for (name, expected) in ((:one, 1), (:optional_present, 1), (:optional_absent, 0))
        targets = call_targets(context, name)
        @test targets.execution_batches isa Tuple
        @test (@inferred target_length(targets)) == expected
        @test length_allocations(targets) == 0
    end

    # An explicit newborn selection can materialize against pending pure
    # additions while the retained complete view still uses the safe barrier.
    newborn = register_object!(model, Object(:a3; scale=:Leaf, kind=:a, parent=:owner))
    newborn_targets = call_targets(context, :all; objects=newborn)
    @test length(newborn_targets) == 1
    @test only(newborn_targets).object_id == ObjectId(:a3)
    @test length(all_targets) == 5
    run_call!(context, :all; objects=newborn)
    @test model_status(model, :a3).calls == 1
end

end # module

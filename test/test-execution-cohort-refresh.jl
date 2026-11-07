using PlantSimEngine
using Test

mutable struct ExecutionRefreshTestTarget{I,S,C}
    object_id::I
    status::S
    context::C
end

execution_refresh_test_target(id, value) =
    ExecutionRefreshTestTarget(ObjectId(id), Status(value=value), Ref(0))
execution_refresh_test_ids(ids) = ObjectId[ObjectId(id) for id in ids]
execution_refresh_test_targets(membership) =
    [target for rows in membership.runs for target in rows]

@testset "Cohort refresh constructs only changed payloads in canonical order" begin
    store = PlantSimEngine.ExecutionCohortStore()
    first = execution_refresh_test_target(1, 1.0)
    middle = execution_refresh_test_target(2, 2.0f0)
    last = execution_refresh_test_target(3, 3.0)
    targets = Dict{ObjectId,Any}(target.object_id => target for target in (first, middle, last))
    checked = ObjectId[]
    build_target = (object_id, previous) -> begin
        push!(checked, object_id)
        targets[object_id]
    end
    initial = PlantSimEngine.refresh_cohort_membership!(
        build_target, store, :growth, execution_refresh_test_ids(1:3), nothing,
    )
    membership = initial.membership
    @test initial.targets_constructed == 3
    @test initial.targets_reused == initial.targets_removed == 0
    @test initial.membership_changed
    @test checked == execution_refresh_test_ids(1:3)
    @test length(membership.runs) == 3
    @test membership.runs[1].cohort === membership.runs[3].cohort
    @test membership.runs[1].cohort !== membership.runs[2].cohort
    @test all(rows -> isconcretetype(eltype(rows)), membership.runs)
    @test all(rows -> rows.store === store, membership.runs)
    @test execution_refresh_test_targets(membership) == [first, middle, last]
    first_location = PlantSimEngine.cohort_location(store, :growth, first.object_id)
    last_location = PlantSimEngine.cohort_location(store, :growth, last.object_id)
    last_context = last.context
    last_ref = PlantSimEngine.refvalue(last.status, :value)
    original_ids = membership.object_ids
    original_locations = membership.locations
    original_runs = copy(membership.runs)
    original_starts = membership.run_starts

    earlier = execution_refresh_test_target(0, 0.0)
    later = execution_refresh_test_target(4, 4.0f0)
    targets[earlier.object_id] = earlier
    targets[later.object_id] = later
    empty!(checked)
    added = PlantSimEngine.refresh_cohort_membership!(
        build_target, store, :growth, execution_refresh_test_ids(0:4),
        execution_refresh_test_ids((0, 4)); previous=membership,
    )
    @test checked == execution_refresh_test_ids((0, 4))
    @test added.targets_constructed == 2
    @test added.targets_reused == 3
    @test added.targets_removed == 0
    @test added.membership_changed
    @test added.membership === membership
    @test membership.object_ids === original_ids
    @test membership.locations === original_locations
    @test membership.run_starts === original_starts
    @test all(index -> membership.runs[index] === original_runs[index], 1:3)
    @test membership.run_starts == [1, 3, 4, 5]
    @test getproperty.(execution_refresh_test_targets(added.membership), :object_id) ==
          execution_refresh_test_ids(0:4)
    @test execution_refresh_test_targets(added.membership)[2] === first
    @test execution_refresh_test_targets(added.membership)[4] === last
    @test PlantSimEngine.cohort_location(store, :growth, first.object_id) === first_location
    @test PlantSimEngine.cohort_location(store, :growth, last.object_id) === last_location
    @test last.context === last_context
    @test PlantSimEngine.refvalue(last.status, :value) === last_ref

    replacement = execution_refresh_test_target(1, 10.0)
    targets[first.object_id] = replacement
    empty!(checked)
    replaced = PlantSimEngine.refresh_cohort_membership!(
        build_target, store, :growth, execution_refresh_test_ids(0:4),
        execution_refresh_test_ids((1,)); previous=added.membership,
    )
    @test checked == execution_refresh_test_ids((1,))
    @test replaced.targets_constructed == 1
    @test replaced.targets_reused == 4
    @test !replaced.membership_changed
    @test replaced.membership === added.membership
    @test execution_refresh_test_targets(replaced.membership)[2] === replacement
    @test PlantSimEngine.cohort_location(store, :growth, first.object_id) === first_location
    @test execution_refresh_test_targets(replaced.membership)[4] === last

    empty!(checked)
    unchanged = PlantSimEngine.refresh_cohort_membership!(
        build_target, store, :growth, execution_refresh_test_ids(0:4),
        ObjectId[]; previous=replaced.membership,
    )
    @test isempty(checked)
    @test unchanged.membership === replaced.membership
    @test unchanged.targets_constructed == 0
    @test unchanged.targets_reused == 5

    empty!(checked)
    validated = PlantSimEngine.refresh_cohort_membership!(
        build_target, store, :growth, execution_refresh_test_ids(0:4),
        nothing; previous=unchanged.membership,
    )
    @test checked == execution_refresh_test_ids(0:4)
    @test validated.membership === unchanged.membership
    @test validated.targets_constructed == 0
    @test validated.targets_reused == 5
end

@testset "Schema extension, removal and empty groups use the same refresh" begin
    store = PlantSimEngine.ExecutionCohortStore()
    first = execution_refresh_test_target(1, 1.0)
    last = execution_refresh_test_target(3, 3.0)
    targets = Dict{ObjectId,Any}(target.object_id => target for target in (first, last))
    checked = ObjectId[]
    build_target = (object_id, previous) -> begin
        push!(checked, object_id)
        targets[object_id]
    end
    initial = PlantSimEngine.refresh_cohort_membership!(
        build_target, store, :growth, execution_refresh_test_ids((1, 3)), nothing,
    ).membership
    first_location = PlantSimEngine.cohort_location(store, :growth, first.object_id)
    last_location = PlantSimEngine.cohort_location(store, :growth, last.object_id)
    changed = ExecutionRefreshTestTarget(ObjectId(1), Status(value=2.0f0, extra=7), Ref(0))
    targets[changed.object_id] = changed
    empty!(checked)
    extended = PlantSimEngine.refresh_cohort_membership!(
        build_target, store, :growth, execution_refresh_test_ids((1, 3)),
        execution_refresh_test_ids((1,)); previous=initial,
    )
    @test checked == execution_refresh_test_ids((1,))
    @test extended.membership_changed
    @test extended.targets_constructed == 1
    @test length(store.cohorts) == 2
    @test execution_refresh_test_targets(extended.membership)[1] === changed
    @test execution_refresh_test_targets(extended.membership)[2] === last
    @test isnothing(first_location.cohort.rows[first_location.row])
    @test PlantSimEngine.cohort_location(store, :growth, last.object_id) === last_location

    empty!(checked)
    removed = PlantSimEngine.refresh_cohort_membership!(
        build_target, store, :growth, execution_refresh_test_ids((3,)),
        execution_refresh_test_ids((1,)); previous=extended.membership,
    )
    @test isempty(checked)
    @test removed.targets_constructed == 0
    @test removed.targets_removed == 1
    @test execution_refresh_test_targets(removed.membership) == [last]
    @test isnothing(PlantSimEngine.cohort_location(store, :growth, ObjectId(1)))
    @test PlantSimEngine.cohort_location(store, :growth, last.object_id) === last_location

    empty_group = PlantSimEngine.refresh_cohort_membership!(
        build_target, store, :growth, ObjectId[], execution_refresh_test_ids((3,));
        previous=removed.membership,
    )
    @test isempty(empty_group.membership.runs)
    @test empty_group.targets_removed == 1
    @test isempty(store.locations)
    targets[first.object_id] = first
    reborn = PlantSimEngine.refresh_cohort_membership!(
        build_target, store, :growth, execution_refresh_test_ids((1,)),
        execution_refresh_test_ids((1,)); previous=empty_group.membership,
    )
    @test execution_refresh_test_targets(reborn.membership) == [first]
    @test PlantSimEngine.cohort_location(store, :growth, first.object_id) === first_location
end

@testset "Refresh stages failing construction and isolates execution owners" begin
    store = PlantSimEngine.ExecutionCohortStore()
    first = execution_refresh_test_target(1, 1.0)
    root = PlantSimEngine.refresh_cohort_membership!(
        (id, previous) -> first, store, :growth, execution_refresh_test_ids((1,)), nothing,
    ).membership
    owner = (:controller, ObjectId(:plant), :growth_call, :manual)
    called = execution_refresh_test_target(1, 1.0)
    call = PlantSimEngine.refresh_cohort_membership!(
        (id, previous) -> called, store, :growth, execution_refresh_test_ids((1,)), nothing;
        owner,
    ).membership
    @test root.runs[1].store === call.runs[1].store
    @test root.runs[1].cohort !== call.runs[1].cohort
    @test root.runs[1][1] === first
    @test call.runs[1][1] === called
    old_location = PlantSimEngine.cohort_location(store, :growth, ObjectId(1))
    changed = execution_refresh_test_target(1, 1.0f0)
    @test_throws ErrorException PlantSimEngine.refresh_cohort_membership!(
        (id, previous) -> id == ObjectId(1) ? changed : error("construction fails"),
        store, :growth, execution_refresh_test_ids((1, 2)),
        execution_refresh_test_ids((1, 2)); previous=root,
    )
    @test PlantSimEngine.cohort_location(store, :growth, ObjectId(1)) === old_location
    @test root.runs[1][1] === first
    @test call.runs[1][1] === called
    @test length(store.cohorts) == 2
    @test_throws ArgumentError PlantSimEngine.refresh_cohort_membership!(
        (id, previous) -> first, store, :growth, execution_refresh_test_ids((1,)),
        ObjectId[]; previous=root, owner,
    )
    @test_throws ArgumentError PlantSimEngine.refresh_cohort_membership!(
        (id, previous) -> execution_refresh_test_target(99, 1.0),
        store, :growth, execution_refresh_test_ids((1,)), nothing; previous=root,
    )
    @test root.runs[1][1] === first
end

@testset "Membership merges distinguish identities with equal display strings" begin
    store = PlantSimEngine.ExecutionCohortStore()
    numeric = execution_refresh_test_target(1, 1.0)
    symbolic = execution_refresh_test_target(Symbol("1"), 2.0)
    targets = Dict{ObjectId,Any}(target.object_id => target for target in (numeric, symbolic))
    builder = (id, previous) -> targets[id]
    initial = PlantSimEngine.refresh_cohort_membership!(
        builder, store, :growth, ObjectId[numeric.object_id], nothing,
    ).membership
    mixed_ids = ObjectId[numeric.object_id, symbolic.object_id]
    PlantSimEngine._sort_object_ids!(mixed_ids)
    added = PlantSimEngine.refresh_cohort_membership!(
        builder, store, :growth, mixed_ids, ObjectId[symbolic.object_id]; previous=initial,
    )
    @test getproperty.(execution_refresh_test_targets(added.membership), :object_id) == mixed_ids
    @test added.targets_constructed == 1
    @test length(added.membership.runs) == 2
    @test added.membership.runs[1][1] === numeric
    @test added.membership.runs[2][1] === symbolic
    replacement = execution_refresh_test_target(2, 3.0)
    targets[replacement.object_id] = replacement
    new_ids = ObjectId[replacement.object_id, symbolic.object_id]
    PlantSimEngine._sort_object_ids!(new_ids)
    changed_ids = ObjectId[numeric.object_id, replacement.object_id]
    PlantSimEngine._sort_object_ids!(changed_ids)
    changed = PlantSimEngine.refresh_cohort_membership!(
        builder, store, :growth, new_ids, changed_ids; previous=added.membership,
    )
    @test changed.targets_constructed == 1
    @test changed.targets_removed == 1
    @test getproperty.(execution_refresh_test_targets(changed.membership), :object_id) == new_ids
    @test isnothing(PlantSimEngine.cohort_location(store, :growth, numeric.object_id))
    @test changed.membership.runs[2][1] === symbolic
end

@testset "In-place run splices preserve recurring families and unaffected views" begin
    store = PlantSimEngine.ExecutionCohortStore()
    targets = Dict{ObjectId,Any}(
        ObjectId(id) => execution_refresh_test_target(id, Float64(id)) for id in (1, 3, 5)
    )
    builder = (id, previous) -> targets[id]
    membership = PlantSimEngine.refresh_cohort_membership!(
        builder, store, :growth, execution_refresh_test_ids((1, 3, 5)), nothing,
    ).membership
    original_run = only(membership.runs)
    original_indices = original_run.indices
    original_locations = copy(membership.locations)
    targets[ObjectId(3)] = execution_refresh_test_target(3, 3.0f0)
    split = PlantSimEngine.refresh_cohort_membership!(
        builder, store, :growth, execution_refresh_test_ids((1, 3, 5)),
        execution_refresh_test_ids((3,)); previous=membership,
    )
    @test split.membership === membership
    @test membership.run_starts == [1, 2, 3]
    @test length(membership.runs) == 3
    @test membership.runs[1] === original_run
    @test membership.runs[1].indices === original_indices
    @test membership.runs[1].cohort === membership.runs[3].cohort
    @test membership.locations[1] === original_locations[1]
    @test membership.locations[3] === original_locations[3]
    @test getproperty.(execution_refresh_test_targets(membership), :object_id) ==
          execution_refresh_test_ids((1, 3, 5))
    right_run = membership.runs[3]

    # A new leading occurrence cannot consume the existing later view.
    targets[ObjectId(0)] = execution_refresh_test_target(0, 0.0f0)
    leading = PlantSimEngine.refresh_cohort_membership!(
        builder, store, :growth, execution_refresh_test_ids((0, 1, 3, 5)),
        execution_refresh_test_ids((0,)); previous=membership,
    )
    @test membership.run_starts == [1, 2, 3, 4]
    @test membership.runs[2] === original_run
    @test membership.runs[4] === right_run
    @test getproperty.(execution_refresh_test_targets(leading.membership), :object_id) ==
          execution_refresh_test_ids((0, 1, 3, 5))

    targets[ObjectId(3)] = execution_refresh_test_target(3, 3.0)
    restored = PlantSimEngine.refresh_cohort_membership!(
        builder, store, :growth, execution_refresh_test_ids((0, 1, 3, 5)),
        execution_refresh_test_ids((3,)); previous=membership,
    )
    @test restored.membership === membership
    @test membership.run_starts == [1, 2]
    @test membership.runs[2] === original_run
    @test getproperty.(membership.runs[2], :object_id) == execution_refresh_test_ids((1, 3, 5))
    @test only(right_run).object_id == ObjectId(5)

    removed = PlantSimEngine.refresh_cohort_membership!(
        builder, store, :growth, execution_refresh_test_ids((1, 5)),
        execution_refresh_test_ids((0, 3)); previous=membership,
    )
    @test removed.targets_removed == 2
    @test membership.run_starts == [1]
    @test only(membership.runs) === original_run
    @test getproperty.(execution_refresh_test_targets(membership), :object_id) ==
          execution_refresh_test_ids((1, 5))
end

function execution_refresh_append_allocations(count)
    store = PlantSimEngine.ExecutionCohortStore()
    builder = (id, previous) -> execution_refresh_test_target(id.value, Float64(id.value))
    ids = execution_refresh_test_ids(1:count)
    membership = PlantSimEngine.refresh_cohort_membership!(
        builder, store, :growth, ids, nothing,
    ).membership
    push!(ids, ObjectId(count + 1))
    changed = ObjectId[ObjectId(count + 1)]
    return @allocated PlantSimEngine.refresh_cohort_membership!(
        builder, store, :growth, ids, changed; previous=membership,
    )
end

@testset "Appending a row does not copy live membership arrays" begin
    execution_refresh_append_allocations(8)
    small = minimum(execution_refresh_append_allocations(8) for _ in 1:2)
    large = minimum(execution_refresh_append_allocations(4096) for _ in 1:2)
    @test large <= small + 4096
end

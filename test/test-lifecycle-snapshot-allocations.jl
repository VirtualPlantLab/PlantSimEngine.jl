function _lifecycle_reference_append(parent_ancestors, object_id)
    ancestors = copy(parent_ancestors)
    push!(ancestors, object_id)
    return ancestors
end

function _lifecycle_append_allocations(append_path, ancestors, object_id)
    append_path(ancestors, object_id)
    return @allocated append_path(ancestors, object_id)
end

# Retain the former expression as the allocation control, independently of the
# production snapshot constructor's geometry dispatch barrier.
function _lifecycle_reference_snapshot(model, object)
    ancestors = get(model.registry.ancestor_ids_by_object, object.id, ())
    return PlantSimEngine.LifecycleObjectSnapshot(
        object.id,
        object.scale,
        object.kind,
        object.species,
        object.name,
        object.parent,
        Tuple(object.children),
        Tuple(ancestors),
        object.geometry,
    )
end

function _lifecycle_fill_snapshots!(snapshots, snapshot, model, object)
    for index in eachindex(snapshots)
        snapshots[index] = snapshot(model, object)
    end
    return snapshots
end

function _lifecycle_snapshot_allocations!(snapshots, snapshot, model, object)
    _lifecycle_fill_snapshots!(snapshots, snapshot, model, object)
    return @allocated _lifecycle_fill_snapshots!(snapshots, snapshot, model, object)
end

@testset "lifecycle snapshot allocations stay within historical budget" begin
    model = CompositeModel(Object(1))
    for id in 2:16
        register_object!(model, Object(id; parent=id - 1))
    end
    leaf = model_object(model, 16)
    # Allocate result storage outside measurement and inspect it afterward so
    # every measured snapshot escapes. Both implementations are warmed first.
    actual_snapshots = Vector{PlantSimEngine.LifecycleObjectSnapshot}(undef, 128)
    previous_snapshots = similar(actual_snapshots)
    actual = _lifecycle_snapshot_allocations!(
        actual_snapshots, PlantSimEngine._lifecycle_object_snapshot, model, leaf,
    )
    previous = _lifecycle_snapshot_allocations!(
        previous_snapshots, _lifecycle_reference_snapshot, model, leaf,
    )
    @test actual <= previous
    expected_ancestors = Tuple(ObjectId.(1:16))
    @test all(snapshot -> snapshot.ancestors == expected_ancestors, actual_snapshots)
    @test all(snapshot -> snapshot.ancestors == expected_ancestors, previous_snapshots)
    @test all(snapshot -> snapshot.children === (), actual_snapshots)
    @test all(snapshot -> snapshot.children === (), previous_snapshots)
end

@testset "ancestor path append allocates its final size once" begin
    for parent_path in (
        ObjectId[],
        ObjectId[ObjectId(:root), ObjectId(7), ObjectId((:branch, 2))],
    )
        original = copy(parent_path)
        id = ObjectId(UInt64(typemax(Int)) + 1)
        path = PlantSimEngine._append_object_ancestor_id(parent_path, id)
        @test path == vcat(parent_path, [id])
        @test parent_path == original
        @test path !== parent_path
        path[end] = ObjectId(:replacement)
        @test parent_path == original
    end

    parent_path = ObjectId[ObjectId(i) for i in 1:128]
    id = ObjectId(129)
    actual = _lifecycle_append_allocations(
        PlantSimEngine._append_object_ancestor_id, parent_path, id,
    )
    previous = _lifecycle_append_allocations(
        _lifecycle_reference_append, parent_path, id,
    )
    @test actual < previous
end

@testset "lifecycle snapshots freeze topology and share geometry" begin
    geometry = Dict(:position => [1.0, 2.0])
    model = CompositeModel(Object(:root; geometry=geometry))
    root_snapshot = only(model.lifecycle_delta.added)
    source_status = Status(signal=big"1.25", payload=[1, 2])
    branch = register_object!(
        model, Object(7; parent=:root, status=source_status),
    )
    branch_snapshot = last(model.lifecycle_delta.added)
    leaf = register_object!(model, Object((:leaf, 1); parent=7))
    leaf_snapshot = last(model.lifecycle_delta.added)
    @test branch.status === source_status
    @test model_status(model, source_status) === source_status
    @test object_id(model, source_status) == ObjectId(7)
    @test root_snapshot.children === ()
    @test branch_snapshot.children === ()
    @test branch_snapshot.ancestors == (ObjectId(:root), ObjectId(7))
    @test leaf_snapshot.ancestors == (
        ObjectId(:root), ObjectId(7), ObjectId((:leaf, 1)),
    )
    @test root_snapshot.geometry === geometry
    push!(geometry[:position], 3.0)
    @test root_snapshot.geometry[:position] == [1.0, 2.0, 3.0]

    reparent_object!(model, branch.id, nothing)
    @test branch_snapshot.parent == ObjectId(:root)
    @test branch_snapshot.ancestors == (ObjectId(:root), ObjectId(7))
    @test leaf_snapshot.ancestors == (
        ObjectId(:root), ObjectId(7), ObjectId((:leaf, 1)),
    )
    @test model.registry.ancestor_ids_by_object[ObjectId(:root)] ==
          [ObjectId(:root)]
    @test model.registry.ancestor_ids_by_object[branch.id] == [ObjectId(7)]
    @test model.registry.ancestor_ids_by_object[leaf.id] ==
          [ObjectId(7), ObjectId((:leaf, 1))]

    remove_object!(model, branch.id)
    removed_branch, removed_leaf = model.lifecycle_delta.removed
    @test removed_branch.children == (ObjectId((:leaf, 1)),)
    @test removed_branch.ancestors == (ObjectId(7),)
    @test removed_leaf.ancestors == (ObjectId(7), ObjectId((:leaf, 1)))
    empty!(branch.children)
    @test removed_branch.children == (ObjectId((:leaf, 1)),)
    @test_throws ArgumentError object_id(model, source_status)
    @test PlantSimEngine._lifecycle_object_snapshot(
        model, Object(:unregistered),
    ).ancestors === ()
end

@testset "lazy addition ids populate both lifecycle dirty sets" begin
    model = CompositeModel(Object(:root))
    PlantSimEngine.Advanced.refresh_environment_bindings!(model)
    PlantSimEngine._register_objects!(model, Object[
        Object(:leaf_a; parent=:root),
        Object(2; parent=:root),
    ])
    delta = model.lifecycle_delta
    expected = Set(ObjectId.((:leaf_a, 2)))
    @test delta.structural_dirty_ids == expected
    @test delta.environment_dirty_ids == expected
    @test Set(snapshot.id for snapshot in delta.added) == expected
end

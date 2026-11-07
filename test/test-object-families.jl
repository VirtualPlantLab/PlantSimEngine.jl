module CanonicalObjectFamilyChecks

using Test
using PlantSimEngine
using MultiScaleTreeGraph

const PSE = PlantSimEngine

@testset "ordinary registry owns typed status families and exact object facades" begin
    supplied = Status(value=1f0)
    reference = PSE.refvalue(supplied, :value)
    first = Object(1; scale=:Leaf, status=supplied)
    second = Object(:leaf; scale=:Leaf, status=Status(value=2.0))
    empty = Object((:plant, 3); scale=:Leaf)
    model = CompositeModel(first, second, empty)
    store = model.registry.objects

    @test store isa PSE.ObjectFamilyStore
    @test store.catalog isa PSE.OpenObjectFamilyCatalog
    @test length(store.catalog.families) == 3
    @test model_object(model, 1) === first
    @test model_status(model, 1) === supplied
    @test PSE.refvalue(model_status(model, supplied), :value) === reference
    @test isnothing(model_status(model, (:plant, 3)))
    @test Set(keys(store)) == Set((ObjectId(1), ObjectId(:leaf), ObjectId((:plant, 3))))
    @test Set(values(store)) == Set((first, second, empty))
    @test Dict(store)[ObjectId(1)] === first
    @test copy(store)[ObjectId(:leaf)] === second
    @test get(store, ObjectId(:absent), nothing) === nothing
    @test object_id(model, supplied) === ObjectId(1)

    model_status(model, 1).value = 4f0
    @test supplied.value === first.status.value === 4f0
    location = store.locations[ObjectId(1)]
    family = store.catalog.families[location.family]
    @test family isa PSE.ObjectFamily{ObjectId{Int},typeof(supplied)}
    @test family.rows[location.row].status === supplied
end

@noinline function escape_registered_status!(sink, model, id, count)
    for _ in 1:count
        sink[] = model_status(model, id)
    end
    return nothing
end

registered_status_allocations(sink, model, id, count) =
    @allocated escape_registered_status!(sink, model, id, count)

@testset "escaping open-family lookups reuse the canonical Status box" begin
    supplied = Status(value=1f0, items=Float32[2], counter=0, label=:leaf, active=true)
    object = Object(:leaf; status=supplied)
    model = CompositeModel(object)
    sink = Ref{Any}()
    for _ in 1:2
        escape_registered_status!(sink, model, object.id, 1000)
        registered_status_allocations(sink, model, object.id, 1000)
    end
    @test registered_status_allocations(sink, model, object.id, 1) == 0
    @test registered_status_allocations(sink, model, object.id, 1000) == 0
    @test sink[] === supplied === object.status
    @test all(index -> PSE.refvalues(sink[])[index] === PSE.refvalues(supplied)[index],
              eachindex(PSE.refvalues(supplied)))
    location = model.registry.objects.locations[object.id]
    family = model.registry.objects.catalog.families[location.family]
    @test family.rows[location.row].status === sink[]
    sink[].items[1] = 3f0
    @test supplied.items === object.status.items
    @test supplied.items == Float32[3]

    replacement = Status(value=4.0, items=[5.0], counter=1, label=:updated, active=false)
    PSE._replace_model_object_status!(model, object, replacement)
    for _ in 1:2
        escape_registered_status!(sink, model, object.id, 1000)
        registered_status_allocations(sink, model, object.id, 1000)
    end
    @test registered_status_allocations(sink, model, object.id, 1000) == 0
    @test sink[] === replacement === object.status
    @test PSE.refvalue(sink[], :items) === PSE.refvalue(replacement, :items)
    @test object_id(model, replacement) === object.id
    @test_throws ArgumentError object_id(model, supplied)
    @test supplied.items == Float32[3]
end

@testset "status replacement moves family membership and exclusive ownership" begin
    original = Status(value=1f0)
    first = Object(:first; status=original)
    occupied = Status(value=9.0)
    second = Object(:second; status=occupied)
    model = CompositeModel(first, second)
    store = model.registry.objects
    previous = store.locations[first.id]
    replacement = Status(value=3.0, counter=2)

    @test PSE._replace_model_object_status!(model, first, replacement) === replacement
    current = store.locations[first.id]
    @test current.family != previous.family
    @test isnothing(store.catalog.families[previous.family].rows[previous.row])
    @test model_object(model, :first) === first
    @test first.status === model_status(model, :first) === replacement
    @test object_id(model, replacement) === first.id
    @test_throws ArgumentError object_id(model, original)
    @test original.value === 1f0

    @test_throws ArgumentError PSE._replace_model_object_status!(model, first, occupied)
    @test first.status === model_status(model, :first) === replacement
    @test model_status(model, :second) === occupied
    @test store.locations[first.id] == current
    @test_throws ArgumentError PSE._replace_model_object_status!(
        model, Object(:first; status=Status(value=0.0)), Status(value=12.0))
    @test model_object(model, :first) === first
    @test model_status(model, :first) === replacement

    @test isnothing(PSE._replace_model_object_status!(model, first, nothing))
    @test isnothing(model_status(model, :first))
    @test_throws ArgumentError object_id(model, replacement)
    @test PSE._replace_model_object_status!(model, first, original) === original
    @test object_id(model, original) === first.id
end

PSE.@process "canonical_family_increment" verbose = false
struct FamilyIncrement <: AbstractCanonical_Family_IncrementModel end
PSE.inputs_(::FamilyIncrement) = NamedTuple()
PSE.outputs_(::FamilyIncrement) = (value=0.0,)
function PSE.run!(::FamilyIncrement, status, environment, constants, context)
    status.value += one(status.value)
    return nothing
end

@testset "conversion and normal execution read canonical family state" begin
    source = Status(value=2.0)
    first = Object(:leaf; scale=:Leaf, status=source)
    model = CompositeModel(first;
        applications=(ModelSpec(FamilyIncrement(); name=:increment, on=Many(scale=:Leaf)),),
        type_promotion=Dict(Float64 => Float32))
    converted = model_status(model, :leaf)
    @test converted !== source
    @test converted.value === 2f0
    @test first.status === converted
    @test object_id(model, converted) === first.id
    @test_throws ArgumentError object_id(model, source)
    @test_throws ArgumentError register_object!(model, Object(:duplicate; status=source))

    simulation = run!(model; outputs=:all)
    @test model_status(model, :leaf) === converted
    @test converted.value === 3f0
    late_source = Status(value=4.5)
    late = Object(:late; scale=:Leaf, status=late_source)
    register_object!(model, late)
    @test late.status.value === 4.5f0
    @test model_status(model, :late) === late.status
    continue!(simulation)
    @test converted.value === 4f0
    @test model_status(model, :late).value === 5.5f0
    @test outputs(simulation)[(:increment, ObjectId(:late), :value)] == [(2.0, 5.5f0)]

    removed_status = model_status(model, :late)
    removed_location = model.registry.objects.locations[late.id]
    remove_object!(model, late.id)
    @test_throws ArgumentError object_id(model, removed_status)
    @test_throws ErrorException model_status(model, late.id)
    replacement = Object(:late; scale=:Leaf, status=Status(value=10.0))
    register_object!(model, replacement)
    @test model_object(model, :late) === replacement
    @test model_status(model, :late).value === 10f0
    @test model.registry.objects.locations[late.id].row != removed_location.row
    @test_throws ArgumentError object_id(model, late)
    continue!(simulation)
    @test model_status(model, :late).value === 11f0
    @test removed_status.value === 5.5f0
end

@testset "typed MTG identities preserve exact nodes through growth and removal" begin
    root = Node(MultiScaleTreeGraph.NodeMTG(:/, :Scene, 1, 0))
    leaf = Node(root, MultiScaleTreeGraph.NodeMTG(:+, :Leaf, 1, 1))
    model = CompositeModel(root;
        status=node -> MultiScaleTreeGraph.symbol(node) === :Leaf ? Status(value=1f0) : nothing)
    adapter = model.source_adapter
    @test keytype(adapter.object_ids_by_node) === typeof(root)
    @test valtype(adapter.nodes_by_object_id) === typeof(root)
    @test source_node(model, leaf) === leaf
    @test isnothing(model_status(model, root))
    @test_throws ArgumentError object_id(model, deepcopy(leaf))
    @test_throws ArgumentError source_node(model, deepcopy(leaf))

    born = add_organ!(root, model, :+, :Leaf, 1; initial_status=(value=7f0,))
    id = object_id(model, born)
    node = source_node(model, born)
    @test model_status(model, node) === born
    @test born.node === node
    @test source_node(model, id) === node
    @test object_id(model, node) === id
    @test born.value === 7f0

    closed_adapter = PSE._closed_mtg_object_adapter(adapter, ObjectId{Int})
    @test closed_adapter.root === root
    @test closed_adapter.status === adapter.status
    @test keytype(closed_adapter.nodes_by_object_id) === ObjectId{Int}
    @test closed_adapter.nodes_by_object_id[id] === node
    @test closed_adapter.object_ids_by_node[node] === id

    remove_object!(model, id)
    @test_throws ArgumentError object_id(model, born)
    @test_throws ArgumentError object_id(model, node)
    @test !haskey(adapter.nodes_by_object_id, id)
    @test !haskey(adapter.object_ids_by_node, node)
    MultiScaleTreeGraph.delete_node!(node)
    reused = add_organ!(root, model, :+, :Leaf, 1; id=id.value, initial_status=(value=9f0,))
    @test object_id(model, reused) === id
    @test source_node(model, reused) !== node
    @test model_status(model, id) === reused
    @test_throws ArgumentError object_id(model, node)
end

@testset "different node attribute schemas preserve one exact MTG node family" begin
    root = Node(MultiScaleTreeGraph.NodeMTG(:/, :Scene, 1, 0), (label="scene",))
    leaf = Node(root, MultiScaleTreeGraph.NodeMTG(:+, :Leaf, 1, 1),
        (area=2f0, state=:active))
    tip = Node(leaf, MultiScaleTreeGraph.NodeMTG(:+, :Tip, 1, 2),
        Dict{Symbol,Any}(:rate => 3.0, :history => Float32[1, 2]))
    model = CompositeModel(root)
    @test typeof(root) === typeof(leaf) === typeof(tip)
    @test source_node(model, object_id(model, leaf)) === leaf
    @test source_node(model, object_id(model, tip)) === tip
    @test leaf[:area] === 2f0
    @test tip[:history] == Float32[1, 2]

    grown = add_organ!(tip, model, :+, :Tip, 2; attributes=(new_field=4,))
    @test typeof(source_node(model, grown)) === typeof(root)
    @test grown.new_field === 4

    # Explicit raw construction can create a different detached node family,
    # but cannot attach it to the homogeneous children vector of this tree.
    encoding = MultiScaleTreeGraph.NodeMTG(:+, :Leaf, 1, 1)
    attrs = (foreign=true,)
    N = Node{typeof(encoding),typeof(attrs)}
    foreign = N(MultiScaleTreeGraph.node_id(leaf), nothing, N[], encoding, attrs, nothing)
    @test typeof(foreign) !== typeof(root)
    @test_throws ArgumentError object_id(model, foreign)
    @test_throws ArgumentError source_node(model, foreign)
end

@testset "deepcopy preserves private canonical family aliases" begin
    original = Status(value=1f0)
    object = Object(:leaf; status=original)
    model = CompositeModel(object)
    copied = deepcopy(model)
    copied_object = model_object(copied, :leaf)
    copied_status = model_status(copied, :leaf)
    @test copied_object !== object
    @test copied_status !== original
    @test copied_object.status === copied_status
    @test object_id(copied, copied_status) === ObjectId(:leaf)
    @test_throws ArgumentError object_id(copied, original)
    @test_throws ArgumentError object_id(model, copied_status)
    location = copied.registry.objects.locations[ObjectId(:leaf)]
    family = copied.registry.objects.catalog.families[location.family]
    @test family.rows[location.row].status === copied_status
    copied_status.value = 6f0
    @test copied_object.status.value === 6f0
    @test original.value === 1f0
end

@testset "closed family catalog keeps runtime membership and shared payloads" begin
    first_status = Status(value=1f0)
    first = Object(1; status=first_status)
    model = CompositeModel(first)
    closed = PSE._closed_object_family_store(model.registry.objects)
    @test closed.catalog isa PSE.ClosedObjectFamilyCatalog
    @test closed.catalog.families isa Tuple
    @test keytype(closed.locations) === ObjectId{Int}
    @test closed[first.id] === first
    @test (@inferred PSE._object_family_status(closed, first.id)) === first_status
    store_type = typeof(closed)

    born = Object(2; status=Status(value=2f0))
    closed[born.id] = born
    @test typeof(closed) === store_type
    @test length(closed) == 2
    @test PSE._object_family_status(closed, born.id) === born.status
    @test closed.status_owners[PSE._status_identity(born.status)] === born.id
    @test_throws ArgumentError setindex!(closed, Object(3; status=Status(value=3.0)), ObjectId(3))
    @test !haskey(closed, ObjectId(3))
    @test length(closed) == 2

    delete!(closed, born.id)
    @test length(closed) == 1
    @test !haskey(closed.status_owners, PSE._status_identity(born.status))
    replacement = Object(2; status=Status(value=8f0))
    closed[replacement.id] = replacement
    @test closed[replacement.id] === replacement
    @test PSE._object_family_status(closed, replacement.id).value === 8f0

    mixed = CompositeModel(Object(1; status=Status(value=1f0)), Object(:leaf; status=nothing))
    mixed_closed = PSE._closed_object_family_store(mixed.registry.objects)
    @test keytype(mixed_closed.locations) === Union{ObjectId{Int},ObjectId{Symbol}}
    @test PSE._object_family_status(mixed_closed, ObjectId(1)).value === 1f0
    @test isnothing(PSE._object_family_status(mixed_closed, ObjectId(:leaf)))

    historical = CompositeModel(Object(:leaf; status=Status(value=1f0)))
    PSE._replace_model_object_status!(historical, :leaf, Status(value=2.0, count=1))
    @test length(historical.registry.objects.catalog.families) == 2
    active = PSE._closed_object_family_store(historical.registry.objects)
    @test length(active.catalog.families) == 1
    @test PSE._object_family_status(active, ObjectId(:leaf)).value === 2.0
    @test_throws ArgumentError setindex!(active,
        Object(:newborn; status=Status(value=3f0)), ObjectId(:newborn))

    statuses = [Status(value=Float32(index), payload=ntuple(identity, index)) for index in 1:8]
    eight = CompositeModel((Object(index; status=status) for (index, status) in enumerate(statuses))...)
    eight_closed = PSE._closed_object_family_store(eight.registry.objects)
    allowed = Union{typeof.(statuses)...}
    inferred = Core.Compiler.return_type(PSE._object_family_status,
        Tuple{typeof(eight_closed),ObjectId{Int}})
    @test inferred === allowed
    for (index, status) in enumerate(statuses)
        @test PSE._object_family_status(eight_closed, ObjectId(index)) === status
    end
end

end

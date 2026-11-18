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
    @test store.catalog isa PSE.ClosedObjectFamilyCatalog
    @test length(store.catalog.families) == 2 # None + one prepared physical S
    canonical = model_status(model, 1)
    @test model_object(model, 1) === first
    for object in (first, second, empty)
        @test model_object(model, object.id) === object
        @test model_object(model, object.id.value) === object
    end
    for id in (17, :absent, (:plant, 4)), query in (id, ObjectId(id))
        failure = try
            model_object(model, query)
        catch exception
            exception
        end
        @test failure isa ErrorException
        expected = id isa Tuple ? "(Symbol(\"plant\"), 4)" : string(id)
        @test sprint(showerror, failure) == "No model object with id `$(expected)`."
    end
    @test canonical !== supplied
    @test PSE.refvalue(canonical, :value) === reference
    @test_throws ArgumentError model_status(model, supplied)
    @test isnothing(model_status(model, (:plant, 3)))
    @test Set(keys(store)) == Set((ObjectId(1), ObjectId(:leaf), ObjectId((:plant, 3))))
    @test Set(values(store)) == Set((first, second, empty))
    @test Dict(store)[ObjectId(1)] === first
    @test copy(store)[ObjectId(:leaf)] === second
    @test get(store, ObjectId(:absent), nothing) === nothing
    @test object_id(model, canonical) === ObjectId(1)
    @test_throws ArgumentError object_id(model, supplied)

    model_status(model, 1).value = 4f0
    @test supplied.value === first.status.value === 4f0
    location = store.locations[ObjectId(1)]
    family = store.catalog.families[location.family]
    @test family isa PSE.ObjectFamily{keytype(store),typeof(canonical)}
    @test family.rows[location.row].status === canonical
end

@testset "object lists retain textual order across identity types" begin
    raw_ids = Any[10, 2, :root, Symbol("2"), (:tree, :leaf, 2), (:tree, :leaf, 10),
        (:tree, Symbol("a b"), 1), (:tree, (:leaf, 1)), (:tree,), ()]
    model = CompositeModel((Object(id; scale=:Leaf) for id in raw_ids)...)
    ids = collect(keys(model.registry.objects))
    for id in ids
        @test PSE._object_list_sort_key(id) == string(id.value)
    end
    expected = sort(collect(model.registry.by_scale[:Leaf]); by=id -> string(id.value))
    @test object_ids(model; scale=:Leaf) == expected
    @test all(object === model_object(model, id)
        for (object, id) in zip(model_objects(model; scale=:Leaf), expected))
    @test object_ids(model; id=[2, 10, 2]) == ObjectId.([10, 2])
end

@testset "missing object diagnostics preserve scalar values and complete tuple identities" begin
    present = Object((:plant, :leaf, 1); status=Status(value=2f0))
    model = CompositeModel(present)
    @test model_object(model, present.id) === present
    @test model_status(model, present.id) === present.status
    cases = (
        :missing => "missing",
        "missing" => "missing",
        17 => "17",
        2.5 => "2.5",
        true => "true",
        (:missing, :leaf, 2) => "(Symbol(\"missing\"), Symbol(\"leaf\"), 2)",
        (:missing, (:leaf, 2)) => "(Symbol(\"missing\"), (Symbol(\"leaf\"), 2))",
    )
    for (id, expected) in cases, lookup in (model_object, model_status, object_id)
        failure = try
            lookup(model, ObjectId(id))
        catch exception
            exception
        end
        @test failure isa ErrorException
        @test sprint(showerror, failure) == "No model object with id `$(expected)`."
    end
end

# Genuine model configuration declares the replacement's numerical types at
# preparation; no dummy object or explicit canonical Status prototype is needed.
PSE.@process "canonical_family_replacement" verbose=false
struct FamilyReplacement{D} <: AbstractCanonical_Family_ReplacementModel
    defaults::D
end
PSE.inputs_(::FamilyReplacement) = (;)
PSE.outputs_(model::FamilyReplacement) = model.defaults
PSE.run!(::FamilyReplacement, status, environment, constants, context) = nothing

@testset "application status diagnostics identify unselected objects" begin
    root = Object(:root; status=Status(value=1f0))
    leaf = Object((:tree, :leaf, 2); scale=:Leaf, parent=:root, status=Status(value=2f0))
    model = CompositeModel(root, leaf; applications=(ModelSpec(
        FamilyReplacement((value=1f0,)); name=:replacement, on=One(id=:root)),))
    compiled = run!(model; steps=0).compiled
    application = PSE._compiled_application_by_id(compiled, :replacement)
    @test !isnothing(PSE._model_status_view_for_application(compiled, application, root.id))
    @test_throws ErrorException("No compiled status view for application `replacement` on object " *
        "`(Symbol(\"tree\"), Symbol(\"leaf\"), 2)`.") PSE._model_status_view_for_application(
        compiled, application, leaf.id)
end

@noinline function escape_registered_status!(sink, model, id, count)
    for _ in 1:count
        sink[] = model_status(model, id)
    end
    return nothing
end

registered_status_allocations(sink, model, id, count) =
    @allocated escape_registered_status!(sink, model, id, count)

@testset "escaping prepared-family lookups reuse the official Status box" begin
    supplied = Status(value=1f0, items=Float32[2], counter=0, label=:leaf, active=true)
    object = Object(:leaf; status=supplied)
    replacement_defaults = (value=4.0, items=[5.0], counter=1, label=:updated, active=false)
    model = CompositeModel(object; applications=(ModelSpec(
        FamilyReplacement(replacement_defaults); name=:replacement, on=One(id=:leaf)),))
    canonical = model_status(model, object.id)
    sink = Ref{Any}()
    for _ in 1:2
        escape_registered_status!(sink, model, object.id, 1000)
        registered_status_allocations(sink, model, object.id, 1000)
    end
    @test registered_status_allocations(sink, model, object.id, 1) == 0
    @test registered_status_allocations(sink, model, object.id, 1000) == 0
    @test sink[] === canonical === object.status
    @test sink[] !== supplied
    @test all(index -> PSE.refvalues(sink[])[index] === PSE.refvalues(supplied)[index],
              eachindex(PSE.refvalues(supplied)))
    location = model.registry.objects.locations[object.id]
    family = model.registry.objects.catalog.families[location.family]
    @test family.rows[location.row].status === sink[]
    sink[].items[1] = 3f0
    @test supplied.items === object.status.items
    @test supplied.items == Float32[3]

    replacement = Status(value=4.0, items=[5.0], counter=1, label=:updated, active=false)
    official_replacement = PSE._replace_model_object_status!(model, object, replacement)
    for _ in 1:2
        escape_registered_status!(sink, model, object.id, 1000)
        registered_status_allocations(sink, model, object.id, 1000)
    end
    @test registered_status_allocations(sink, model, object.id, 1000) == 0
    @test sink[] === official_replacement === object.status
    @test sink[] !== replacement
    @test PSE.refvalue(sink[], :items) === PSE.refvalue(replacement, :items)
    @test object_id(model, official_replacement) === object.id
    @test_throws ArgumentError object_id(model, replacement)
    @test_throws ArgumentError object_id(model, canonical)
    @test_throws ArgumentError object_id(model, supplied)
    @test supplied.items == Float32[3]
end

@testset "status replacement keeps the prepared family and exclusive official ownership" begin
    original = Status(value=1f0)
    first = Object(:first; status=original)
    occupied = Status(value=9.0)
    second = Object(:second; status=occupied)
    model = CompositeModel(first, second; applications=(ModelSpec(
        FamilyReplacement((value=3.0, counter=2)); name=:replacement, on=One(id=:first)),))
    store = model.registry.objects
    first_official = model_status(model, :first)
    second_official = model_status(model, :second)
    previous = store.locations[first.id]
    replacement = Status(value=3.0, counter=2)

    official = PSE._replace_model_object_status!(model, first, replacement)
    @test official !== replacement
    current = store.locations[first.id]
    @test current.family == previous.family
    @test current.row == previous.row
    @test store.catalog.families[current.family].rows[current.row].status === official
    @test model_object(model, :first) === first
    @test first.status === model_status(model, :first) === official
    @test PSE.refvalue(official, :value) === PSE.refvalue(replacement, :value)
    @test object_id(model, official) === first.id
    @test_throws ArgumentError object_id(model, replacement)
    @test_throws ArgumentError object_id(model, first_official)
    @test_throws ArgumentError object_id(model, original)
    @test original.value === 1f0

    @test_throws ArgumentError PSE._replace_model_object_status!(model, first, occupied)
    @test_throws ArgumentError PSE._replace_model_object_status!(model, first, second_official)
    @test first.status === model_status(model, :first) === official
    @test model_status(model, :second) === second_official
    @test store.locations[first.id] == current
    @test_throws ArgumentError PSE._replace_model_object_status!(
        model, Object(:first; status=Status(value=0.0)), Status(value=12.0))
    @test model_object(model, :first) === first
    @test model_status(model, :first) === official

    @test isnothing(PSE._replace_model_object_status!(model, first, nothing))
    @test isnothing(model_status(model, :first))
    @test_throws ArgumentError object_id(model, official)
    restored = PSE._replace_model_object_status!(model, first, original)
    @test restored !== original
    @test restored === model_status(model, :first)
    @test PSE.refvalue(restored, :value) === PSE.refvalue(original, :value)
    @test object_id(model, restored) === first.id
    @test_throws ArgumentError object_id(model, original)
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
    @test !hasproperty(born, :node)
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
    @test !hasproperty(grown, :new_field)
    @test source_node(model, grown)[:new_field] === 4

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
    manifest = model.registry.objects.catalog.status_manifest
    @test model.scenario_plan_cache.status_manifest === manifest
    copied = deepcopy(model)
    copied_manifest = copied.registry.objects.catalog.status_manifest
    @test copied.scenario_plan_cache.status_manifest === copied_manifest
    @test copied_manifest !== manifest
    @test copied_manifest.raw_families !== manifest.raw_families
    shared = deepcopy((manifest, manifest))
    @test shared[1] === shared[2]
    @test shared[1] !== manifest
    @test shared[1].raw_families !== manifest.raw_families
    copied_object = model_object(copied, :leaf)
    copied_status = model_status(copied, :leaf)
    @test copied_object !== object
    @test copied_status !== model_status(model, :leaf)
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
    canonical = model_status(model, first.id)
    S = typeof(canonical)
    inferred = Core.Compiler.return_type(PSE._object_family_status,
        Tuple{typeof(closed),typeof(first.id)})
    @test inferred === Union{Nothing,S}
    @test PSE._object_family_status(closed, first.id) === canonical
    @test PSE.refvalue(canonical, :value) === PSE.refvalue(first_status, :value)
    store_type = typeof(closed)

    born = Object(2; status=Status(value=2f0))
    register_object!(model, born)
    closed[born.id] = born
    @test typeof(closed) === store_type
    @test length(closed) == 2
    @test PSE._object_family_status(closed, born.id) === born.status
    @test closed.status_owners[PSE._status_identity(born.status)] === born.id
    foreign = CompositeModel(Object(3; status=Status(value=3.0)))
    @test_throws ArgumentError setindex!(closed, model_object(foreign, 3), ObjectId(3))
    @test !haskey(closed, ObjectId(3))
    @test length(closed) == 2

    delete!(closed, born.id)
    @test length(closed) == 1
    @test !haskey(closed.status_owners, PSE._status_identity(born.status))
    remove_object!(model, born.id)
    replacement = Object(2; status=Status(value=8f0))
    register_object!(model, replacement)
    closed[replacement.id] = replacement
    @test closed[replacement.id] === replacement
    @test PSE._object_family_status(closed, replacement.id).value === 8f0

    mixed = CompositeModel(Object(1; status=Status(value=1f0)), Object(:leaf; status=nothing))
    mixed_closed = PSE._closed_object_family_store(mixed.registry.objects)
    @test keytype(mixed_closed.locations) === Union{ObjectId{Int},ObjectId{Symbol}}
    @test PSE._object_family_status(mixed_closed, ObjectId(1)).value === 1f0
    @test isnothing(PSE._object_family_status(mixed_closed, ObjectId(:leaf)))

    # Runtime discovery/retirement of arbitrary Status types is obsolete.
    # Empty None+S retention is covered by test-prepared-status-registration.

    statuses = [Status(value=Float32(index), payload=ntuple(identity, index)) for index in 1:8]
    eight = CompositeModel((Object(index; status=status) for (index, status) in enumerate(statuses))...)
    eight_closed = PSE._closed_object_family_store(eight.registry.objects)
    official = [model_status(eight, index) for index in 1:8]
    S = typeof(Base.first(official))
    allowed = Union{Nothing,S}
    inferred = Core.Compiler.return_type(PSE._object_family_status,
        Tuple{typeof(eight_closed),ObjectId{Int}})
    @test inferred === allowed
    for (index, status) in enumerate(statuses)
        canonical = PSE._object_family_status(eight_closed, ObjectId(index))
        @test canonical === official[index]
        @test PSE.refvalue(canonical, :value) === PSE.refvalue(status, :value)
        @test PSE.refvalue(canonical, :payload) === PSE.refvalue(status, :payload)
    end
end

@testset "declared closed ID domains admit real future identities before row copies" begin
    parent = Object(:plant; kind=:plant, status=Status(value=1f0))
    model = CompositeModel(parent; applications=(ModelSpec(
        FamilyReplacement((value=0f0,)); name=:leaves, on=Many(kind=:leaf)),))
    original = model_status(model, :plant)
    reference = PSE.refvalue(original, :value)
    snapshot_watchers() = begin
        watchers = PSE._status_vars(original).watchers
        watchers isa Vector ? copy(watchers) : watchers
    end
    before_watchers = snapshot_watchers()
    for invalid in (ObjectId, Int, Union{}, ObjectId{Int})
        @test_throws ArgumentError PSE._closed_object_family_store(model.registry.objects, invalid)
        @test snapshot_watchers() == before_watchers
        @test model_status(model, :plant) === original
        @test PSE.refvalue(original, :value) === reference
    end
    I = Union{ObjectId{Symbol},ObjectId{Tuple{Symbol,Symbol,Int}}}
    store = PSE._closed_object_family_store(model.registry.objects, I)
    @test keytype(store) === I
    @test store.catalog.status_manifest === model.registry.objects.catalog.status_manifest
    admitted_watchers = snapshot_watchers()
    @test PSE._closed_object_family_store(store, I) === store
    @test snapshot_watchers() == admitted_watchers
    registry = PSE.ObjectRegistry(store, model.registry.by_scale, model.registry.by_kind,
        model.registry.by_species, model.registry.ancestor_ids_by_object)
    closed = PSE.CompositeModel(registry,
        (getfield(model, index) for index in 2:fieldcount(typeof(model)))...)
    @test model_object(closed, :plant) === parent
    @test model_status(closed, :plant) === original
    @test PSE.refvalue(model_status(closed, :plant), :value) === reference
    supplied = Status(value=2f0)
    newborn_reference = PSE.refvalue(supplied, :value)
    newborn = Object((:plant, :leaf, 1); kind=:leaf, parent=:plant, status=supplied)
    register_object!(closed, newborn)
    @test model_object(closed, newborn.id) === newborn
    @test object_id(closed, newborn) === ObjectId((:plant, :leaf, 1))
    @test model_status(closed, newborn.id) === newborn.status
    @test PSE.refvalue(newborn.status, :value) === newborn_reference
    children = copy(parent.children)
    @test_throws ArgumentError register_object!(closed,
        Object(17; kind=:leaf, parent=:plant, status=Status(value=3f0)))
    @test !haskey(store, ObjectId(17))
    @test parent.children == children
    @test PSE._closed_object_family_store(store) === store

    empty_model = CompositeModel(; applications=(ModelSpec(
        FamilyReplacement((value=0f0,)); name=:leaves, on=Many(kind=:leaf)),))
    empty_store = empty_model.registry.objects
    legacy_empty = PSE._closed_object_family_store(empty_store)
    @test isempty(legacy_empty)
    @test keytype(legacy_empty) === ObjectId
    @test legacy_empty !== empty_store
    @test legacy_empty.catalog.status_manifest === empty_store.catalog.status_manifest
    declared_empty = PSE._closed_object_family_store(empty_store, I)
    @test isempty(declared_empty)
    @test keytype(declared_empty) === I
    @test PSE._closed_object_family_store(declared_empty, I) === declared_empty
end

end

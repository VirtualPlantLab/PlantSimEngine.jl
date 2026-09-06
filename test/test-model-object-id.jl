PlantSimEngine.@process "object_identity_probe" verbose = false

struct ObjectIdentityProbeModel{N,I} <: AbstractObject_Identity_ProbeModel
    source::N
    expected::I
end

PlantSimEngine.inputs_(::ObjectIdentityProbeModel) = NamedTuple()
PlantSimEngine.outputs_(::ObjectIdentityProbeModel) = (
    matches=false,
    current_object_matches=false,
    current_status_matches=false,
    current_node_matches=false,
)

function PlantSimEngine.run!(
    model::ObjectIdentityProbeModel,
    status,
    environment,
    constants,
    context,
)
    status.matches = object_id(context, model.source) == model.expected
    current_object = model_object(context)
    status.current_object_matches =
        object_id(context) == current_object.id &&
        current_object === model_object(runtime_model(context), object_id(context))
    status.current_status_matches =
        model_status(context) === current_object.status
    status.current_node_matches =
        source_node(context) ===
        source_node(runtime_model(context), object_id(context))
    return nothing
end

function _registered_object_id_allocations(model, id)
    object_id(model, id)
    return @allocated object_id(model, id)
end

_object_identity_nothing(node) = nothing

function _object_identity_reference_objects_from_mtg(root)
    objects = Object[]
    MultiScaleTreeGraph.traverse!(root) do node
        node_parent = MultiScaleTreeGraph.parent(node)
        parent_id = node === root || isnothing(node_parent) ?
                    nothing : MultiScaleTreeGraph.node_id(node_parent)
        push!(
            objects,
            Object(
                MultiScaleTreeGraph.node_id(node);
                scale=MultiScaleTreeGraph.symbol(node),
                kind=nothing,
                species=nothing,
                name=nothing,
                parent=parent_id,
                geometry=nothing,
                status=nothing,
            ),
        )
    end
    return objects
end

function _object_identity_standalone_objects_from_mtg(root)
    return objects_from_mtg(
        root;
        kind=_object_identity_nothing,
        species=_object_identity_nothing,
        name=_object_identity_nothing,
        geometry=_object_identity_nothing,
        status=_object_identity_nothing,
    )
end

function _object_identity_projection_allocations(f, root)
    f(root)
    return minimum(@allocated(f(root)) for _ in 1:3)
end

@testset "standalone MTG projection stays lightweight" begin
    root = Node(MultiScaleTreeGraph.NodeMTG("/", :Scene, 1, 0))
    for index in 1:128
        Node(root, MultiScaleTreeGraph.NodeMTG("+", :Leaf, index, 1))
    end

    reference_allocations = _object_identity_projection_allocations(
        _object_identity_reference_objects_from_mtg,
        root,
    )
    standalone_allocations = _object_identity_projection_allocations(
        _object_identity_standalone_objects_from_mtg,
        root,
    )
    @test standalone_allocations <= reference_allocations + 4_096
end

@testset "registered object identity resolution" begin
    root = Node(MultiScaleTreeGraph.NodeMTG("/", :Scene, 1, 0))
    plant = Node(root, MultiScaleTreeGraph.NodeMTG("+", :Plant, 1, 1))
    leaf = Node(plant, MultiScaleTreeGraph.NodeMTG("+", :Leaf, 1, 2))
    mtg_id = node -> (MultiScaleTreeGraph.symbol(node), MultiScaleTreeGraph.node_id(node))
    leaf_id = ObjectId((:Leaf, MultiScaleTreeGraph.node_id(leaf)))
    adapted = objects_from_mtg(root; id=mtg_id)
    @test only(object for object in adapted if object.id == leaf_id).scale == :Leaf

    model = CompositeModel(
        root;
        id=mtg_id,
        applications=(
            ModelSpec(
                ObjectIdentityProbeModel(leaf, leaf_id);
                name=:object_identity_probe,
                on=One(scale=:Scene),
            ),
        ),
    )

    registered_leaf = model_object(model, leaf_id)
    @test object_id(model, leaf_id) == leaf_id
    @test _registered_object_id_allocations(model, leaf_id) == 0
    @test object_id(model, leaf_id.value) == leaf_id
    @test object_id(model, registered_leaf) == leaf_id
    @test object_id(model, leaf) == leaf_id
    @test _registered_object_id_allocations(model, leaf) == 0
    @test model_object(model, leaf) === registered_leaf
    @test source_node(model, leaf_id) === leaf

    copied_root = deepcopy(root)
    copied_leaf = MultiScaleTreeGraph.get_node(
        copied_root,
        MultiScaleTreeGraph.node_id(leaf),
    )
    copied_plant = MultiScaleTreeGraph.get_node(
        copied_root,
        MultiScaleTreeGraph.node_id(plant),
    )
    @test mtg_id(copied_leaf) == mtg_id(leaf)
    @test_throws ArgumentError object_id(model, copied_leaf)
    @test_throws ArgumentError object_id(
        model,
        Object(leaf_id.value; scale=:Leaf),
    )
    @test_throws ErrorException object_id(model, (:Leaf, 999))

    copied_child_count = length(MultiScaleTreeGraph.children(copied_plant))
    registered_before = object_ids(model)
    @test_throws ArgumentError add_organ!(
        copied_plant,
        model,
        :+,
        :Leaf,
        2;
        index=2,
        initial_status=(signal=0.0,),
    )
    @test length(MultiScaleTreeGraph.children(copied_plant)) == copied_child_count
    @test object_ids(model) == registered_before

    new_leaf_status = add_organ!(
        plant,
        model,
        :+,
        :Leaf,
        2;
        index=2,
        initial_status=(signal=0.0,),
    )
    new_leaf_id = ObjectId((:Leaf, 4))
    @test MultiScaleTreeGraph.node_id(new_leaf_status.node) == 4
    @test object_id(model, new_leaf_status) == new_leaf_id
    @test object_id(model, new_leaf_status.node) == new_leaf_id
    @test model_status(model, new_leaf_id) === new_leaf_status
    @test source_node(model, new_leaf_status) === new_leaf_status.node

    simulation = run!(model; steps=1, outputs=:none)
    probe_status = model_object(model, (:Scene, 1)).status
    @test probe_status.matches
    @test probe_status.current_object_matches
    @test probe_status.current_status_matches
    @test probe_status.current_node_matches
    @test object_id(simulation, leaf) == leaf_id

    remove_object!(model, new_leaf_id)
    @test_throws ArgumentError object_id(model, new_leaf_status)
    remove_object!(model, leaf_id)
    @test_throws ErrorException object_id(model, leaf_id)
    @test_throws ArgumentError object_id(model, leaf)
end

@testset "MTG adapter reserves ids from detached shared-store components" begin
    root = Node(MultiScaleTreeGraph.NodeMTG("/", :Scene, 1, 0))
    plant = Node(root, MultiScaleTreeGraph.NodeMTG("+", :Plant, 1, 1))
    detached = Node(plant, MultiScaleTreeGraph.NodeMTG("+", :Leaf, 1, 2))
    MultiScaleTreeGraph.reparent!(detached, nothing)

    @test MultiScaleTreeGraph.max_id(root) == 2
    @test MultiScaleTreeGraph.new_id(root) == 4

    model = CompositeModel(root)
    @test_throws ArgumentError object_id(model, detached)

    added = add_organ!(
        plant,
        model,
        :+,
        :Leaf,
        2;
        index=1,
        initial_status=(signal=1.0,),
    )

    @test MultiScaleTreeGraph.node_id(added.node) == 4
    @test MultiScaleTreeGraph.parent(added.node) === plant
    @test source_node(model, ObjectId(4)) === added.node
    @test MultiScaleTreeGraph.new_id(root) == 5
    @test MultiScaleTreeGraph.node_id(detached) == 3
end

@testset "MTG identities remain stable after source mutation" begin
    root = Node(MultiScaleTreeGraph.NodeMTG("/", :Scene, 1, 0))
    plant = Node(root, MultiScaleTreeGraph.NodeMTG("+", :Plant, 1, 1))
    leaf_a = Node(plant, MultiScaleTreeGraph.NodeMTG("+", :Leaf, 1, 2))
    leaf_b = Node(plant, MultiScaleTreeGraph.NodeMTG("+", :Leaf, 2, 2))
    runtime_ids = IdDict{Any,Symbol}(
        root => :scene,
        plant => :plant,
        leaf_a => :leaf_a,
        leaf_b => :leaf_b,
    )
    mutable_id = node -> (runtime_ids[node], MultiScaleTreeGraph.node_id(node))
    model = CompositeModel(root; id=mutable_id)
    leaf_a_id = ObjectId((:leaf_a, 3))
    leaf_b_id = ObjectId((:leaf_b, 4))

    @test object_id(model, leaf_a) == leaf_a_id
    @test object_id(model, leaf_b) == leaf_b_id
    runtime_ids[leaf_a] = :leaf_b
    setfield!(leaf_a, :id, 4)
    @test mutable_id(leaf_a) == leaf_b_id.value
    @test object_id(model, leaf_a) == leaf_a_id
    @test object_id(model, leaf_b) == leaf_b_id
    setfield!(leaf_b, :id, 999)
    @test MultiScaleTreeGraph.node_id(leaf_b) == 999
    @test object_id(model, leaf_a) == leaf_a_id
    @test object_id(model, leaf_b) == leaf_b_id
    @test _registered_object_id_allocations(model, leaf_a) == 0
    @test _registered_object_id_allocations(model, leaf_b) == 0

    duplicate_root = Node(MultiScaleTreeGraph.NodeMTG("/", :Scene, 1, 0))
    Node(duplicate_root, MultiScaleTreeGraph.NodeMTG("+", :Plant, 1, 1))
    @test_throws ErrorException CompositeModel(duplicate_root; id=_ -> :duplicate)
end

@testset "removed MTG identities can be reused by new nodes" begin
    root = Node(
        MultiScaleTreeGraph.NodeMTG("/", :Scene, 1, 0),
        (runtime_id=:scene,),
    )
    plant = Node(
        root,
        MultiScaleTreeGraph.NodeMTG("+", :Plant, 1, 1),
        (runtime_id=:plant,),
    )
    old_leaf = Node(
        plant,
        MultiScaleTreeGraph.NodeMTG("+", :Leaf, 1, 2),
        (runtime_id=:reusable_leaf,),
    )
    model = CompositeModel(root; id=node -> node[:runtime_id])
    reusable_id = ObjectId(:reusable_leaf)
    old_raw_id = MultiScaleTreeGraph.node_id(old_leaf)

    remove_object!(model, reusable_id)
    @test_throws ArgumentError object_id(model, old_leaf)

    new_leaf_status = add_organ!(
        plant,
        model,
        :+,
        :Leaf,
        2;
        index=2,
        id=10,
        attributes=(runtime_id=:reusable_leaf,),
        initial_status=(signal=0.0,),
    )
    @test new_leaf_status.node !== old_leaf
    @test MultiScaleTreeGraph.node_id(new_leaf_status.node) != old_raw_id
    @test object_id(model, new_leaf_status.node) == reusable_id
    @test_throws ArgumentError object_id(model, old_leaf)
end

@testset "empty application plan survives structural refresh" begin
    root = Node(MultiScaleTreeGraph.NodeMTG("/", :Scene, 1, 0))
    plant = Node(root, MultiScaleTreeGraph.NodeMTG("+", :Plant, 1, 1))
    Node(plant, MultiScaleTreeGraph.NodeMTG("+", :Leaf, 1, 2))
    model = CompositeModel(
        root;
        status=node -> Status(node=node, signal=0.0),
    )
    simulation = run!(model; steps=1, outputs=:none)
    initial_step = current_step(simulation)

    added = add_organ!(
        plant,
        model,
        :+,
        :Leaf,
        2;
        index=2,
        initial_status=(signal=1.0,),
    )
    @test Advanced.bindings_dirty(model)
    @test continue!(simulation) === simulation
    @test current_step(simulation) == initial_step + 1
    @test !Advanced.bindings_dirty(model)
    @test object_id(model, added) == ObjectId(4)
end

@testset "registered Status identity resolution" begin
    status = Status(signal=1.0)
    object = Object(:leaf; scale=:Leaf, status=status)
    model = CompositeModel(object)

    @test object_id(model, status) == ObjectId(:leaf)
    @test _registered_object_id_allocations(model, status) == 0
    @test object_id(model, object) == ObjectId(:leaf)
    @test model_object(model, status) === object
    @test model_status(model, object) === status
    foreign_mtg = Node(MultiScaleTreeGraph.NodeMTG("/", :Leaf, 1, 1))
    @test_throws ArgumentError object_id(model, foreign_mtg)
    @test_throws ArgumentError object_id(model, Status(signal=1.0))
    @test_throws ArgumentError source_node(model, status)

    empty_status_a = Status()
    empty_status_b = Status()
    @test empty_status_a !== empty_status_b
    empty_model = CompositeModel(
        Object(:empty_a; scale=:Leaf, status=empty_status_a),
        Object(:empty_b; scale=:Leaf, status=empty_status_b),
    )
    @test object_id(empty_model, empty_status_a) == ObjectId(:empty_a)
    @test object_id(empty_model, empty_status_b) == ObjectId(:empty_b)

    shared_status = Status(signal=2.0)
    @test_throws ArgumentError CompositeModel(
        Object(:scene; scale=:Scene),
        Object(:leaf_a; scale=:Leaf, parent=:scene, status=shared_status),
        Object(:leaf_b; scale=:Leaf, parent=:scene, status=shared_status),
    )

    mtg_root = Node(MultiScaleTreeGraph.NodeMTG("/", :Scene, 1, 0))
    mtg_plant = Node(mtg_root, MultiScaleTreeGraph.NodeMTG("+", :Plant, 1, 1))
    mtg_leaf_a = Node(mtg_plant, MultiScaleTreeGraph.NodeMTG("+", :Leaf, 1, 2))
    mtg_leaf_b = Node(mtg_plant, MultiScaleTreeGraph.NodeMTG("+", :Leaf, 2, 2))
    shared_mtg_status = Status(node=mtg_leaf_a, signal=3.0)
    statuses = IdDict{Any,Any}(
        mtg_leaf_a => shared_mtg_status,
        mtg_leaf_b => shared_mtg_status,
    )
    @test_throws ArgumentError CompositeModel(
        mtg_root;
        status=node -> get(statuses, node, nothing),
    )

    canonical_mtg = CompositeModel(mtg_root)
    @test isnothing(model_status(canonical_mtg, mtg_leaf_a))
    @test source_node(canonical_mtg, mtg_leaf_b) === mtg_leaf_b
end

PlantSimEngine.@process "object_identity_probe" verbose = false

struct ObjectIdentityProbeModel{N,I} <: AbstractObject_Identity_ProbeModel
    source::N
    expected::I
end

PlantSimEngine.inputs_(::ObjectIdentityProbeModel) = NamedTuple()
PlantSimEngine.outputs_(::ObjectIdentityProbeModel) = (matches=false,)

function PlantSimEngine.run!(
    model::ObjectIdentityProbeModel,
    status,
    environment,
    constants,
    context,
)
    status.matches = object_id(context, model.source) == model.expected
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

    simulation = run!(model; steps=1, outputs=:none)
    @test model_object(model, (:Scene, 1)).status.matches
    @test object_id(simulation, leaf) == leaf_id

    remove_object!(model, leaf_id)
    @test_throws ErrorException object_id(model, leaf_id)
    @test_throws ArgumentError object_id(model, leaf)
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

@testset "registered Status identity resolution" begin
    status = Status(signal=1.0)
    object = Object(:leaf; scale=:Leaf, status=status)
    model = CompositeModel(object)

    @test object_id(model, status) == ObjectId(:leaf)
    @test object_id(model, object) == ObjectId(:leaf)
    foreign_mtg = Node(MultiScaleTreeGraph.NodeMTG("/", :Leaf, 1, 1))
    @test_throws ArgumentError object_id(model, foreign_mtg)
    @test_throws ArgumentError object_id(model, Status(signal=1.0))

    shared_status = Status(signal=2.0)
    ambiguous = CompositeModel(
        Object(:scene; scale=:Scene),
        Object(:leaf_a; scale=:Leaf, parent=:scene, status=shared_status),
        Object(:leaf_b; scale=:Leaf, parent=:scene, status=shared_status),
    )
    @test_throws ArgumentError object_id(ambiguous, shared_status)

    mtg_root = Node(MultiScaleTreeGraph.NodeMTG("/", :Scene, 1, 0))
    mtg_plant = Node(mtg_root, MultiScaleTreeGraph.NodeMTG("+", :Plant, 1, 1))
    mtg_leaf_a = Node(mtg_plant, MultiScaleTreeGraph.NodeMTG("+", :Leaf, 1, 2))
    mtg_leaf_b = Node(mtg_plant, MultiScaleTreeGraph.NodeMTG("+", :Leaf, 2, 2))
    shared_mtg_status = Status(node=mtg_leaf_a, signal=3.0)
    mtg_leaf_a[:plantsimengine_status] = shared_mtg_status
    mtg_leaf_b[:plantsimengine_status] = shared_mtg_status
    ambiguous_mtg = CompositeModel(mtg_root)
    @test_throws ArgumentError object_id(ambiguous_mtg, shared_mtg_status)
end

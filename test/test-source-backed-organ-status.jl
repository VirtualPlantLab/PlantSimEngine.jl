using Dates
using PlantSimEngine
using MultiScaleTreeGraph
using Test

PlantSimEngine.@process "source_backed_length" verbose=false
struct SourceBackedLengthModel <: AbstractSource_Backed_LengthModel end
PlantSimEngine.inputs_(::SourceBackedLengthModel) = NamedTuple()
PlantSimEngine.outputs_(::SourceBackedLengthModel) = (Length=0.0,)
function PlantSimEngine.run!(::SourceBackedLengthModel, status, environment, constants, context)
    status.Length += 1.0
    return nothing
end

PlantSimEngine.@process "source_backed_total" verbose=false
struct SourceBackedTotalModel <: AbstractSource_Backed_TotalModel end
PlantSimEngine.inputs_(::SourceBackedTotalModel) = (lengths=Required(Vector{Float64}), first_length=Required(Float64))
PlantSimEngine.outputs_(::SourceBackedTotalModel) = (total=0.0, first_seen=0.0)
function PlantSimEngine.run!(::SourceBackedTotalModel, status, environment, constants, context)
    status.total = sum(status.lengths)
    status.first_seen = status.first_length
    return nothing
end

PlantSimEngine.@process "source_backed_history" verbose=false
struct SourceBackedHistoryModel <: AbstractSource_Backed_HistoryModel end
PlantSimEngine.inputs_(::SourceBackedHistoryModel) = (
    previous=Required(Float64), held=Required(Float64),
)
PlantSimEngine.outputs_(::SourceBackedHistoryModel) = (previous_seen=0.0, held_seen=0.0)
function PlantSimEngine.run!(::SourceBackedHistoryModel, status, environment, constants, context)
    status.previous_seen = status.previous
    status.held_seen = status.held
    return nothing
end

PlantSimEngine.@process "source_backed_distribution" verbose=false
struct SourceBackedDistributionModel <: AbstractSource_Backed_DistributionModel end
PlantSimEngine.inputs_(::SourceBackedDistributionModel) = NamedTuple()
PlantSimEngine.outputs_(::SourceBackedDistributionModel) = (Length=Distributed(Default(0.0)),)
function PlantSimEngine.run!(::SourceBackedDistributionModel, status, environment, constants, context)
    targets = output_targets(context, (:Length,))
    assign_outputs!(targets, (object_id=collect(object_ids(targets)), Length=fill(12.0, length(targets))))
    return nothing
end

# This small client-owned handle exercises PSE's interface dispatch without
# implementing another storage engine in its tests.
struct SourceBackedTestNode <: MultiScaleTreeGraph.AbstractMTGNode
    node::MultiScaleTreeGraph.Node
end
MultiScaleTreeGraph.node_id(node::SourceBackedTestNode) = node_id(getfield(node, :node))
MultiScaleTreeGraph.node_mtg(node::SourceBackedTestNode) = node_mtg(getfield(node, :node))
MultiScaleTreeGraph.node_attributes(node::SourceBackedTestNode) = node_attributes(getfield(node, :node))
Base.parent(node::SourceBackedTestNode) = begin
    value = parent(getfield(node, :node))
    isnothing(value) ? nothing : SourceBackedTestNode(value)
end
MultiScaleTreeGraph.children(node::SourceBackedTestNode) = SourceBackedTestNode.(children(getfield(node, :node)))
MultiScaleTreeGraph.get_root(node::SourceBackedTestNode) = SourceBackedTestNode(get_root(getfield(node, :node)))
MultiScaleTreeGraph.new_id(node::SourceBackedTestNode) = new_id(getfield(node, :node))
MultiScaleTreeGraph.get_node(node::SourceBackedTestNode, id::Int) = begin
    value = get_node(getfield(node, :node), id)
    isnothing(value) ? nothing : SourceBackedTestNode(value)
end
MultiScaleTreeGraph.add_node!(parent_node::SourceBackedTestNode, id::Int, encoding::MultiScaleTreeGraph.AbstractNodeMTG, attrs) =
    SourceBackedTestNode(add_node!(getfield(parent_node, :node), id, encoding, attrs))
MultiScaleTreeGraph.delete_node!(node::SourceBackedTestNode) = delete_node!(getfield(node, :node))

source_backed_factory(node, adapted, initial) = Status((
    node=Ref(node),
    Length=attribute_ref(node, :Length, Float64),
))

@testset "Reference-vector constructors retain concrete backing" begin
    references = [Ref(1.0), Ref(2.0)]
    inferred = PlantSimEngine.RefVector(references)
    declared = PlantSimEngine.RefVector{Float64}(references)
    @test typeof(inferred) === typeof(declared)
    @test eltype(inferred) === Float64
    @test parent(inferred) === references
    @test collect(inferred) == [1.0, 2.0]
    @test isempty(PlantSimEngine.RefVector{Float64}())
end

@testset "Source-backed organ status factory" begin
    root = Node(NodeMTG(:/, :Plant, 1, 0))
    runtime = Ref(0)
    model = CompositeModel(root;
        status=node -> Status(node=node, runtime=runtime),
        status_factory=source_backed_factory,
    )
    @test model_status(model, root).runtime === runtime
    first_status = add_organ!(root, model, :+, :Leaf, 1;
        attributes=(Length=1.0, cold_metadata="not a runtime variable"),
        use_status_adapter=false)
    first_leaf = source_node(model, first_status)
    @test propertynames(first_status) == (:node, :Length)
    @test first_status.node === first_leaf
    @test !hasproperty(first_status, :cold_metadata)
    @test first_status.Length == 1.0
    @test PlantSimEngine.refvalue(first_status, :Length) isa Ref{Float64}
    @test !(PlantSimEngine.refvalue(first_status, :Length) isa Base.RefValue)
    first_leaf[:Length] = 3.0
    @test first_status.Length == 3.0
    first_status.Length = 4.0
    @test first_leaf[:Length] == 4.0
    second_status = add_organ!(root, model, :+, :Leaf, 1;
        attributes=(Length=2.0,), use_status_adapter=false)
    @test PlantSimEngine._status_identity(first_status) !== PlantSimEngine._status_identity(second_status)
    @test object_id(model, first_status) != object_id(model, second_status)
    @test model_status(model, first_leaf) === first_status

    # The ordinary path retains private RefValue ownership.
    private_root = Node(NodeMTG(:/, :Plant, 1, 0))
    private_model = CompositeModel(private_root)
    private = add_organ!(private_root, private_model, :+, :Leaf, 1;
        attributes=(Length=1.0,), initial_status=(Length=2,), use_status_adapter=false)
    @test private.Length === 2
    @test source_node(private_model, private)[:Length] === 1.0
    @test PlantSimEngine.refvalue(private, :Length) isa Base.RefValue{Int}

    # A different model is private by default even on this same MTG. Explicit
    # source-backed policies intentionally opt into the source's storage.
    separate = CompositeModel(root; status=node -> Status(Length=get(node_attributes(node), :Length, 0.0)))
    separate_status = model_status(separate, first_leaf)
    first_status.Length = 5.0
    @test separate_status.Length == 4.0
end

@testset "Factory overlays, validation and rollback" begin
    calls = Ref(0)
    factory = function(node, adapted, initial)
        @test adapted.signal == 3.0
        @test node[:adapter_mutation] === true
        initial_signal = get(initial, :signal, adapted.signal)
        return Status((node=Ref(node), signal=Ref(initial_signal)))
    end
    root = Node(NodeMTG(:/, :Plant, 1, 0))
    accessor = node -> begin
        calls[] += 1
        node[:adapter_mutation] = true
        Status(signal=3.0)
    end
    model = CompositeModel(root; status=accessor, status_factory=factory)
    before = calls[]
    status = add_organ!(root, model, :+, :Leaf, 1;
        attributes=(signal=1.0,), initial_status=(signal=7,))
    @test calls[] == before + 1
    @test status.signal === 7
    @test source_node(model, status)[:signal] === 1.0

    bad_factories = (
        (node, adapted, initial) -> nothing,
        (node, adapted, initial) -> Status(node=:wrong),
        (node, adapted, initial) -> Status(node=node, plantsimengine_status=nothing),
        (node, adapted, initial) -> Status(node=node),
        (node, adapted, initial) -> Status(node=node, signal=Float64(initial.signal)),
    )
    for bad_factory in bad_factories
        bad_root = Node(NodeMTG(:/, :Plant, 1, 0))
        bad_model = CompositeModel(bad_root; status_factory=bad_factory)
        count_before = length(model_objects(bad_model))
        @test_throws ArgumentError add_organ!(bad_root, bad_model, :+, :Leaf, 1;
            attributes=(signal=1.0,), initial_status=(signal=7,), use_status_adapter=false)
        @test isempty(children(bad_root))
        @test length(model_objects(bad_model)) == count_before
    end
    reserved_root = Node(NodeMTG(:/, :Plant, 1, 0))
    reserved_model = CompositeModel(reserved_root; status_factory=source_backed_factory)
    @test_throws ErrorException add_organ!(reserved_root, reserved_model, :+, :Leaf, 1;
        attributes=(Length=1.0, plantsimengine_status=nothing), use_status_adapter=false)
    @test isempty(children(reserved_root))

    # Status transformation remains a registration policy. It can replace an
    # external cell when conversion is requested explicitly.
    transformed_root = Node(NodeMTG(:/, :Plant, 1, 0))
    transformed_model = CompositeModel(transformed_root;
        status_factory=source_backed_factory,
        status_transform=(key, value) -> key === :Length ? Float32(value) : value)
    transformed = add_organ!(transformed_root, transformed_model, :+, :Leaf, 1;
        attributes=(Length=1.0,), use_status_adapter=false)
    @test transformed.Length === 1.0f0
    @test source_node(transformed_model, transformed)[:Length] === 1.0
end

@testset "Typed One and Many bindings retain live cells through growth" begin
    root = Node(NodeMTG(:/, :Plant, 1, 0))
    first_leaf = Node(2, root, NodeMTG(:+, :Leaf, 1, 1), (Length=1.0,))
    model = CompositeModel(root;
        status=node -> MultiScaleTreeGraph.symbol(node) === :Leaf ?
            source_backed_factory(node, nothing, NamedTuple()) : Status(node=node),
        status_factory=source_backed_factory,
        environment=(duration=Hour(1),),
        applications=(
            ModelSpec(SourceBackedLengthModel(); name=:length, on=Many(scale=:Leaf)),
            ModelSpec(SourceBackedTotalModel(); name=:total, on=One(scale=:Plant),
                inputs=(
                    lengths=Many(within=Subtree(), scale=:Leaf, var=:Length, application=:length),
                    first_length=One(within=Subtree(), id=2, var=:Length, application=:length),
                )),
        ))
    first_status = model_status(model, first_leaf)
    simulation = run!(model; steps=1, outputs=:none)
    plant_status = model_status(model, root)
    @test plant_status.lengths isa PlantSimEngine.RefVector{Float64}
    @test eltype(parent(plant_status.lengths)) === typeof(PlantSimEngine.refvalue(first_status, :Length))
    @test plant_status.first_length === 2.0
    @test plant_status.first_seen === 2.0
    @test plant_status.total === 2.0
    @test source_node(model, first_status)[:Length] === 2.0
    second_status = add_organ!(root, model, :+, :Leaf, 1;
        attributes=(Length=4.0,), use_status_adapter=false)
    continue!(simulation; steps=1)
    plant_status = model_status(model, root)
    @test plant_status.lengths isa PlantSimEngine.RefVector{Float64}
    @test collect(plant_status.lengths) == [3.0, 5.0]
    @test plant_status.total === 8.0
    @test source_node(model, second_status)[:Length] === 5.0
    @test PlantSimEngine._model_binding_carrier_kind(only(filter(
        binding -> binding.input === :first_length, simulation.compiled.input_bindings))) === :ref

    # Registry removal is the PSE lifecycle operation; pruning the source MTG is
    # an explicit, separate operation. A stale removed cell must not remain in
    # the refreshed Many carrier.
    first_cell = PlantSimEngine.refvalue(model_status(model, first_leaf), :Length)
    second_leaf = source_node(model, second_status)
    remove_object!(model, object_id(model, second_leaf))
    MultiScaleTreeGraph.delete_node!(second_leaf)
    @test_throws ArgumentError second_status.Length
    continue!(simulation; steps=1)
    plant_status = model_status(model, root)
    many_binding = only(filter(
        binding -> binding.input === :lengths, simulation.compiled.input_bindings))
    @test many_binding.source_ids == [object_id(model, first_leaf)]
    @test length(model_objects(model; scale=:Leaf)) == 1
    @test collect(plant_status.lengths) == [4.0]
    @test plant_status.total === 4.0
    @test plant_status.first_seen === 4.0
    @test PlantSimEngine.refvalue(model_status(model, first_leaf), :Length) === first_cell
    plant_status.lengths[1] = 10.0
    @test first_leaf[:Length] === 10.0
    @test model_status(model, first_leaf).Length === 10.0
end

@testset "Source-backed cells keep accepted PreviousTimeStep history" begin
    root = Node(NodeMTG(:/, :Plant, 1, 0))
    leaf = Node(2, root, NodeMTG(:+, :Leaf, 1, 1), (Length=1.0,))
    model = CompositeModel(root;
        status=node -> MultiScaleTreeGraph.symbol(node) === :Leaf ?
            source_backed_factory(node, nothing, NamedTuple()) : Status(node=node, previous=1.0),
        environment=(duration=Hour(1),),
        applications=(
            ModelSpec(SourceBackedLengthModel(); name=:length,
                on=Many(scale=:Leaf), every=Hour(1)),
            ModelSpec(SourceBackedHistoryModel(); name=:history,
                on=One(scale=:Plant), every=Hour(1),
                inputs=(
                    PreviousTimeStep(:previous) => One(within=Subtree(),
                        scale=:Leaf, var=:Length, application=:length),
                    :held => One(within=Subtree(), scale=:Leaf,
                        var=:Length, application=:length, policy=HoldLast()),
                )),
        ))
    simulation = run!(model; steps=1, outputs=:all)
    history = model_status(model, root)
    history_view = simulation.compiled.status_views_by_target[
        (:history, object_id(model, root))].status
    source_cell = PlantSimEngine.refvalue(model_status(model, leaf), :Length)
    @test history.previous_seen === 1.0
    @test history.held_seen === 2.0
    @test PlantSimEngine.refvalue(history_view, :previous) isa Base.RefValue{Float64}
    @test PlantSimEngine.refvalue(history_view, :previous) !== source_cell
    @test PlantSimEngine.refvalue(history_view, :held) === source_cell
    stream = outputs(simulation)[(:length, object_id(model, leaf), :Length)]
    @test last(stream) == (1.0, 2.0)

    # An external live write is visible to HoldLast at the same cadence, while
    # the previous-step input must use the last accepted producer sample.
    leaf[:Length] = 100.0
    @test history_view.held === 100.0
    @test history_view.previous === 1.0
    @test last(stream) == (1.0, 2.0)
    continue!(simulation; steps=1)
    history = model_status(model, root)
    @test history.previous_seen === 2.0
    @test history.held_seen === 101.0
    @test leaf[:Length] === 101.0
    @test first(stream) == (1.0, 2.0)
    @test last(stream) == (2.0, 101.0)
end

@testset "Custom MTG node backend uses the creation hook" begin
    root = SourceBackedTestNode(Node(NodeMTG(:/, :Plant, 1, 0)))
    model = CompositeModel(root; status_factory=source_backed_factory)
    status = add_organ!(root, model, :+, :Leaf, 1;
        attributes=(Length=2.0,), use_status_adapter=false)
    node = source_node(model, status)
    @test node isa SourceBackedTestNode
    @test parent(node) === root
    @test object_id(model, node) == ObjectId(node_id(node))
    @test model_status(model, node) === status
    status.Length = 7.0
    @test node[:Length] === 7.0
    before = length(children(root))
    @test_throws ErrorException add_organ!(root, model, :+, :Leaf, 1; id=node_id(node),
        attributes=(Length=1.0,), use_status_adapter=false)
    @test length(children(root)) == before
end

@testset "Distributed assignment validates source-backed rows before writes" begin
    root = Node(NodeMTG(:/, :Plant, 1, 0))
    model = CompositeModel(root; status_factory=source_backed_factory,
        environment=(duration=Hour(1),),
        applications=(ModelSpec(SourceBackedDistributionModel(); name=:distribution,
            on=One(scale=:Plant),
            outputs_to=(OutputTo(Many(within=Subtree(), scale=:Leaf); vars=(:Length,)),)),))
    first = add_organ!(root, model, :+, :Leaf, 1;
        attributes=(Length=1.0,), use_status_adapter=false)
    second = add_organ!(root, model, :+, :Leaf, 1;
        attributes=(Length=2.0,), use_status_adapter=false)
    simulation = run!(model; steps=0, outputs=:none)
    second_node = source_node(model, second)
    delete!(node_attributes(second_node), :Length)
    caught = try
        continue!(simulation; steps=1)
        nothing
    catch error
        error
    end
    @test caught !== nothing
    @test occursin("Length", sprint(showerror, caught))
    @test first.Length === 1.0
    @test source_node(model, first)[:Length] === 1.0
end

using Dates
using MultiScaleTreeGraph
using PlantSimEngine
using Test

_grouped_tree_ids(node) = (
    MultiScaleTreeGraph.node_id(node),
    (_grouped_tree_ids(child) for child in MultiScaleTreeGraph.children(node))...,
)
_grouped_snapshots(model) = [
    (snapshot.id.value, snapshot.name, snapshot.parent,
     snapshot.children, snapshot.ancestors, snapshot.geometry)
    for snapshot in model.lifecycle_delta.added
]

function _grouped_creation_fixture(; failure=nothing, mutate=false, replace_prior=false, transform_node=false)
    root = Node(MultiScaleTreeGraph.NodeMTG(:/, :Scene, 1, 0))
    owner = Ref{Any}(nothing)
    active = Ref(root)
    trace = Any[]
    payload, nested = [:shared], Ref(7)
    source = Status(signal=2.0, payload=payload, nested=nested)
    replaced, replacement = Ref{Any}(nothing), Ref{Any}(nothing)
    function record(event, node; variable=nothing)
        isnothing(owner[]) && return
        model = owner[]
        push!(trace, (
            event, MultiScaleTreeGraph.node_id(node), variable,
            object_ids(model), _grouped_tree_ids(root), _grouped_snapshots(model),
            sort!(collect(model.lifecycle_delta.structural_dirty_ids); by=id -> id.value),
            sort!(collect(model.lifecycle_delta.environment_dirty_ids); by=id -> id.value),
            length(model.lifecycle_delta.moved), model.bindings_dirty,
            model.environment_bindings_dirty, model.revision,
            model.environment_revision, model.runtime_revision,
            haskey(model.source_adapter.object_ids_by_node, node),
        ))
    end
    model = CompositeModel(root;
        id=node -> begin
            active[] = node
            record(:id, node)
            MultiScaleTreeGraph.node_id(node)
        end,
        status=node -> begin
            node === root && return nothing
            record(:status, node)
            if MultiScaleTreeGraph.node_id(node) == 3
                failure === :status && error("intentional status failure")
                if mutate
                    model_object(owner[], 2).name = "changed later"
                    update_geometry!(owner[], 2, :changed_later)
                end
                if replace_prior
                    replaced[] = model_status(owner[], 2)
                    replacement[] = Status(signal=Float32(99), node=:replacement)
                    PlantSimEngine._replace_model_object_status!(owner[], ObjectId(2), replacement[])
                end
            end
            node[:written_by_adapter] = MultiScaleTreeGraph.node_id(node)
            source
        end,
        scale=node -> (record(:scale, node); MultiScaleTreeGraph.symbol(node)),
        kind=node -> (record(:kind, node); nothing),
        species=node -> (record(:species, node); nothing),
        name=node -> (record(:name, node); "adapted name"),
        geometry=node -> (record(:geometry, node); (MultiScaleTreeGraph.node_id(node),)),
        type_promotion=Dict(Float64 => Float32),
        status_transform=(variable, value) -> begin
            record(:transform, active[]; variable=variable)
            failure === :transform && MultiScaleTreeGraph.node_id(active[]) == 3 &&
                variable === :signal && error("intentional transform failure")
            transform_node && variable === :node ? :transformed_node : value
        end,
        instances=(ObjectInstance(:tree,
            CompositeModelTemplate(; kind=:tree, species=:tree_species); root=1),),
        environment=(duration=Hour(1),),
    )
    PlantSimEngine.Advanced.refresh_environment_bindings!(model)
    owner[] = model
    return (; root, model, trace, payload, nested, source, replaced, replacement)
end

function _grouped_first(root)
    return (parent=root, link=:/, symbol=:Cycle, scale=1,
        attributes=(signal=1.0,), initial_status=(signal=3.0, node=:ignored),
        kind=:explicit, name="first")
end

@testset "grouped births match scalar callback observations and canonical identities" begin
    scalar = _grouped_creation_fixture(; mutate=true)
    grouped = _grouped_creation_fixture(; mutate=true)
    first_status = add_organ!(scalar.root, scalar.model, :/, :Cycle, 1;
        attributes=(signal=1.0,), initial_status=(signal=3.0, node=:ignored),
        kind=:explicit, name="first")
    second = add_organ!(first_status.node, scalar.model, :/, :Zone, 2;
        initial_status=(signal=4.0,))
    creations = add_organs!(grouped.model, (
        _grouped_first(grouped.root),
        (parent=OrganParent(1), link=:/, symbol=:Zone, scale=2,
            initial_status=(signal=4.0,)),
    ))
    @test creations isa Tuple
    actual = map(creation -> creation.status, creations)
    @test map(creation -> creation.node, creations) === map(status -> status.node, actual)
    @test grouped.trace == scalar.trace
    second_id_event = only(filter(event -> event[1] === :id && event[2] == 3, grouped.trace))
    @test second_id_event[4] == [ObjectId(1), ObjectId(2)]
    @test length(second_id_event[6]) == 1
    @test second_id_event[7] == [ObjectId(2)]
    @test !last(second_id_event)
    @test _grouped_snapshots(grouped.model) == _grouped_snapshots(scalar.model)
    @test only(grouped.model.lifecycle_delta.added[1:1]).name == "first"
    @test first(grouped.model.lifecycle_delta.added).geometry == (2,)
    @test first(grouped.model.lifecycle_delta.added).children == ()
    @test MultiScaleTreeGraph.parent(actual[2].node) === actual[1].node
    for (status, expected) in zip(actual, (first_status, second))
        @test status.signal === expected.signal
        @test status.signal isa Float32
        @test status.written_by_adapter == MultiScaleTreeGraph.node_id(status.node)
        @test model_status(grouped.model, status.node) === status
        @test source_node(grouped.model, status) === status.node
        @test status.payload === grouped.payload
        @test status.nested === grouped.nested
        @test PlantSimEngine.refvalue(status, :signal) !==
              PlantSimEngine.refvalue(grouped.source, :signal)
    end
    @test PlantSimEngine.refvalue(actual[1], :payload) !==
          PlantSimEngine.refvalue(actual[2], :payload)
    @test grouped.source.signal === 2.0
    @test model_object(grouped.model, actual[1]).kind == :explicit
    @test model_object(grouped.model, actual[2]).kind == :tree
    @test model_object(grouped.model, actual[2]).species == :tree_species
    before = (object_ids(grouped.model), grouped.model.revision,
        length(grouped.model.lifecycle_delta.added))
    @test add_organs!(grouped.model, ()) === ()
    @test before == (object_ids(grouped.model), grouped.model.revision,
        length(grouped.model.lifecycle_delta.added))
end

@testset "grouped failures retain precisely the successful scalar prefix" begin
    for failure in (:reserved, :duplicate_id, :status, :transform)
        scalar = _grouped_creation_fixture(; failure=failure)
        grouped = _grouped_creation_fixture(; failure=failure)
        second_options = failure === :reserved ?
            (attributes=(plantsimengine_status=nothing,),) :
            failure === :duplicate_id ? (id=2,) : NamedTuple()
        first = add_organ!(scalar.root, scalar.model, :/, :Cycle, 1;
            attributes=(signal=1.0,), initial_status=(signal=3.0, node=:ignored),
            kind=:explicit, name="first")
        @test_throws ErrorException add_organ!(first.node, scalar.model, :/, :Zone, 2;
            second_options...)
        @test_throws ErrorException add_organs!(grouped.model, (
            _grouped_first(grouped.root),
            (; parent=OrganParent(1), link=:/, symbol=:Zone, scale=2, second_options...),
            (parent=grouped.root, link=:+, symbol=:Unreached, scale=1),
        ))
        @test grouped.trace == scalar.trace
        @test object_ids(grouped.model) == object_ids(scalar.model) == [ObjectId(1), ObjectId(2)]
        @test _grouped_tree_ids(grouped.root) == _grouped_tree_ids(scalar.root)
        @test _grouped_snapshots(grouped.model) == _grouped_snapshots(scalar.model)
        @test grouped.model.source_adapter.max_node_id[] == scalar.model.source_adapter.max_node_id[]
        @test length(grouped.model.source_adapter.object_ids_by_node) == 2
        @test length(grouped.model.source_adapter.nodes_by_object_id) == 2
        @test Set(keys(grouped.model.status_conversion_records)) ==
              Set(keys(scalar.model.status_conversion_records))
    end
end

@testset "grouped parent references and record validation are reached in order" begin
    for invalid_parent in (OrganParent(0), OrganParent(2), OrganParent(3))
        fixture = _grouped_creation_fixture()
        @test_throws ArgumentError add_organs!(fixture.model, (
            _grouped_first(fixture.root),
            (parent=invalid_parent, link=:/, symbol=:Zone, scale=2),
        ))
        @test object_ids(fixture.model) == [ObjectId(1), ObjectId(2)]
        @test fixture.model.source_adapter.max_node_id[] == 2
    end
    fixture = _grouped_creation_fixture()
    @test_throws ArgumentError add_organs!(fixture.model, (_grouped_first(fixture.root), 17))
    @test object_ids(fixture.model) == [ObjectId(1), ObjectId(2)]
    fixture = _grouped_creation_fixture()
    @test_throws UndefKeywordError add_organs!(fixture.model, (
        _grouped_first(fixture.root), (parent=OrganParent(1), link=:/, scale=2),
    ))
    @test object_ids(fixture.model) == [ObjectId(1), ObjectId(2)]
    fixture = _grouped_creation_fixture()
    creations = add_organs!(fixture.model, (
        (parent=fixture.root, link=:/, symbol=:Cycle, scale=1, id=40,
            use_status_adapter=false, initial_status=(signal=8.0,)),
        (parent=OrganParent(1), link=:/, symbol=:Zone, scale=2,
            use_status_adapter=false, initial_status=(signal=9.0,)),
    ))
    statuses = map(creation -> creation.status, creations)
    @test map(status -> object_id(fixture.model, status), statuses) == (ObjectId(40), ObjectId(41))
    @test !any(event -> event[1] === :status, fixture.trace)
    @test !hasproperty(statuses[1], :payload)
    @test statuses[1].signal === Float32(8)
end

@testset "birth records retain physical nodes and original statuses after later replacement" begin
    scalar = _grouped_creation_fixture(; replace_prior=true, transform_node=true)
    grouped = _grouped_creation_fixture(; replace_prior=true, transform_node=true)
    original = add_organ!(scalar.root, scalar.model, :/, :Cycle, 1;
        attributes=(signal=1.0,), initial_status=(signal=3.0, node=:ignored),
        kind=:explicit, name="first")
    original_node = source_node(scalar.model, original)
    second = add_organ!(original_node, scalar.model, :/, :Zone, 2)
    third = add_organ!(original_node, scalar.model, :/, :Zone, 2)
    creations = add_organs!(grouped.model, (
        _grouped_first(grouped.root),
        (parent=OrganParent(1), link=:/, symbol=:Zone, scale=2),
        (parent=OrganParent(1), link=:/, symbol=:Zone, scale=2),
    ))
    @test grouped.trace == scalar.trace
    @test scalar.replaced[] === original
    @test creations[1].status === grouped.replaced[]
    @test propertynames(creations[1].status) == propertynames(original)
    @test creations[1].status.signal === original.signal
    @test creations[1].status.node === :transformed_node
    @test MultiScaleTreeGraph.node_id(creations[1].node) == 2
    @test model_status(grouped.model, creations[1].node) === grouped.replacement[]
    @test model_status(scalar.model, original_node) === scalar.replacement[]
    @test_throws ArgumentError object_id(grouped.model, creations[1].status)
    @test MultiScaleTreeGraph.parent(creations[2].node) === creations[1].node
    @test MultiScaleTreeGraph.parent(creations[3].node) === creations[1].node
    @test creations[2].status.signal === second.signal
    @test creations[3].status.signal === third.signal
end

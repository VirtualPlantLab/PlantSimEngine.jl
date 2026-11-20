module ExplicitOrganStatusTests
using PlantSimEngine, Test
import MultiScaleTreeGraph as MTG
const PSE = PlantSimEngine

PSE.@process "explicit_organ_status" verbose=false
struct Probe{T} <: AbstractExplicit_Organ_StatusModel
    ambient::T
end
PSE.inputs_(model::Probe{T}) where {T} = (seed=Required(T), ambient=Default(model.ambient))
PSE.outputs_(::Probe{T}) where {T} = (value=zero(T), payload=T[])
PSE.run!(::Probe, status, environment, constants, context) =
    (status.value = status.seed + status.ambient; nothing)

function fixture(::Type{T}=Float32) where {T}
    root = MTG.Node(1, MTG.NodeMTG(:/, :Scene, 1, 0), (note="scene",))
    MTG.Node(2, root, MTG.NodeMTG(:+, :Leaf, 1, 1), (note="existing", seed=T(1)))
    calls = Ref(0)
    import_status(node) = begin
        calls[] += 1
        MTG.symbol(node) === :Leaf ? Status(seed=node[:seed], payload=T[0]) : nothing
    end
    model = CompositeModel(root; status=import_status,
        applications=(ModelSpec(Probe(T(2)); name=:probe, on=Many(scale=:Leaf)),))
    simulation = run!(model; steps=0, outputs=:none)
    return (; root, model, simulation, calls)
end
function ownership_snapshot(data)
    adapter = data.model.source_adapter
    return (ids=object_ids(data.model), max_id=adapter.max_node_id[],
        tree_next_id=MTG.new_id(data.root),
        children=copy(MTG.children(data.root)), forward=copy(adapter.object_ids_by_node),
        reverse=copy(adapter.nodes_by_object_id), added=length(data.model.lifecycle_delta.added),
        conversion_records=copy(data.model.status_conversion_records))
end

@testset "explicit scientific data share references and leave metadata on the MTG" begin
    for T in (Float32, BigFloat)
        data = fixture(T)
        imports = data.calls[]
        payload = T[3, 4]
        given = Status(seed=T(3), payload=payload)
        seed_ref, payload_ref = PSE.refvalue(given, :seed), PSE.refvalue(given, :payload)
        newborn = add_organ!(data.root, data.model, :+, :Leaf, 1;
            attributes=(note="annotation", geometry_cache=[1, 2], seed=T(99)),
            initial_status=given)
        node = source_node(data.model, newborn)
        @test data.calls[] == imports
        @test newborn !== given
        @test PSE.refvalue(newborn, :seed) === seed_ref
        @test PSE.refvalue(newborn, :payload) === payload_ref
        @test newborn.payload === payload
        @test newborn.seed == T(3)
        @test !hasproperty(newborn, :node) && !hasproperty(newborn, :note)
        @test !hasproperty(newborn, :geometry_cache)
        @test MTG.node_attributes(node)[:note] == "annotation"
        @test node[:seed] == T(99)
        @test model_status(data.model, node) === newborn
        @test_throws ArgumentError object_id(data.model, given)
        continue!(data.simulation; steps=0)
        @test newborn.ambient == T(2) && newborn.value == zero(T)
        @test typeof(newborn) === typeof(model_status(data.model, 2))
        @test typeof(newborn.seed) === typeof(newborn.ambient) === typeof(newborn.value) === T
        second = add_organ!(data.root, data.model, :+, :Leaf, 1;
            initial_status=(seed=T(4),))
        third = add_organ!(data.root, data.model, :+, :Leaf, 1;
            initial_status=(seed=T(5),))
        continue!(data.simulation; steps=0)
        @test second.payload == third.payload == T[]
        @test second.payload !== third.payload
        @test second.payload !== model_status(data.model, 2).payload
        @test data.calls[] == imports
        step!(data.simulation)
        @test newborn.value == T(5) && second.value == T(6) && third.value == T(7)
        given.seed = T(7)
        @test newborn.seed == T(7)
        push!(payload, T(5))
        @test newborn.payload == T[3, 4, 5]
    end
end

@testset "invalid explicit data never activate a newborn or reserve its model ID" begin
    data = fixture()
    before = ownership_snapshot(data)
    for (invalid, expected) in ((17, ArgumentError),
        ((plantsimengine_status=nothing,), ErrorException),
        (Status(plantsimengine_status=nothing), ErrorException))
        @test_throws expected add_organ!(data.root, data.model, :+, :Leaf, 1;
            initial_status=invalid)
        @test ownership_snapshot(data) == before
    end
    for initial in ((seed=1.0,), (seed=1f0, unprepared=2f0))
        @test_throws ArgumentError add_organ!(data.root, data.model, :+, :Leaf, 1;
            initial_status=initial)
        @test ownership_snapshot(data) == before
    end
    given = Status(seed=3f0, payload=Float32[])
    newborn = add_organ!(data.root, data.model, :+, :Leaf, 1; initial_status=given)
    after = ownership_snapshot(data)
    @test_throws ArgumentError add_organ!(data.root, data.model, :+, :Leaf, 1; initial_status=given)
    @test ownership_snapshot(data) == after
    @test PSE.refvalue(newborn, :seed) === PSE.refvalue(given, :seed)
end

@testset "a prepared MTG adapter keeps scientific inputs separate from node annotations" begin
    root = MTG.Node(1, MTG.NodeMTG(:/, :Plant, 1, 1),
        (kind=:plant, note="plant", seed=0f0, geometry=Float32[]))
    source = CompositeModel(root;
        applications=(ModelSpec(Probe(2f0); name=:probe, on=Many(scale=:Leaf)),))
    model = PSE._with_object_id_domain(source, ObjectId{Int})
    adapter = model.source_adapter
    @test model.scenario_plan_cache.owner === model
    @test model.scenario_plan_cache.status_manifest === source.scenario_plan_cache.status_manifest
    @test source_node(model, 1) === root
    if isdefined(MTG, :prepare_node_edits)
        @test length(adapter.node_edits) == 1
    end
    simulation = run!(model; steps=0, outputs=:all)
    @test_throws "before binding a simulation" PSE._with_object_id_domain(model)
    geometry = Float32[1, 2]
    given = Status(seed=3f0, payload=Float32[])
    leaf = add_organ!(root, simulation, :+, :Leaf, 2;
        attributes=Dict{Symbol,Any}(:kind=>:expanding, :note=>"first", :geometry=>geometry, :seed=>99f0),
        initial_status=given)
    node = source_node(model, leaf)
    @test only(MTG.children(root)) === node
    @test model_object(model, node).kind === :expanding
    @test model_object(model, node).geometry === geometry
    @test node[:note] == "first" && node[:seed] === 99f0
    @test !hasproperty(leaf, :geometry) && !hasproperty(leaf, :note)
    @test PSE.refvalue(leaf, :seed) === PSE.refvalue(given, :seed)
    bare = add_organ!(root, simulation, :+, :Leaf, 2; initial_status=(seed=4f0,))
    @test isnothing(model_object(model, source_node(model, bare)).kind)
    continue!(simulation; steps=1)
    @test leaf.value === 5f0 && bare.value === 6f0
    @test only(outputs(simulation)[(:probe, object_id(model, leaf), :value)]) == (1.0, 5f0)
end

@testset "new organs inherit declared MTG labels and geometry" begin
    for prepared in (false, true)
        root = MTG.Node(1, MTG.NodeMTG(:/, :Plant, 1, 1), (annotation=:existing,))
        geometry = Float32[1, 2]
        MTG.add_column!(root, :Leaf, :kind, Int; default=3)
        MTG.add_column!(root, :Leaf, :species, Symbol; default=:guineensis)
        MTG.add_column!(root, :Leaf, :name, String; default="young leaf")
        MTG.add_column!(root, :Leaf, :geometry, typeof(geometry); default=geometry)
        model = CompositeModel(root)
        prepared && (model = PSE._with_object_id_domain(model, ObjectId{Int}))
        leaf = add_organ!(root, model, :+, :Leaf, 2)
        object = model_object(model, source_node(model, leaf))
        @test (object.kind, object.species, object.name) == (Symbol(3), :guineensis, "young leaf")
        @test object.geometry === geometry

        MTG.add_column!(root, :Tip, :kind, Int; default=7)
        tip = add_organ!(root, model, :+, :Tip, 2)
        @test model_object(model, source_node(model, tip)).kind === Symbol(7)
        MTG.add_column!(root, :Bud, :kind, Symbol; default=:dormant)
        if prepared && isdefined(MTG, :prepare_node_edits)
            @test_throws "new MTG label type" add_organ!(root, model, :+, :Bud, 2)
            @test isnothing(MTG.get_node(root, 4))
            bud = add_organ!(root, model, :+, :Bud, 2; attributes=(kind=:dormant,))
        else
            bud = add_organ!(root, model, :+, :Bud, 2)
        end
        @test MTG.node_id(source_node(model, bud)) == 4
        @test model_object(model, source_node(model, bud)).kind === :dormant

        fruit = add_organ!(root, model, :+, :Fruit, 2; attributes=(kind=:green,))
        @test model_object(model, source_node(model, fruit)).kind === :green
        @test !hasproperty(fruit, :kind)
    end
end

@testset "a failing MTG accessor preserves a descendant it already attached" begin
    for prepared in (false, true)
        root = MTG.Node(MTG.NodeMTG(:/, :Plant, 1, 1))
        newborn = Ref{typeof(root)}()
        tip = Ref{typeof(root)}()
        function kind(node)
            MTG.symbol(node) === :Leaf || return :plant
            @test MTG.parent(node) === root && only(MTG.children(root)) === node
            newborn[] = node
            tip[] = MTG.Node(MTG.node_id(node) + 1, node, MTG.NodeMTG(:<, :Tip, 1, 2), (;))
            throw(ArgumentError("rejected leaf"))
        end
        model = CompositeModel(root; kind)
        prepared && (model = PSE._with_object_id_domain(model, ObjectId{Int}))
        @test_throws "rejected leaf" add_organ!(root, model, :+, :Leaf, 2)
        @test isnothing(MTG.parent(newborn[])) && isempty(MTG.children(newborn[]))
        @test only(MTG.children(root)) === tip[]
        @test MTG.parent(tip[]) === root && MTG.link(tip[]) === :+
        @test isnothing(MTG.get_node(root, MTG.node_id(newborn[])))
        @test MTG.get_node(root, MTG.node_id(tip[])) === tip[]
        @test_throws ArgumentError object_id(model, newborn[])
        @test object_id(model, root) == ObjectId(MTG.node_id(root))
    end
end

@testset "the initial data grammar has one Status construction path" begin
    payload = Float32[1, 2]
    for source in ((value=3f0, payload=payload), Dict(:value=>3f0, :payload=>payload),
        Dict("value"=>3f0, "payload"=>payload), pairs((value=3f0, payload=payload)))
        status = PSE._organ_status(source)
        @test status.value === 3f0 && status.payload === payload
        @test !hasproperty(status, :node)
    end
    given = Status(value=3f0, payload=payload)
    @test PSE._organ_status(given) === given
    @test isempty(PSE._organ_status(nothing))
    nested = Ref(7)
    status = PSE._organ_status((value=nested,))
    @test PSE.refvalue(status, :value) === nested
    @test status.value == 7
end
end

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

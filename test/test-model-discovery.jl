import InteractiveUtils
using PlantSimEngine, PlantSimEngine.Authoring, Test

module ModelDiscoveryFixture
using PlantSimEngine

abstract type AbstractDiscoveryRoot <: PlantSimEngine.AbstractModel end
abstract type AbstractDiscoveryProcess{T} <: AbstractDiscoveryRoot end
PlantSimEngine.process_(::Type{<:AbstractDiscoveryProcess}) = :model_discovery_fixture

const constructions = Ref(0)
struct DiscoveryModel{T} <: AbstractDiscoveryProcess{T}
    value::T
end
DiscoveryModel() = (constructions[] += 1; DiscoveryModel(1.0))

abstract type AbstractUnprocessedModel <: AbstractDiscoveryRoot end
struct UnprocessedModel <: AbstractUnprocessedModel end

module Nested
import ..ModelDiscoveryFixture: AbstractDiscoveryProcess
struct NestedModel <: AbstractDiscoveryProcess{Float64} end
end

module Peer
import ..ModelDiscoveryFixture: AbstractDiscoveryProcess
struct NestedModel <: AbstractDiscoveryProcess{Float32} end
end

const ModelAlias = DiscoveryModel
const ConcreteAlias = DiscoveryModel{Float32}
const ModuleAlias = Nested
const ImportedModel = Nested.NestedModel
end

function discovery_recursive_reference(module_, root)
    found = Type[]
    for child in InteractiveUtils.subtypes(module_, root)
        push!(found, child)
        append!(found, discovery_recursive_reference(module_, child))
    end
    return found
end

@testset "Model discovery scans nominal definitions once per query" begin
    fixture = ModelDiscoveryFixture
    root = fixture.AbstractDiscoveryRoot
    discover(root) = PlantSimEngine._abstract_model_subtypes_in_modules(
        [fixture, fixture.Nested, fixture], root,
    )
    reference = discovery_recursive_reference(fixture, root)
    discovered = discover(root)
    @test Set(discovered) == Set(reference)
    @test length(discovered) == length(unique(discovered))
    @test discovered == PlantSimEngine._abstract_model_subtypes_in_modules(
        [fixture.Peer, fixture.Nested, fixture], root,
    )
    @test fixture.DiscoveryModel in discovered
    @test fixture.Nested.NestedModel in discovered
    @test fixture.ConcreteAlias ∉ discovered
    @test isempty(discover(fixture.DiscoveryModel{Float32}))

    for T in (Float32, Float64)
        parameterized_root = fixture.AbstractDiscoveryProcess{T}
        @test Set(discover(parameterized_root)) ==
              Set(discovery_recursive_reference(fixture, parameterized_root))
        @test fixture.DiscoveryModel{T} in discover(parameterized_root)
    end

    @test fixture.AbstractDiscoveryProcess in available_processes()
    models = available_models(:model_discovery_fixture)
    @test fixture.DiscoveryModel in models
    @test fixture.Nested.NestedModel in models
    @test filter(type -> nameof(type) === :NestedModel &&
        parentmodule(type) in (fixture.Nested, fixture.Peer), models) == sort(
        [fixture.Nested.NestedModel, fixture.Peer.NestedModel]; by=string,
    )
    @test fixture.UnprocessedModel ∉ available_models()
    @test models == available_models(fixture.AbstractDiscoveryProcess)
    @test models == sort(models; by=type -> string(
        PlantSimEngine._process_name_for_type(type), ".", nameof(type),
    ))
    @test fixture.constructions[] == 0

    Core.eval(fixture, :(struct LateDiscoveryModel <: AbstractDiscoveryProcess{Float32} end))
    @test fixture.LateDiscoveryModel in discover(root)
    @test Set(discover(root)) == Set(discovery_recursive_reference(fixture, root))
    @test fixture.LateDiscoveryModel in available_models(:model_discovery_fixture)
    @test fixture.constructions[] == 0
end

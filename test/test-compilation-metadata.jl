module CompilationMetadataChecks

using PlantSimEngine, Test
const PSE = PlantSimEngine

PSE.@process "compiled_port_metadata" verbose=false
struct PortProbe{C} <: AbstractCompiled_Port_MetadataModel
    declarations::C
end
function PSE.outputs_(model::PortProbe)
    model.declarations[] += 1
    return (value=0.0, scratch=zeros(3))
end
PSE.run!(::PortProbe, status, environment, constants, context) = nothing

@testset "writer matching uses the prepared port schema" begin
    declarations = Ref(0)
    model = CompositeModel(Object(:leaf; scale=:Leaf);
        applications=(ModelSpec(PortProbe(declarations); name=:probe,
            on=Many(scale=:Leaf), output_routing=(scratch=:stream_only,)),))
    simulation = run!(model; steps=0, outputs=:none)
    application = only(simulation.compiled.applications)
    prepared_count = declarations[]
    @test PSE._model_output_names(application) === (:value, :scratch)
    @test PSE._model_canonical_output_names(application) === (:value,)
    for _ in 1:20
        @test PSE._application_writes_object_variable(
            PSE.NoCompiledDistributedOutputs(), application, ObjectId(:leaf), :value)
        @test !PSE._application_writes_object_variable(
            PSE.NoCompiledDistributedOutputs(), application, ObjectId(:missing), :value)
        @test PSE._model_canonical_output_names(application) === (:value,)
    end
    @test declarations[] == prepared_count
end

@testset "shared point queries preserve ownership and cardinality checks" begin
    model = CompositeModel(
        Object(:plant; scale=:Plant),
        Object(:leaf_a; scale=:Leaf, parent=:plant),
        Object(:leaf_b; scale=:Leaf, parent=:plant))
    cache = Dict{Any,Vector{ObjectId}}()
    point = One(Ancestor(scale=:Plant); scale=:Plant)
    matcher = PSE._compile_selector_matcher(model, point)
    first_ids = PSE._cached_dependency_object_ids(cache, model, point, matcher, ObjectId(:leaf_a))
    @test first_ids == [ObjectId(:plant)]
    empty!(first_ids)
    next_ids = PSE._cached_dependency_object_ids(cache, model, point, matcher, ObjectId(:leaf_a))
    @test next_ids == [ObjectId(:plant)]
    @test next_ids !== only(values(cache))
    many = Many(SceneScope(); scale=:Leaf)
    ids = PSE._cached_dependency_object_ids(cache, model, many,
        PSE._compile_selector_matcher(model, many), ObjectId(:plant))
    @test ids == [ObjectId(:leaf_a), ObjectId(:leaf_b)]
    for selector in (One(SceneScope(); scale=:Leaf), OptionalOne(SceneScope(); scale=:Leaf))
        @test_throws Exception PSE._cached_dependency_object_ids(cache, model, selector,
            PSE._compile_selector_matcher(model, selector), ObjectId(:plant))
    end
end

end

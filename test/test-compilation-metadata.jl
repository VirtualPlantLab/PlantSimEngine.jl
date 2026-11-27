module CompilationMetadataChecks

using PlantSimEngine, Test
const PSE = PlantSimEngine

function application_identity_from_membership(applications::Vector{PSE.CompiledModelApplication})
    application = first(applications)
    return (application.id, application.process)
end

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
    erased = PSE.CompiledModelApplication[simulation.compiled.applications...]
    @test (@inferred application_identity_from_membership(erased)) ==
          (:probe, :compiled_port_metadata)
    @test PSE._model_output_names(application) === (:value, :scratch)
    @test PSE._model_canonical_output_names(application) === (:value,)
    for _ in 1:20
        @test PSE._application_writes_object_variable(
            PSE.NoCompiledDistributedOutputs(), application, ObjectId(:leaf), :value)
        @test !PSE._application_writes_object_variable(
            PSE.NoCompiledDistributedOutputs(), application, ObjectId(:missing), :value)
        @test PSE._model_canonical_output_names(application) === (:value,)
        for variable in (:value, :scratch)
            @test PSE._matches_input_source_writer(ObjectId(:leaf), variable,
                nothing, :probe, simulation.compiled.applications_by_id,
                simulation.compiled.distributed_outputs,
                simulation.compiled.applications_by_object)
        end
    end
    @test declarations[] == prepared_count
end

@testset "shared point queries preserve ownership and cardinality checks" begin
    model = CompositeModel(
        Object(:plant; scale=:Plant),
        Object(:leaf_a; scale=:Leaf, parent=:plant),
        Object(:leaf_b; scale=:Leaf, parent=:plant))
    cache = PSE._input_query_cache(model.registry.objects, 2)
    point = One(Ancestor(scale=:Plant); scale=:Plant)
    plan = (selector=point, matcher=PSE._compile_selector_matcher(model, point))
    first_ids = PSE._input_route_source_ids(cache, 1, model, plan, ObjectId(:leaf_a))
    @test first_ids == [ObjectId(:plant)]
    empty!(first_ids)
    next_ids = PSE._input_route_source_ids(cache, 1, model, plan, ObjectId(:leaf_a))
    @test next_ids == [ObjectId(:plant)]
    @test next_ids !== cache[1]
    many = Many(SceneScope(); scale=:Leaf)
    many_plan = (selector=many, matcher=PSE._compile_selector_matcher(model, many))
    ids = PSE._input_route_source_ids(cache, 2, model, many_plan, ObjectId(:plant))
    @test ids == [ObjectId(:leaf_a), ObjectId(:leaf_b)]
    for selector in (One(SceneScope(); scale=:Leaf), OptionalOne(SceneScope(); scale=:Leaf))
        invalid_plan = (selector=selector, matcher=PSE._compile_selector_matcher(model, selector))
        @test_throws Exception PSE._input_route_source_ids(nothing, 0, model,
            invalid_plan, ObjectId(:plant))
    end
end

end

module InputSourceMatchingChecks

using PlantSimEngine, Test
const PSE = PlantSimEngine

PSE.@process "source_match_writer" verbose=false
PSE.@process "source_match_alternative" verbose=false
struct Writer{T} <: AbstractSource_Match_WriterModel
    value::T
end
struct AlternativeWriter{T} <: AbstractSource_Match_AlternativeModel
    value::T
end
PSE.inputs_(::Union{Writer,AlternativeWriter}) = NamedTuple()
PSE.outputs_(model::Union{Writer,AlternativeWriter}) = (x=zero(model.value),)
PSE.run!(model::Union{Writer,AlternativeWriter}, status, environment, constants, context) =
    (status.x = model.value; nothing)

function matching_fixture()
    names = (:a, :b, :c, :d, :e, :f)
    models = (Writer(1f0), Writer(2.0), Writer(Int8(3)), Writer(Int16(4)),
        Writer(Int32(5)), AlternativeWriter(Int64(6)))
    objects = ntuple(index -> Object(index; status=Status(x=models[index].value)), 6)
    applications = ntuple(index -> ModelSpec(models[index];
        name=names[index], on=One(id=index)), 6)
    simulation = run!(CompositeModel(objects...; applications); steps=0, outputs=:none)
    compiled = simulation.compiled
    owner(name, index) = PSE.CompiledWriterOwner(index, name, ObjectId(index), nothing, :local)
    ownership = Dict(
        (ObjectId(1), :x) => [owner(:a, 1), owner(:b, 2), owner(:c, 3),
            owner(:d, 4), owner(:missing, 99)],
        (ObjectId(2), :x) => [owner(:b, 2), owner(:a, 1), owner(:e, 5), owner(:f, 6)],
    )
    distributed = PSE.CompiledDistributedOutputs((), Dict(), ownership, Dict())
    return simulation, distributed
end

function matched(compiled, distributed, ids; process=nothing, application=nothing,
    potential=(), allow_empty=false)
    return PSE._matching_input_source_applications(compiled.applications_by_object,
        ObjectId.(ids), :x, process, application, distributed, potential;
        applications_by_id=compiled.applications_by_id, allow_empty)
end

@testset "local and ownership matching preserve first occurrence order" begin
    simulation, distributed = matching_fixture()
    compiled = simulation.compiled
    references = [PSE.refvalue(model_status(simulation.model, id), :x) for id in 1:6]
    @test compiled.applications_by_id isa PSE.CompiledMetadataTable
    @test matched(compiled, distributed, (1, 2)) == [:a, :b, :c, :d, :e, :f]
    @test matched(compiled, distributed, (2, 1)) == [:b, :a, :e, :f, :c, :d]
    @test matched(compiled, distributed, (1, 2); application=:c) == [:c]
    alternative = compiled.applications_by_id[:f]
    @test matched(compiled, distributed, (1, 2); process=alternative.process) == [:f]
    @test PSE._matches_input_source_writer(ObjectId(2), :x, alternative.process,
        nothing, compiled.applications_by_id, distributed, compiled.applications_by_object)
    @test !PSE._matches_input_source_writer(ObjectId(1), :x, nothing, :missing,
        compiled.applications_by_id, distributed, compiled.applications_by_object)
    @test matched(compiled, distributed, (1, 2); potential=(:c,)) == [:c]
    # The planned producer is absent from the first object's local/remote
    # ownership and present only on the second object.
    @test matched(compiled, distributed, (1, 2); potential=(:f,)) == [:f]
    @test isempty(matched(compiled, distributed, (1, 2);
        application=:missing, potential=(:missing,), allow_empty=true))
    @test_throws ErrorException matched(compiled, distributed, (1, 2);
        application=:missing, potential=(:missing,))
    @test [model_status(simulation.model, id).x for id in 1:6] == [1, 2, 3, 4, 5, 6]
    @test all(PSE.refvalue(model_status(simulation.model, id), :x) === references[id]
        for id in 1:6)
    @test current_step(simulation) == 0
end

@testset "an already matched owner still requires its distributed index" begin
    _, distributed = matching_fixture()
    matches = [:a]
    failure = try
        PSE._append_distributed_input_source_applications!(matches, distributed,
            ObjectId(1), :x, nothing, nothing, nothing)
        nothing
    catch exception
        exception
    end
    @test failure isa ErrorException
    @test sprint(showerror, failure) ==
        "Distributed output producer matching requires the compiled application index."
    @test matches == [:a]
    @test PSE._append_distributed_input_source_applications!(matches, distributed,
        ObjectId(7), :x, nothing, nothing, nothing) === matches
end

@testset "planned singleton matching retains a real newborn partial overlay" begin
    simulation, distributed = matching_fixture()
    compiled = simulation.compiled
    newborn = register_object!(simulation.model, Object(7; status=Status(x=7f0)))
    reference = PSE.refvalue(newborn.status, :x)
    partial = PSE._partial_model_application(compiled.applications_by_id[:a],
        ObjectId[ObjectId(7)])
    overlay = PSE._ApplicationsByObjectOverlay(compiled.applications_by_object,
        Dict(ObjectId(7) => PSE.CompiledModelApplication[partial]))
    @test !(ObjectId(7) in compiled.applications_by_id[:a].target_ids)
    @test PSE._matching_input_source_applications(overlay, ObjectId[ObjectId(7)],
        :x, nothing, nothing, PSE.NoCompiledDistributedOutputs(), (:a,);
        applications_by_id=compiled.applications_by_id) == [:a]
    @test PSE._matches_input_source_writer(ObjectId(7), :x, nothing, :a,
        compiled.applications_by_id, PSE.NoCompiledDistributedOutputs(), overlay)
    @test PSE._final_canonical_source_application(overlay, ObjectId[ObjectId(7)],
        [:f, :a], :x; applications_by_id=compiled.applications_by_id) == [:a]
    @test PSE._final_canonical_source_application(overlay, ObjectId[ObjectId(7)],
        [:f, :a], :x, distributed; applications_by_id=compiled.applications_by_id) == [:a]
    unmatched = [:f, :b]
    @test PSE._final_canonical_source_application(overlay, ObjectId[ObjectId(7)],
        unmatched, :x; applications_by_id=compiled.applications_by_id) === unmatched
    @test unmatched == [:f, :b]
    @test newborn.status.x === 7f0
    @test PSE.refvalue(newborn.status, :x) === reference
    @test current_step(simulation) == 0
end

@testset "one producer on several local objects is recorded once in first occurrence order" begin
    model = CompositeModel(
        Object(1; kind=:local, status=Status(x=1f0)),
        Object(2; kind=:local, status=Status(x=2f0)),
        Object(3; kind=:local, status=Status(x=3f0)),
        Object(4; status=Status(x=4.0));
        applications=(
            ModelSpec(Writer(1f0); name=:shared, on=Many(kind=:local)),
            ModelSpec(AlternativeWriter(4.0); name=:other, on=One(id=4)),
        ))
    simulation = run!(model; steps=0, outputs=:none)
    compiled = simulation.compiled
    shared = compiled.applications_by_id[:shared]
    other = compiled.applications_by_id[:other]
    shared_owner = PSE.CompiledWriterOwner(shared.slot, :shared, ObjectId(1), nothing, :local)
    other_owner = PSE.CompiledWriterOwner(other.slot, :other, ObjectId(4), nothing, :distributed)
    ownership = Dict(
        (ObjectId(1), :x) => [shared_owner, other_owner],
        (ObjectId(2), :x) => [shared_owner],
        (ObjectId(3), :x) => [other_owner, shared_owner],
    )
    distributed = PSE.CompiledDistributedOutputs((), Dict(), ownership, Dict())
    @test shared.target_ids == ObjectId.([1, 2, 3])
    @test matched(compiled, PSE.NoCompiledDistributedOutputs(), (2, 1, 3, 1)) == [:shared]
    @test matched(compiled, distributed, (2, 1, 3, 1)) == [:shared, :other]
    @test matched(compiled, distributed, (4, 3, 2, 1)) == [:other, :shared]
    @test matched(compiled, distributed, (2, 1, 3, 1); process=shared.process) == [:shared]
    @test matched(compiled, distributed, (2, 1, 3, 1); application=:other) == [:other]

    newborn = register_object!(model, Object(5; kind=:local, status=Status(x=5f0)))
    reference = PSE.refvalue(newborn.status, :x)
    partial = PSE._partial_model_application(shared, ObjectId[ObjectId(5)])
    overlay = PSE._ApplicationsByObjectOverlay(compiled.applications_by_object,
        Dict(ObjectId(5) => PSE.CompiledModelApplication[partial]))
    @test PSE._matching_input_source_applications(overlay, ObjectId.([5, 2, 1, 3]),
        :x, nothing, nothing, distributed;
        applications_by_id=compiled.applications_by_id) == [:shared, :other]
    @test newborn.status.x === 5f0
    @test PSE.refvalue(newborn.status, :x) === reference
    @test [model_status(model, id).x for id in 1:4] == [1, 2, 3, 4]
    @test current_step(simulation) == 0
end

end

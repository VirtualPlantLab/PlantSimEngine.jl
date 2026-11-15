module FixedStatusManifestChecks
using PlantSimEngine, Test
const PSE = PlantSimEngine
PSE.@process "fixed_status_manifest_source" verbose=false
PSE.@process "fixed_status_manifest_reader" verbose=false

struct Source{X,Y,C} <: AbstractFixed_Status_Manifest_SourceModel
    x::X
    y::Y
    calls::C
end
function PSE.outputs_(source::Source)
    source.calls[] += 1
    return (x=source.x, y=source.y)
end
PSE.run!(::Source, status, environment, constants, context) = nothing
struct Reader <: AbstractFixed_Status_Manifest_ReaderModel end
PSE.inputs_(::Reader) = (x=Default(0f0),)
PSE.outputs_(::Reader) = (;)
PSE.run!(::Reader, status, environment, constants, context) = nothing

@testset "future declarations bound storage without cross-config numeric admission" begin
    a = Source(1f0, 2.0, Ref(0))
    b = Source(1.0, 2f0, Ref(0))
    model = CompositeModel(Object(:scene; scale=:Scene, status=Status(keep=3f0));
        applications=(ModelSpec(a; name=:a, on=Many(scale=:Leaf, kind=:a)),
            ModelSpec(b; name=:b, on=Many(scale=:Leaf, kind=:b))))
    manifest = model.scenario_plan_cache.status_manifest
    @test manifest isa PSE.PreparedStatusManifest
    S = manifest.status_type
    names = PSE._status_schema_names(S)
    refs = PSE._status_schema_references(S)
    @test (:x in names) && (:y in names) && (:keep in names)
    @test Base.RefValue{Float32} <: fieldtype(refs, findfirst(isequal(:x), names))
    @test Base.RefValue{Float64} <: fieldtype(refs, findfirst(isequal(:x), names))
    @test a.calls[] == b.calls[] == 1

    # This pair fits the GLOBAL slot unions, but no configured kind=:a family.
    bad = Object(:bad; scale=:Leaf, kind=:a, status=Status(x=9f0, y=9f0))
    before = length(model.registry.objects)
    @test_throws ArgumentError register_object!(model, bad)
    @test length(model.registry.objects) == before
    @test !haskey(model.registry.objects, ObjectId(:bad))
    good = Object(:good; scale=:Leaf, kind=:a, status=Status(x=9f0, y=9.0))
    x = PSE.refvalue(good.status, :x)
    register_object!(model, good)
    @test typeof(model_status(model, :good)) === S
    @test PSE.refvalue(model_status(model, :good), :x) === x
    @test a.calls[] == b.calls[] == 1
end

@testset "One uses the prospective source reference witness before first birth" begin
    source = Source(1.0, 2.0, Ref(0))
    model = CompositeModel(Object(:scene; scale=:Scene);
        applications=(ModelSpec(source; name=:source, on=Many(scale=:Leaf)),
            ModelSpec(Reader(); name=:reader, on=One(scale=:Scene),
                inputs=(x=One(scale=:Leaf),))))
    preparation = model.scenario_plan_cache
    plan = only(record for record in preparation.program.input_records
        if record isa PSE.CompiledModelInputPlan && record.application_id === :reader)
    @test plan.reference_types === Tuple{Base.RefValue{Float64}}
    @test source.calls[] == 1
    leaf = Object(:first; scale=:Leaf, status=Status(x=4.0, y=5.0))
    x = PSE.refvalue(leaf.status, :x)
    register_object!(model, leaf)
    run!(model; steps=1, outputs=:none)
    @test PSE.refvalue(model_status(model, :scene), :x) === x
    @test source.calls[] == 2 # ordinary fresh staging read, no manifest replay
end
end

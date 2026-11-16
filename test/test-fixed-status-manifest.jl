module FixedStatusManifestChecks
using Dates, PlantSimEngine, Test
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
@testset "RAW evidence cardinality does not alter an otherwise equal prepared owner" begin
    make = function (leaves)
        source = Source(1.0,2.0,Ref(0))
        objects = Object[Object(:scene;scale=:Scene)]
        leaves && push!(objects,Object(:leaf;scale=:Leaf,parent=:scene,
            status=Status(x=3.0,y=4.0)))
        return CompositeModel(objects...;applications=(
            ModelSpec(source;name=:source,on=Many(scale=:Leaf)),))
    end
    populated, empty = make(true), make(false)
    left = PSE._prepared_status_manifest(populated)
    right = PSE._prepared_status_manifest(empty)
    @test left.status_type === right.status_type
    owner_type_equal = typeof(left) === typeof(right)
    @test owner_type_equal
    model_type_equal = typeof(populated) === typeof(empty)
    @test model_type_equal
    @test length(left.raw_families) == 1 # Even redundant evidence is retained.
    @test isempty(right.raw_families)
    @test only(left.raw_families).names == [:x,:y]
    @test only(left.raw_families).reference_types == [Base.RefValue{Float64},Base.RefValue{Float64}]
end

@testset "nominal RAW data retains unique classes, exact aliases and force provenance" begin
    storage = Float32[3]
    external = Ref(storage,1)
    initial = Status((x=Ref{Real}(5f0),y=Ref(4.0),external=external))
    source = Source(1.0,2.0,Ref(0))
    model = CompositeModel(Object(:leaf;scale=:Leaf,status=initial);
        applications=(ModelSpec(source;name=:source,on=Many(scale=:Leaf)),))
    raw = PSE._prepared_status_manifest(model).raw_families
    @test length(raw) == 1
    @test only(raw).names == [:x,:y,:external]
    @test PSE.refvalue(model_status(model,:leaf),:external) === external
    late_storage = Float32[7]
    late = Status((x=Ref{Real}(9f0),y=Ref(8.0),external=Ref(late_storage,1)))
    late_cells = PSE.refvalues(late)
    register_object!(model,Object(:late;scale=:Leaf,status=late))
    official = model_status(model,:late)
    @test all(PSE.refvalue(official,name) === reference for
        (name,reference) in zip((:x,:y,:external),late_cells))
    Advanced.refresh_bindings!(model;force=true)
    @test PSE._prepared_status_manifest(model).raw_families === raw
    @test model_status(model,:late) === official
    @test PSE.refvalue(official,:external) === late_cells[3]
    late_storage[1] = 11f0
    @test official.external === 11f0
end

# Environment variable names are configuration data, not status permissions.
struct EnvironmentNamedSource{T} <: AbstractFixed_Status_Manifest_SourceModel
    variable::Symbol
    initial::T
end
PSE.inputs_(::EnvironmentNamedSource) = NamedTuple()
PSE.outputs_(model::EnvironmentNamedSource) = (x=model.initial,)
PSE.environment_inputs_(model::EnvironmentNamedSource) =
    NamedTuple{(model.variable,)}((model.initial,))
PSE.run!(model::EnvironmentNamedSource, status, environment, constants, context) =
    (status.x = getproperty(environment, model.variable); nothing)

@testset "environment remapping does not alter the status permission owner schema" begin
    spec(variable) = ModelSpec(EnvironmentNamedSource(variable, 0f0);
        name=:source, on=One(id=:leaf))
    supplied = Status(x=9f0)
    reference = PSE.refvalue(supplied, :x)
    model = CompositeModel(Object(:leaf; status=supplied); applications=(spec(:T),),
        environment=(duration=Hour(1), T=3f0, U=7f0))
    official = model_status(model, :leaf)
    manifest = PSE._prepared_status_manifest(model)
    first = Advanced.refresh_bindings!(model)
    model.applications[1] = spec(:U)
    second = Advanced.refresh_bindings!(model; force=true)
    current = PSE._prepared_status_manifest(model)
    @test first.model === second.model === model
    @test current.status_type === manifest.status_type
    @test typeof(current) === typeof(manifest)
    @test model.registry.objects.catalog.status_manifest === current
    @test model_status(model, :leaf) === official
    @test PSE.refvalue(official, :x) === reference
    @test official.x === 9f0
    @test fieldnames(typeof(only(current.authored))) ==
        (:slot, :id, :target_matcher, :object_slots)
    run!(model; steps=1, outputs=:none)
    @test model_status(model, :leaf) === official
    @test PSE.refvalue(official, :x) === reference
    @test official.x === 7f0
end

@testset "projected admission preserves the real configured override slots" begin
    base = Source(1f0, 2.0, Ref(0))
    replacement = Source(1.0, 2f0, Ref(0))
    template = CompositeModelTemplate((ModelSpec(base; name=:source,
        on=Many(scale=:Leaf)),))
    instance = ObjectInstance(:stand, template; root=Object(:plant; scale=:Plant),
        objects=(Object(:future_override; scale=:Leaf, parent=:plant),),
        object_overrides=(Override(object=:future_override, application=:source,
            model=replacement),))
    model = CompositeModel(instance)
    preparation = model.scenario_plan_cache
    manifest = PSE._prepared_status_manifest(model)
    authored = only(preparation.authored)
    projected = only(manifest.authored)
    owner = PSE._application_model_overrides(authored)
    counts = (base.calls[], replacement.calls[])
    @test projected.object_slots === owner.object_slots
    @test projected.slot == authored.slot
    @test projected.id === authored.id
    @test projected.target_matcher === authored.target_matcher
    for (id, expected) in ((ObjectId(:future_override), 2), (ObjectId(:base), 1))
        @test PSE._prepared_status_variant_slot(projected, id) == expected
        @test PSE._prepared_status_variant_slot(projected, id) ==
            PSE._prepared_status_variant_slot(authored, id)
    end
    @test (base.calls[], replacement.calls[]) == counts
    # Mount the genuine target first, then reuse its vacant identity. Its None
    # status contributes no RAW x/y cells; birth rights still come from ports.
    @test model_status(model, :future_override) === nothing
    remove_object!(model, :future_override)
    @test !haskey(model.registry.objects, ObjectId(:future_override))
    @test projected.object_slots === owner.object_slots
    @test owner.object_slots[ObjectId(:future_override)] == 2
    @test (base.calls[], replacement.calls[]) == counts
    wrong = Object(:future_override; scale=:Leaf, parent=:plant, status=Status(x=3f0, y=4f0))
    @test_throws ArgumentError register_object!(model, wrong)
    @test !haskey(model.registry.objects, wrong.id)
    supplied = Status(x=3.0, y=4f0)
    reference = PSE.refvalue(supplied, :x)
    register_object!(model, Object(:future_override; scale=:Leaf, parent=:plant, status=supplied))
    @test PSE.refvalue(model_status(model, :future_override), :x) === reference
    register_object!(model, Object(:base; scale=:Leaf, parent=:plant, status=Status(x=5f0, y=6.0)))
    @test model_status(model, :base).x === 5f0
    @test (base.calls[], replacement.calls[]) == counts
end

end

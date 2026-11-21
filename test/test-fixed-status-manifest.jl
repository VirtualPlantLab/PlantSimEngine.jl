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

@testset "independent preparations keep the same slots for supplied fields" begin
    function prepare_leaves(reverse_order)
        value = Ref(3f0)
        data = reverse_order ? (; zeta=Ref(7), alpha=value) : (; alpha=value, zeta=Ref(7))
        leaf = Object(:leaf; scale=:Leaf, status=Status(data))
        soil = Object(:soil; scale=:Soil, status=Status(depth=2.0))
        objects = reverse_order ? (leaf, soil) : (soil, leaf)
        model = CompositeModel(objects...; applications=(
            ModelSpec(Source(1f0, 2.0, Ref(0)); name=:source, on=Many(scale=:Leaf)),))
        return model, value
    end
    a, original = prepare_leaves(false)
    b, other = prepare_leaves(true)
    schema(m) = PSE._prepared_status_manifest(m).status_type
    @test schema(a) === schema(b)
    @test PSE._status_schema_names(schema(a)) == (:x, :y, :alpha, :depth, :zeta)
    @test PSE.refvalue(model_status(a, :leaf), :alpha) === original
    @test PSE.refvalue(model_status(b, :leaf), :alpha) === other
    @test typeof(PSE.refvalue(model_status(b, :leaf), :zeta)) === Base.RefValue{Int}
end

function _wide_leaf_admission_bytes(model, leaf, status)
    return @allocated PSE._validate_prepared_initial_status(model, leaf, status, leaf.parent)
end

@testset "admission reads a wide prepared leaf status without copying it for each field" begin
    names = ntuple(i -> Symbol(:raw_, i), 160)
    cells = ntuple(i -> isodd(i) ? Ref(i) : Ref(Float64(i)), length(names))
    scene = Object(:scene; scale=:Scene, status=Status(NamedTuple{names}(cells)))
    old = Object(:old; scale=:Leaf, parent=:scene, status=Status(x=2.0))
    model = CompositeModel(scene, old; applications=(
        ModelSpec(Source(0.0, 0.0, Ref(0)); name=:leaf_source, on=Many(scale=:Leaf)),))
    supplied = copy(model_status(model, :old))
    leaf = Object(:new; scale=:Leaf, parent=:scene, status=supplied)
    _wide_leaf_admission_bytes(model, leaf, supplied)
    @test _wide_leaf_admission_bytes(model, leaf, supplied) <= 4096
    @test register_object!(model, leaf) === leaf
    @test PSE.refvalue(model_status(model, :new), :x) === PSE.refvalue(supplied, :x)
end

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
@testset "repeated applications share the prepared admission schema" begin
    function scene(kinds)
        applications = [ModelSpec(Source(1.0, 2.0, Ref(0)); name=kind,
            on=Many(scale=:Leaf, kind=kind)) for kind in kinds]
        return CompositeModel(Object(:scene; scale=:Scene); applications)
    end

    small = scene((:sun,))
    large = scene((:sun, :shade))
    @test typeof(PSE._prepared_status_manifest(small)) === typeof(PSE._prepared_status_manifest(large))

    leaf = Object(:leaf; scale=:Leaf, kind=:shade, status=Status(x=3.0))
    reference = PSE.refvalue(leaf.status, :x)
    @test_throws ArgumentError register_object!(small, leaf)
    @test !haskey(small.registry.objects, leaf.id)
    register_object!(large, leaf)
    @test PSE.refvalue(model_status(large, :leaf), :x) === reference
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

    # A real no-change conversion receipt must not grant RefValue32 when
    # the only configured RAW implementation is an external RefArray32.
    transform_calls = Ref(0)
    preserve_type = (variable, value) -> (transform_calls[] += 1; value)
    external_only = Ref(Float32[3], 1)
    no_change = CompositeModel(Object(:external;
        status=Status((external=external_only,))); status_transform=preserve_type)
    same_raw = PSE._prepared_status_manifest(no_change).raw_families
    @test only(same_raw).reference_types == [typeof(external_only)]
    @test PSE.refvalue(model_status(no_change, :external), :external) === external_only
    @test transform_calls[] == 1
    next_external = Ref(Float32[7], 1)
    register_object!(no_change, Object(:next_external;
        status=Status((external=next_external,))))
    @test PSE.refvalue(model_status(no_change, :next_external), :external) === next_external
    @test transform_calls[] == 2
    records_before = copy(no_change.status_conversion_records)
    wrong_ref_class = Object(:wrong_ref_class; status=Status(external=9f0))
    @test_throws ArgumentError register_object!(no_change, wrong_ref_class)
    @test !haskey(no_change.registry.objects, wrong_ref_class.id)
    @test no_change.status_conversion_records == records_before
    @test transform_calls[] == 3 # Actual attempts only; preparation did not replay it.
    @test only(same_raw).reference_types == [typeof(external_only)]
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


@testset "pending consumers admit their own from-status source before registration" begin
    model = CompositeModel(Object(:scene; scale=:Scene); applications=(
        ModelSpec(Reader(); name=:reader, on=Many(scale=:Leaf),
            inputs=(x=One(Self(); var=:seed, from_status=true),)),))
    supplied = Status(seed=3f0)
    reference = PSE.refvalue(supplied, :seed)
    wrong = Object(:wrong; scale=:Leaf, parent=:scene, status=Status(seed=3.0))
    @test_throws ArgumentError register_object!(model, wrong)
    @test Set(keys(model.registry.objects)) == Set([ObjectId(:scene)])
    leaf = Object(:pending; scale=:Leaf, parent=:scene, status=supplied)
    @test register_object!(model, leaf) === leaf
    @test PSE.refvalue(model_status(model, leaf), :seed) === reference
    @test Set(keys(model.registry.objects)) == Set([ObjectId(:scene), ObjectId(:pending)])
    run!(model; steps=1, outputs=:none)
    @test PSE.refvalue(model_status(model, leaf), :x) === reference
    @test model_status(model, leaf).x === 3f0
end

end

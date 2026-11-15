module PreparedStatusRegistrationChecks
using PlantSimEngine, Test
const PSE = PlantSimEngine

PSE.@process "prepared_registration_source" verbose=false
struct Source{T} <: AbstractPrepared_Registration_SourceModel
    initial::T
end
PSE.inputs_(::Source) = NamedTuple()
PSE.outputs_(model::Source) = (x=model.initial,)
PSE.run!(::Source, status, environment, constants, context) = nothing

function fixture(second_id=17)
    first = Object(:plant_a; scale=:Plant)
    second = Object(second_id; scale=:Plant)
    a = Object(:leaf_a; scale=:Leaf, parent=first.id, status=Status(x=1f0))
    b = Object(:leaf_b; scale=:Leaf, parent=second.id, status=Status(x=2.0))
    template(value) = CompositeModelTemplate((
        ModelSpec(Source(value); name=:source, on=Many(scale=:Leaf)),);
        kind=:tree, species=:same)
    model = CompositeModel(
        ObjectInstance(:a, template(0f0); root=first, objects=(a,)),
        ObjectInstance(:b, template(0.0); root=second, objects=(b,)))
    return (; model, first, second, a, b)
end

@testset "prepared registration preserves IDs, scopes, references and inactive None" begin
    data = fixture()
    model = data.model
    store = model.registry.objects
    @test keytype(store) === ObjectId
    @test isnothing(model_status(model, data.first.id))
    @test isnothing(model_status(model, data.second.id))
    manifest = PSE._scenario_preparation(model).status_manifest
    @test store.catalog.status_manifest === manifest
    S = manifest.status_type
    @test typeof(model_status(model, data.a.id)) === S
    @test typeof(model_status(model, data.b.id)) === S

    # Both instances have the same labels and global slot bounds contain32/64.
    # Scope, not those marginal bounds, must reject64 under the32 application.
    wrong_source = Status(x=3.0)
    wrong = Object(:wrong; scale=:Leaf, parent=data.first.id, status=wrong_source)
    before = copy(data.first.children)
    records = copy(model.status_conversion_records)
    @test_throws ArgumentError register_object!(model, wrong)
    @test wrong.status === wrong_source
    @test isnothing(wrong.kind) && isnothing(wrong.species)
    @test data.first.children == before
    @test model.status_conversion_records == records
    @test !haskey(store, wrong.id)

    supplied = Status(x=4f0)
    reference = PSE.refvalue(supplied, :x)
    newborn = Object((:new, 2); scale=:Leaf, parent=data.first.id, status=supplied)
    @test register_object!(model, newborn) === newborn
    @test typeof(model_status(model, newborn.id)) === S
    @test PSE.refvalue(model_status(model, newborn.id), :x) === reference
    @test newborn.kind === :tree && newborn.species === :same
    # The official header has its own token; biological references stay shared.
    @test model_status(model, newborn.id) !== supplied
    @test_throws ArgumentError object_id(model, supplied)
    @test object_id(model, model_status(model, newborn.id)) === newborn.id

    override_source = Status(x=5.0)
    override_ref = PSE.refvalue(override_source, :x)
    moved_parent = Object(:override_parent; scale=:Leaf, parent=data.first.id, status=override_source)
    @test register_object!(model, moved_parent; parent=data.second.id) === moved_parent
    @test moved_parent.parent === data.second.id
    @test PSE.refvalue(model_status(model, moved_parent.id), :x) === override_ref
    @test PSE._prepared_status_application_matches(model, moved_parent, data.second.id,
        only(recipe for recipe in manifest.authored if recipe.id === :b__source))
end

@testset "prospective matching uses the finite registry identity family" begin
    data = fixture(:plant_b)
    previous = data.model.registry
    objects = PSE._closed_object_family_store(previous.objects)
    registry = PSE.ObjectRegistry(objects, previous.by_scale, previous.by_kind,
        previous.by_species, previous.ancestor_ids_by_object)
    fields = map(fieldnames(typeof(data.model))) do name
        name === :registry ? registry : getfield(data.model, name)
    end
    model = PSE.CompositeModel(fields...)
    @test keytype(model.registry.objects) === ObjectId{Symbol}

    wrong = Object(:wrong_closed; scale=:Leaf, status=Status(x=6.0))
    wrong_source = wrong.status
    children = copy(data.first.children)
    @test_throws ArgumentError register_object!(model, wrong; parent=data.first.id)
    @test wrong.status === wrong_source
    @test isnothing(wrong.parent) && isnothing(wrong.kind) && isnothing(wrong.species)
    @test data.first.children == children
    @test !haskey(model.registry.objects, wrong.id)

    source = Status(x=7.0)
    cell = PSE.refvalue(source, :x)
    newborn = Object(:new_closed; scale=:Leaf, parent=data.first.id, status=source)
    @test register_object!(model, newborn; parent=data.second.id) === newborn
    @test newborn.parent === data.second.id
    @test newborn.kind === :tree && newborn.species === :same
    @test PSE.refvalue(model_status(model, newborn.id), :x) === cell
    @test resolve_object_ids(model, Many(Scope(:b), scale=:Leaf)) == [data.b.id, newborn.id]
    @test resolve_object_ids(model, Many(Scope(:a), scale=:Leaf)) == [data.a.id]
end

@testset "registration retains conversion receipts only for actual materialization" begin
    for promote in (false, true)
        calls = Ref(0)
        transform(variable, value) = (calls[] += 1; value)
        model = CompositeModel(Object(:root; scale=:Scene),
            Object(:seed; scale=:Leaf, parent=:root, status=Status(x=1f0));
            applications=(ModelSpec(Source(0f0); name=:source, on=Many(scale=:Leaf)),),
            type_promotion=promote ? Dict(Float64 => Float32) : nothing,
            status_transform=promote ? transform : nothing)
        @test model_status(model, :root) === nothing
        calls[] = 0
        records = copy(model.status_conversion_records)
        supplied = promote ? Status(x=2.0) : Status(x=2f0)
        reference = PSE.refvalue(supplied, :x)
        object = Object(:born; scale=:Leaf, parent=:root, status=supplied)
        @test register_object!(model, object) === object
        official = model_status(model, object)
        @test official.x === 2f0
        @test supplied.x === (promote ? 2.0 : 2f0)
        @test (PSE.refvalue(official, :x) === reference) === !promote
        @test calls[] == Int(promote)
        if promote
            receipt = model.status_conversion_records[(:supplied_status, nothing, object.id, :x)]
            @test receipt.original_type === Float64
            @test receipt.effective_type === Float32
        else
            @test model.status_conversion_records == records
        end
    end
end

@testset "empty prepared catalogs retain None and S without biological values" begin
    model = CompositeModel(Object(:only))
    S = PSE._scenario_preparation(model).status_manifest.status_type
    closed = PSE._closed_object_family_store(model.registry.objects)
    C = typeof(closed.catalog)
    @test isnothing(model_status(model, :only))
    empty!(closed)
    @test isempty(closed)
    @test typeof(closed.catalog) === C
    @test PSE._with_prepared_canonical_status_type(identity, closed.catalog) === S
    @test all(isempty(family.rows) for family in closed.catalog.families)
end

@testset "future explicit Scope is inactive until its real root is registered" begin
    selector = Many(Scope(ObjectId(:future_root)), scale=:Leaf)
    model = CompositeModel(Object(:seed; status=Status(x=1f0)); applications=(
        ModelSpec(Source(0f0); name=:future, on=selector),))
    # Preparation only records prospective types; the public query still rejects
    # an unresolved current scope instead of silently changing query semantics.
    @test_throws ErrorException resolve_object_ids(model, selector)
    source = Status(x=2f0)
    reference = PSE.refvalue(source, :x)
    root = Object(:future_root; scale=:Leaf, status=source)
    @test register_object!(model, root) === root
    @test PSE.refvalue(model_status(model, root.id), :x) === reference
    @test resolve_object_ids(model, selector) == [root.id]
end

end

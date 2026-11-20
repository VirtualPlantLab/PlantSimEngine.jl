module RegisteredStatusDispatchChecks

using PlantSimEngine, Test
const PSE = PlantSimEngine

@testset "erased statuses share one prepared schema and retain their real references" begin
    supplied = [Status(value=Float32(index), payload=ntuple(identity, index)) for index in 1:8]
    model = CompositeModel((Object(index; status=status) for (index,status) in enumerate(supplied))...)
    catalog = PSE._closed_object_family_store(model.registry.objects).catalog
    official = [model_status(model, index) for index in 1:8]
    S = PSE._scenario_preparation(model).status_manifest.status_type
    seen = DataType[]
    for index in 1:8
        erased = model_object(model, index).status
        matched = PSE._with_registered_status(catalog, erased) do status
            push!(seen, typeof(status))
            status.value += 1f0
            status === official[index]
        end
        @test matched
        @test erased !== supplied[index]
        @test PSE.refvalue(erased, :value) === PSE.refvalue(supplied[index], :value)
        @test PSE.refvalue(erased, :payload) === PSE.refvalue(supplied[index], :payload)
        @test supplied[index].value === Float32(index + 1)
        @test_throws ArgumentError object_id(model, supplied[index])
    end
    @test seen == fill(S, 8)
    @test_throws ArgumentError PSE._with_registered_status(identity, catalog, Status(unknown=1))
end

PSE.@process "registered_status_finisher" verbose=false
struct Finisher <: AbstractRegistered_Status_FinisherModel end
PSE.inputs_(::Finisher) = NamedTuple()
PSE.outputs_(::Finisher) = (value=0.5, visits=0)
PSE.run!(::Finisher, status, environment, constants, context) = nothing

@testset "ensuring a required status admits root and registered parent identities" begin
    model = PSE._with_object_id_domain(CompositeModel(
        Object(:root; scale=:Leaf),Object(:child; scale=:Leaf,parent=:root);
        applications=(ModelSpec(Finisher();name=:finish,on=Many(scale=:Leaf)),)))
    I = keytype(model.registry.objects)
    S = PSE._scenario_preparation(model).status_manifest.status_type
    @test I === typeof(ObjectId(:root))
    statuses = map((:root,:child)) do id
        @test model_status(model,id) === nothing
        status = @inferred PSE._ensure_model_object_status!(model,ObjectId(id))
        @test typeof(status) === S
        @test model_status(model,id) === status
        @test isempty(status)
        @test (@inferred PSE._ensure_model_object_status!(model,ObjectId(id))) === status
        status
    end
    @test model_object(model,:root).parent === nothing
    @test model_object(model,:child).parent === ObjectId(:root)
    simulation = run!(model;steps=1,outputs=:all)
    for (id,status) in zip((:root,:child),statuses)
        @test model_status(model,id) === status
        @test status.value === 0.5 && status.visits === 0
        @test outputs(simulation)[(:finish,ObjectId(id),:value)] == [(1.0,0.5)]
    end
end

@testset "newborn registration and finishing retain real reference classes" begin
    # These are genuine initial data, all retained and checked below. Their Ref
    # classes provide the raw seed family; ports provide value/visits permissions.
    existing = (
        Status(seed=1f0, value=0.5, visits=0),
        Status(seed=2.0, value=0.5, visits=0),
        Status((seed=Ref{Real}(3f0), value=Ref(0.5), visits=Ref(0))),
        Status((seed=Ref{Any}(4f0), value=Ref(0.5), visits=Ref(0))),
    )
    model = PSE._with_object_id_domain(CompositeModel(
        Object(:owner; status=Status(count=0)),
        (Object(Symbol(:existing_, index); parent=:owner, scale=:Leaf, status=status)
            for (index,status) in enumerate(existing))...;
        applications=(ModelSpec(Finisher(); name=:finish, on=Many(scale=:Leaf)),)))
    S = PSE._scenario_preparation(model).status_manifest.status_type
    for (index, supplied) in enumerate(existing)
        @test typeof(model_status(model, Symbol(:existing_, index))) === S
        @test PSE.refvalue(model_status(model, Symbol(:existing_, index)), :seed) ===
              PSE.refvalue(supplied, :seed)
    end
    for (id, seed) in ((:a, Status(seed=3f0)), (:b, Status(seed=4.0)),
                       (:c, Status((seed=Ref{Real}(5f0),))),
                       (:d, Status((seed=Ref{Any}(6f0),))))
        object = Object(id; parent=:owner, scale=:Leaf, status=seed)
        @test register_object!(model, object) === object
        canonical = model_status(model, id)
        @test canonical !== seed
        @test typeof(canonical) === S
        @test_throws ArgumentError object_id(model, seed)
        @test object_id(model, canonical) === ObjectId(id)
        seed_ref = PSE.refvalue(seed, :seed)
        value, visits = Ref(0.5), Ref(0)
        I = keytype(model.registry.objects)
        recipes = PSE._canonical_status_recipe_storage(model, I)
        order = I[]
        recipe = PSE._status_recipe_for_object!(recipes, order, model, ObjectId(id))
        PSE._status_recipe_set_reference!(recipe, :value, value)
        PSE._status_recipe_set_reference!(recipe, :visits, visits)
        PSE._apply_status_recipes!(model, recipes, order)
        full = model_status(model, id)
        @test full === canonical === object.status
        @test typeof(full) === S
        @test PSE.refvalue(full, :seed) === seed_ref
        @test PSE.refvalue(full, :value) === value
        @test PSE.refvalue(full, :visits) === visits
        @test (full.seed, full.value, full.visits) == (seed.seed, 0.5, 0)
        if id === :d
            seed_ref[] = :later
            @test full.seed === :later
        elseif id === :c
            seed_ref[] = 9.0
            @test full.seed === 9.0
        end
    end
    unsupported = Object(:wrong; parent=:owner, scale=:Leaf, status=Status(seed=Int8(1)))
    original = unsupported.status
    before = copy(model_object(model, :owner).children)
    @test_throws ArgumentError register_object!(model, unsupported)
    @test unsupported.status === original
    @test !haskey(model.registry.objects, ObjectId(:wrong))
    @test model_object(model, :owner).children == before
end

PSE.@process "registered_status_review_private" verbose=false
struct PrivateWriter <: AbstractRegistered_Status_Review_PrivateModel end
PSE.inputs_(::PrivateWriter) = NamedTuple()
PSE.outputs_(::PrivateWriter) = (x=0.0,)
PSE.environment_inputs_(::PrivateWriter) = NamedTuple()
PSE.environment_outputs_(::PrivateWriter) = NamedTuple()
function PSE.run!(::PrivateWriter, status, environment, constants, context)
    status.x += 1.0
    return nothing
end

@testset "private stream-only references stay absent from canonical storage" begin
    source = CompositeModel(Object(:leaf; status=Status(seed=1.0));
        applications=(ModelSpec(PrivateWriter(); name=:private_writer,
            on=One(id=:leaf), output_routing=(x=:stream_only,)),))
    model = PSE._with_object_id_domain(source)
    canonical = model_status(model, :leaf)
    @test propertynames(canonical) == (:seed,)
    @test !hasproperty(canonical, :x)
    simulation = run!(model; steps=2, outputs=:all)
    @test model_status(model, :leaf) === canonical
    @test propertynames(canonical) == (:seed,)
    rows = collect_outputs(simulation, :leaf, :x; sink=nothing)
    @test getproperty.(rows, :value) == [1.0, 2.0]
end

@testset "the shared conversion executes once on the actual supplied status" begin
    seen = Tuple{Symbol,DataType}[]
    transform = (name,value) -> begin
        push!(seen, (name,typeof(value)))
        value
    end
    model = PSE._with_object_id_domain(CompositeModel(
        Object(:owner; status=Status(count=0)),
        Object(:existing; parent=:owner, scale=:Leaf, status=Status(seed=1.0));
        type_promotion=Dict(Float64=>Float32), status_transform=transform))
    baseline_calls = length(seen)
    supplied = Status(seed=3.0)
    born = register_object!(model, Object(:leaf; parent=:owner, scale=:Leaf, status=supplied))
    effective = model_status(model, :leaf)
    @test typeof(effective) === PSE._scenario_preparation(model).status_manifest.status_type
    @test effective === born.status
    @test effective.seed === 3f0
    @test supplied.seed === 3.0
    @test length(seen) == baseline_calls + 1
    @test last(seen) == (:seed,Float64)
    @test PSE.refvalue(effective, :seed) !== PSE.refvalue(supplied, :seed)
    @test object_id(model, effective) === ObjectId(:leaf)
    @test_throws ArgumentError register_object!(model, Object(:other; scale=:Leaf, status=supplied))
    @test length(seen) == baseline_calls + 1
    @test !haskey(model.registry.objects, ObjectId(:other))
end

@testset "incompatible edited references fail before changing live cells" begin
    supplied = Status(seed=2.0)
    model = PSE._with_object_id_domain(CompositeModel(Object(:leaf; scale=:Leaf, status=supplied);
        applications=(ModelSpec(Finisher(); name=:finish, on=Many(scale=:Leaf)),)))
    official = model_status(model, :leaf)
    seed_ref = PSE.refvalue(official, :seed)
    recipe = PSE._CanonicalStatusRecipe(official, false)
    @test_throws ArgumentError PSE._status_recipe_set_reference!(recipe, :value, Ref(0f0))
    @test isempty(recipe.edit_names)
    @test model_status(model, :leaf) === official
    @test !hasproperty(official, :value) && !hasproperty(official, :visits)
    @test PSE.refvalue(official, :seed) === seed_ref
    @test object_id(model, official) === ObjectId(:leaf)
    @test_throws ArgumentError object_id(model, supplied)
end

end

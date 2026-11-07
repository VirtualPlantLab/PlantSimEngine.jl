module RegisteredStatusDispatchChecks

using PlantSimEngine, Test
const PSE = PlantSimEngine

const Seed32 = Status{(:seed,),Tuple{Base.RefValue{Float32}}}
const Seed64 = Status{(:seed,),Tuple{Base.RefValue{Float64}}}
const SeedReal = Status{(:seed,),Tuple{Base.RefValue{Real}}}
const SeedAny = Status{(:seed,),Tuple{Base.RefValue{Any}}}
const Full32 = Status{(:seed,:value,:visits),
    Tuple{Base.RefValue{Float32},Base.RefValue{Float64},Base.RefValue{Int}}}
const Full64 = Status{(:seed,:value,:visits),
    Tuple{Base.RefValue{Float64},Base.RefValue{Float64},Base.RefValue{Int}}}
const FullReal = Status{(:seed,:value,:visits),
    Tuple{Base.RefValue{Real},Base.RefValue{Float64},Base.RefValue{Int}}}
const FullAny = Status{(:seed,:value,:visits),
    Tuple{Base.RefValue{Any},Base.RefValue{Float64},Base.RefValue{Int}}}

function closed_model(model, future::Tuple)
    previous = model.registry
    active = PSE._closed_object_family_store(previous.objects)
    I = keytype(active)
    empty_families = map(future) do S
        PSE.ObjectFamily{I,S}(Union{Nothing,PSE.ObjectFamilyRow{I,S}}[])
    end
    families = (active.catalog.families..., empty_families...)
    store = PSE.ObjectFamilyStore(PSE.ClosedObjectFamilyCatalog(families),
        active.locations, active.status_owners, active.layout_cache)
    registry = PSE.ObjectRegistry(store, previous.by_scale, previous.by_kind,
        previous.by_species, previous.ancestor_ids_by_object)
    fields = map(fieldnames(typeof(model))) do name
        name === :registry ? registry : getfield(model, name)
    end
    return PSE.CompositeModel(fields...)
end

@testset "eight erased statuses execute inside their concrete family branch" begin
    supplied = [Status(value=Float32(index), payload=ntuple(identity, index)) for index in 1:8]
    model = CompositeModel((Object(index; status=status) for (index,status) in enumerate(supplied))...)
    catalog = PSE._closed_object_family_store(model.registry.objects).catalog
    seen = DataType[]
    for index in 1:8
        erased = model_object(model, index).status
        matched = PSE._with_registered_status(catalog, erased) do status
            push!(seen, typeof(status))
            status.value += 1f0
            status === supplied[index]
        end
        @test matched
        @test supplied[index].value === Float32(index + 1)
    end
    @test seen == typeof.(supplied)
    @test_throws ArgumentError PSE._with_registered_status(identity, catalog, Status(unknown=1))
end

@testset "newborn registration and finishing retain real reference types" begin
    model = closed_model(CompositeModel(Object(:owner; status=Status(count=0))),
        (Seed32,Seed64,SeedReal,SeedAny,Full32,Full64,FullReal,FullAny))
    for (id, seed, Expected) in ((:a, Status(seed=3f0), Full32),
                                (:b, Status(seed=4.0), Full64),
                                (:c, Status((seed=Ref{Real}(5f0),)), FullReal),
                                (:d, Status((seed=Ref{Any}(6f0),)), FullAny))
        object = Object(id; parent=:owner, scale=:Leaf, status=seed)
        @test register_object!(model, object) === object
        @test model_status(model, id) === seed
        @test object_id(model, seed) === ObjectId(id)
        seed_ref = PSE.refvalue(seed, :seed)
        value, visits = Ref(0.5), Ref(0)
        recipe = PSE._CanonicalStatusRecipe(seed)
        PSE._status_recipe_set_reference!(recipe, :value, value)
        PSE._status_recipe_set_reference!(recipe, :visits, visits)
        PSE._finish_canonical_status_recipe(model, recipe) do status
            @test typeof(status) === Expected
            PSE._replace_model_object_status!(model, object, status)
        end
        full = model_status(model, id)
        @test typeof(full) === Expected
        @test PSE.refvalue(full, :seed) === seed_ref
        @test PSE.refvalue(full, :value) === value
        @test PSE.refvalue(full, :visits) === visits
        @test full === object.status
        @test object_id(model, full) === ObjectId(id)
        @test_throws ArgumentError object_id(model, seed)
        if Expected === FullAny
            seed_ref[] = :later
            @test full.seed === :later
        elseif Expected === FullReal
            seed_ref[] = 9.0
            @test full.seed === 9.0
        end
    end
    unsupported = Object(:wrong; parent=:owner, status=Status(seed=Int8(1)))
    original = unsupported.status
    @test_throws ArgumentError register_object!(model, unsupported)
    @test unsupported.status === original
    @test !haskey(model.registry.objects, ObjectId(:wrong))
    @test !(ObjectId(:wrong) in model_object(model, :owner).children)
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

@testset "private stream-only schema is not a canonical object family" begin
    source = CompositeModel(Object(:leaf; status=Status(seed=1.0));
        applications=(ModelSpec(PrivateWriter(); name=:private_writer,
            on=One(id=:leaf), output_routing=(x=:stream_only,)),))
    model = closed_model(source, ())
    canonical = model_status(model, :leaf)
    @test propertynames(canonical) == (:seed,)

    # The private (seed,x) status belongs to this application's runtime view.
    # It must not need an unused (seed,x) canonical registry family.
    simulation = run!(model; steps=2, outputs=:all)
    @test model_status(model, :leaf) === canonical
    @test propertynames(model_status(model, :leaf)) == (:seed,)
    rows = collect_outputs(simulation, :leaf, :x; sink=nothing)
    @test getproperty.(rows, :value) == [1.0, 2.0]
end

@testset "the shared conversion executes once on the actual supplied status" begin
    seen = Tuple{Symbol,DataType}[]
    transform = (name,value) -> begin
        push!(seen, (name,typeof(value)))
        value
    end
    model = closed_model(CompositeModel(Object(:owner; status=Status(count=0));
        type_promotion=Dict(Float64=>Float32), status_transform=transform), (Seed32,))
    baseline_calls = length(seen)
    supplied = Status(seed=3.0)
    born = register_object!(model, Object(:leaf; parent=:owner, status=supplied))
    effective = model_status(model, :leaf)
    @test typeof(effective) === Seed32
    @test effective === born.status
    @test effective.seed === 3f0
    @test supplied.seed === 3.0
    @test length(seen) == baseline_calls + 1
    @test last(seen) == (:seed,Float64)
    @test PSE.refvalue(effective, :seed) !== PSE.refvalue(supplied, :seed)
    @test object_id(model, effective) === ObjectId(:leaf)
    @test_throws ArgumentError register_object!(model, Object(:other; status=supplied))
    @test length(seen) == baseline_calls + 1
    @test !haskey(model.registry.objects, ObjectId(:other))
end

@testset "unadmitted edited reference types fail without replacing live state" begin
    seed = Status(seed=2.0)
    model = closed_model(CompositeModel(Object(:leaf; status=seed)), (Full64,))
    recipe = PSE._CanonicalStatusRecipe(seed)
    PSE._status_recipe_set_reference!(recipe, :value, Ref(0f0))
    PSE._status_recipe_set_reference!(recipe, :visits, Ref(0))
    publish = status -> PSE._replace_model_object_status!(model, :leaf, status)
    @test_throws ArgumentError PSE._finish_canonical_status_recipe(publish, model, recipe)
    @test model_status(model, :leaf) === seed
    @test object_id(model, seed) === ObjectId(:leaf)
end

end

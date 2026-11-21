module FixedStatusScopeGrowthChecks
using PlantSimEngine, Test
const PSE = PlantSimEngine
PSE.@process "fixed_status_scope_growth" verbose=false

struct Increment{T} <: AbstractFixed_Status_Scope_GrowthModel
    initial::T
end
PSE.outputs_(model::Increment) = (x=model.initial,)
function PSE.run!(model::Increment, status, environment, constants, context)
    status.x += one(model.initial)
    return nothing
end

@testset "reparenting retains historical cells while newborns obey their own scope" begin
    supplied = Status(x=3f0)
    cell = PSE.refvalue(supplied, :x)
    model = CompositeModel(
        Object(:north; scale=:Plant), Object(:south; scale=:Plant),
        Object(:leaf; scale=:Leaf, parent=:north, status=supplied);
        applications=(
            ModelSpec(Increment(0f0); name=:north_growth,
                on=Many(scale=:Leaf, within=Scope(ObjectId(:north)))),
            ModelSpec(Increment(0.0); name=:south_growth,
                on=Many(scale=:Leaf, within=Scope(ObjectId(:south)))),
        ))
    official = model_status(model, :leaf)
    @test official !== supplied
    @test PSE.refvalue(official, :x) === cell
    @test_throws ArgumentError object_id(model, supplied)
    @test object_id(model, official) == ObjectId(:leaf)
    @test isnothing(model_status(model, :north))
    @test isnothing(model_status(model, :south))
    prepared_type = typeof(official)

    simulation = run!(model; steps=1, outputs=:none)
    @test official.x === 4f0
    reparent_object!(model, :leaf, :south)
    step!(simulation)
    @test model_status(model, :leaf) === official
    @test PSE.refvalue(official, :x) === cell
    @test official.x === 5f0

    # Float32 fits the global storage union but has never been admitted as
    # newborn data in the Float64 southern configuration.
    rejected = Object(:rejected; scale=:Leaf, parent=:south, status=Status(x=7f0))
    old_status = rejected.status
    object_count = length(model.registry.objects)
    children = copy(model.registry.objects[ObjectId(:south)].children)
    source_owners = copy(model.status_source_owners)
    conversion_records = copy(model.status_conversion_records)
    @test_throws ArgumentError register_object!(model, rejected)
    @test length(model.registry.objects) == object_count
    @test !haskey(model.registry.objects, ObjectId(:rejected))
    @test rejected.status === old_status
    @test model.registry.objects[ObjectId(:south)].children == children
    @test model.status_source_owners == source_owners
    @test model.status_conversion_records == conversion_records

    newborn = Object(:newborn; scale=:Leaf, parent=:south, status=Status(x=8.0))
    newborn_cell = PSE.refvalue(newborn.status, :x)
    register_object!(model, newborn)
    @test typeof(model_status(model, :newborn)) === prepared_type
    @test PSE.refvalue(model_status(model, :newborn), :x) === newborn_cell
    step!(simulation)
    @test official.x === 6f0
    @test model_status(model, :newborn).x === 9.0

    # Preparing Status storage does not restrict the public identity domain.
    tuple_id = (:southern_leaf, 1)
    register_object!(model, Object(tuple_id; scale=:Leaf, parent=:south,
        status=Status(x=1.0)))
    step!(simulation)
    tuple_status = model_status(model, ObjectId(tuple_id))
    @test typeof(tuple_status) === prepared_type
    @test object_id(model, tuple_status) == ObjectId(tuple_id)
    @test tuple_status.x === 2.0
end

@testset "registries sharing a canonical header observe changed references independently" begin
    make(id, status) = CompositeModel(Object(id; scale=:Leaf, status);
        applications=(ModelSpec(Increment(0f0); on=Many(scale=:Leaf)),))
    first_model = make(:one, Status(x=1f0))
    first_run = run!(first_model; steps=0, outputs=:none)
    canonical = model_status(first_model, :one)
    second_model = make(:two, canonical)
    second_run = run!(second_model; steps=0, outputs=:none)
    @test model_status(second_model, :two) === canonical

    detached = copy(canonical)
    PSE._set_status_reference!(detached, :x, Ref(99f0))
    @test isempty(first_model.registry.objects.changed_status_ids)
    @test isempty(second_model.registry.objects.changed_status_ids)
    old = PSE.refvalue(canonical, :x)
    replacement = Ref(4f0)
    PSE._set_status_reference!(canonical, :x, replacement)
    for (model, sim) in ((first_model, first_run), (second_model, second_run))
        register_object!(model, Object(:axis; scale=:Axis))
        step!(sim)
        @test isempty(model.registry.objects.changed_status_ids)
    end
    @test old[] === 1f0
    @test replacement[] === 6f0
    copied = deepcopy(first_model)
    copied_status = model_status(copied, :one)
    GC.gc()
    copied_ref = Ref(20f0)
    PSE._set_status_reference!(copied_status, :x, copied_ref)
    @test copied.registry.objects.changed_status_ids == [ObjectId(:one)]
    @test isempty(first_model.registry.objects.changed_status_ids)
    @test isempty(second_model.registry.objects.changed_status_ids)
    @test PSE.refvalue(canonical, :x) === replacement

    function temporary_subscriber(s)
        short_lived = make(:temporary, s)
        return WeakRef(short_lived.registry.objects.changed_status_ids)
    end
    released = temporary_subscriber(canonical)
    GC.gc()
    @test isnothing(released.value)
    remove_object!(first_model, :one)
    PSE._set_status_reference!(canonical, :x, Ref(10f0))
    @test isempty(first_model.registry.objects.changed_status_ids)
    @test second_model.registry.objects.changed_status_ids == [ObjectId(:two)]
end
end

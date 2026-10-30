using Dates
using PlantSimEngine
using PlantSimEngine.Diagnostics
using Test

PlantSimEngine.@process "column_carrier_gather" verbose = false
PlantSimEngine.@process "column_carrier_writer" verbose = false

struct ColumnCarrierGatherModel <: AbstractColumn_Carrier_GatherModel end
PlantSimEngine.inputs_(::ColumnCarrierGatherModel) = (
    single=Required(Float32),
    optional=Default(-1.0f0),
    signals=Required(Vector{Float32}),
)
PlantSimEngine.outputs_(::ColumnCarrierGatherModel) = (
    total=0.0f0,
    seen_single=0.0f0,
    seen_optional=0.0f0,
    seen_ids=ObjectId[],
    seen_values=Float32[],
)
function PlantSimEngine.run!(::ColumnCarrierGatherModel, status, environment, constants, context)
    signals = bound_input(context, :signals)
    status.total = sum(signals; init=0.0f0)
    status.seen_single = status.single
    status.seen_optional = status.optional
    status.seen_ids = collect(object_ids(signals))
    status.seen_values = collect(signals)
    return nothing
end

struct ColumnCarrierWriterModel{F} <: AbstractColumn_Carrier_WriterModel
    action::F
end
PlantSimEngine.inputs_(::ColumnCarrierWriterModel) = NamedTuple()
PlantSimEngine.outputs_(::ColumnCarrierWriterModel) = (x=Distributed(Default(0.0f0)),)
function PlantSimEngine.run!(model::ColumnCarrierWriterModel, status, environment, constants, context)
    model.action(context)
    return nothing
end

column_carrier_status(column, index; name=:x) = Status(NamedTuple{(name,)}((Ref(column, index),)))

function column_carrier_scene(column)
    return CompositeModel(
        Object(:plant_a; kind=:gatherer, status=Status(single=0.0f0, marker=1)),
        Object(:plant_b; kind=:gatherer, status=Status(single=0.0f0, marker=2)),
        Object(1; kind=:source, parent=:plant_a,
            status=column_carrier_status(column, 1; name=:signal)),
        Object(2; kind=:source, parent=:plant_a,
            status=column_carrier_status(column, 2; name=:signal));
        applications=(ModelSpec(ColumnCarrierGatherModel(); name=:gather,
            on=Many(kind=:gatherer), inputs=(
                single=One(id=1, within=SceneScope(), var=:signal, from_status=true),
                optional=OptionalOne(id=2, within=SceneScope(), var=:signal, from_status=true),
                signals=Many(kind=:source, within=Subtree(), var=:signal, from_status=true),
            )),),
        environment=(duration=Hour(1),),
    )
end

function column_carrier_binding(model, consumer_id, input)
    compiled = Advanced.refresh_bindings!(model)
    return only(binding for binding in compiled.input_bindings
        if binding.consumer_id == ObjectId(consumer_id) && binding.input == input)
end

@testset "concrete reference storage and backing-array alias detection" begin
    column = Float32[1, 2, 3]
    references = [Ref(column, index) for index in eachindex(column)]
    carrier = PlantSimEngine.RefVector(references)
    @test carrier isa PlantSimEngine.RefVector{Float32,typeof(first(references))}
    @test carrier isa PlantSimEngine.RefVector{Float32}
    @test isconcretetype(typeof(carrier))
    @test eltype(carrier) === Float32
    @test eltype(PlantSimEngine.RefVector{Float32}) === Float32
    @test parent(carrier) === references
    carrier[2] = 7.0f0
    @test column == Float32[1, 7, 3]
    column[1] = 4.0f0
    @test carrier[1] === 4.0f0
    @test Base.mightalias(carrier, column)
    @test Base.mightalias(column, carrier)
    @test all(id -> id in Base.dataids(carrier), Base.dataids(column))
    other_carrier = PlantSimEngine.RefVector([Ref(column, index) for index in 3:-1:1])
    @test Base.mightalias(carrier, other_carrier)
    @test !Base.mightalias(carrier, copy(column))

    # Broadcast must read the old values before writing overlapping cells.
    carrier .= view(column, 3:-1:1)
    @test column == Float32[3, 7, 4]
    column .= view(carrier, 3:-1:1)
    @test column == Float32[4, 7, 3]
    copied = Base.unaliascopy(carrier)
    @test typeof(copied) === typeof(carrier)
    @test collect(copied) == column
    @test !Base.mightalias(copied, column)
    copied[1] = -2.0f0
    @test column[1] === 4.0f0

    values = [[1], [2]]
    mutable_carrier = PlantSimEngine.RefVector([Ref(values, 1), Ref(values, 2)])
    @test Base.unaliascopy(mutable_carrier)[1] === values[1]
    gathered = PlantSimEngine.RefVector([Ref(column, 3), Ref(column, 1)])
    gathered_copy = Base.unaliascopy(gathered)
    @test length(getfield(first(parent(gathered_copy)), :x)) == 2
    @test collect(gathered_copy) == Float32[3, 4]
    cells = [Ref(1.0f0), Ref(2.0f0)]
    @test PlantSimEngine.RefVector(cells) isa PlantSimEngine.RefVector{Float32,Base.RefValue{Float32}}
    @test isempty(PlantSimEngine.RefVector{Float32}())
    @test eltype(PlantSimEngine.RefVector{Float32}()) === Float32
    statuses = [column_carrier_status(column, index) for index in 1:2]
    @test collect(PlantSimEngine.RefVector(:x, statuses)) == column[1:2]

    mixed = PlantSimEngine._ref_vector_carrier(Ref[Ref(column, 1), Ref(9.0f0)])
    @test mixed isa PlantSimEngine.ObjectRefVector
    @test Base.mightalias(mixed, column)
    @test typeof(Base.unaliascopy(mixed)) === typeof(mixed)
    @test !Base.mightalias(Base.unaliascopy(mixed), column)
    heterogeneous = PlantSimEngine._ref_vector_carrier(Ref[Ref(column, 1), Ref(9.0)])
    @test heterogeneous isa PlantSimEngine.ObjectRefVector
    @test typeof.(collect(heterogeneous)) == [Float32, Float64]
end

@testset "One, OptionalOne, Many and lifecycle keep live column cells" begin
    column = Float32[1, 2, 3]
    model = column_carrier_scene(column)
    single = column_carrier_binding(model, :plant_a, :single)
    optional = column_carrier_binding(model, :plant_a, :optional)
    many = column_carrier_binding(model, :plant_a, :signals)
    @test input_carrier(single) === PlantSimEngine.refvalue(model_object(model, 1).status, :signal)
    @test input_carrier(single) isa Base.RefArray{Float32}
    @test input_carrier(optional) isa Base.RefArray{Float32}
    @test input_value(single) === 1.0f0
    @test has_reference_carrier(single)
    @test input_carrier(many) isa PlantSimEngine.RefVector{Float32}
    @test eltype(parent(input_carrier(many))) === typeof(Ref(column, 1))
    explained = only(row for row in explain_bindings(Advanced.refresh_bindings!(model))
        if row.consumer_id == :plant_a && row.input == :single)
    @test explained.carrier_kind === :ref
    @test explained.copy_semantics === :live_references

    simulation = run!(model; outputs=:all)
    @test model_object(model, :plant_a).status.total === 3.0f0
    @test isempty(model_object(model, :plant_b).status.seen_ids)
    column[1] = 5.0f0
    model_object(model, :plant_a).status.single = 6.0f0
    @test column[1] === 6.0f0
    continue!(simulation)
    @test model_object(model, :plant_a).status.total === 8.0f0
    @test model_object(model, :plant_b).status.seen_single === 6.0f0

    register_object!(model, Object(3; kind=:source,
        status=column_carrier_status(column, 3; name=:signal)); parent=:plant_a)
    continue!(simulation)
    @test input_carrier(column_carrier_binding(model, :plant_a, :signals)) isa PlantSimEngine.RefVector{Float32}
    @test model_object(model, :plant_a).status.seen_ids == ObjectId[ObjectId(1), ObjectId(2), ObjectId(3)]
    @test model_object(model, :plant_a).status.total === 11.0f0
    reparent_object!(model, 3, :plant_b)
    continue!(simulation)
    @test model_object(model, :plant_b).status.seen_ids == ObjectId[ObjectId(3)]
    @test model_object(model, :plant_b).status.seen_values == Float32[3]

    register_object!(model, Object(4; kind=:source, status=Status(signal=4.0f0)); parent=:plant_a)
    continue!(simulation)
    @test input_carrier(column_carrier_binding(model, :plant_a, :signals)) isa PlantSimEngine.ObjectRefVector
    @test model_object(model, :plant_a).status.seen_values == Float32[6, 2, 4]
    previous_optional_reference = PlantSimEngine.refvalue(model_object(model, :plant_a).status, :optional)
    remove_object!(model, 4)
    remove_object!(model, 2)
    continue!(simulation)
    @test input_carrier(column_carrier_binding(model, :plant_a, :signals)) isa PlantSimEngine.RefVector{Float32}
    @test model_object(model, :plant_a).status.seen_ids == ObjectId[ObjectId(1)]
    # An absent OptionalOne skips rewiring; existing consumer state is retained.
    # Defaults initialize missing fields rather than resetting an existing one.
    @test input_carrier(column_carrier_binding(model, :plant_a, :optional)) === nothing
    @test PlantSimEngine.refvalue(model_object(model, :plant_a).status, :optional) === previous_optional_reference
    @test model_object(model, :plant_a).status.seen_optional === 2.0f0
    @test column == Float32[6, 2, 3]
    register_object!(model, Object(5; kind=:source, status=Status(signal=9.25)); parent=:plant_a)
    continue!(simulation)
    heterogeneous = input_value(column_carrier_binding(model, :plant_a, :signals))
    @test heterogeneous isa PlantSimEngine.ObjectRefVector
    @test typeof.(collect(heterogeneous)) == [Float32, Float64]
    @test model_object(model, 5).status.signal === 9.25
    remove_object!(model, 5)
    continue!(simulation)
    @test input_carrier(column_carrier_binding(model, :plant_a, :signals)) isa PlantSimEngine.RefVector{Float32}
    @test !isempty(outputs(simulation))
end

@testset "distributed columns, validated assignment and mixed-storage refresh" begin
    column = Float32[1, 2, 3]
    seen_carriers = Any[]
    action = context -> begin
        targets = output_targets(context, (:x,))
        carrier = targets.columns.x
        push!(seen_carriers, carrier)
        ids = collect(object_ids(targets))
        @test Base.mightalias(carrier, column)
        before = collect(carrier)
        @test_throws ArgumentError assign_outputs!(targets, ids[1:end-1], (x=before[1:end-1],))
        @test collect(carrier) == before
        invalid = Any[10.0f0 for _ in ids]
        invalid[end] = "invalid Float32"
        @test_throws Exception assign_outputs!(targets, ids, (x=invalid,))
        @test collect(carrier) == before
        if length(ids) == 2
            @test_throws ArgumentError assign_outputs!(targets, ids, (x=view(column, 2:-1:1),))
            @test collect(carrier) == before
            @test assign_outputs!(targets, ids, (x=carrier,)) === targets
        end
        values = Float32[10 * id.value for id in ids]
        assign_outputs!(targets, reverse(ids), (x=reverse(values),))
        return nothing
    end
    model = CompositeModel(
        Object(:controller; kind=:controller),
        Object(1; kind=:destination, status=column_carrier_status(column, 1)),
        Object(2; kind=:destination, status=column_carrier_status(column, 2));
        applications=(ModelSpec(ColumnCarrierWriterModel(action); name=:scatter,
            on=One(kind=:controller), outputs_to=(
                OutputTo(Many(kind=:destination, within=SceneScope()); vars=(:x,)),
            )),),
        environment=(duration=Hour(1),),
    )
    simulation = run!(model; outputs=:all)
    @test only(seen_carriers) isa PlantSimEngine.RefVector{Float32}
    @test column == Float32[10, 20, 3]
    register_object!(model, Object(3; kind=:destination,
        status=column_carrier_status(column, 3)))
    continue!(simulation)
    @test last(seen_carriers) isa PlantSimEngine.RefVector{Float32}
    @test column == Float32[10, 20, 30]
    register_object!(model, Object(4; kind=:destination, status=Status(x=0.0f0)))
    continue!(simulation)
    @test last(seen_carriers) isa PlantSimEngine.ObjectRefVector
    @test model_object(model, 4).status.x === 40.0f0
    @test column == Float32[10, 20, 30]
    remove_object!(model, 4)
    remove_object!(model, 2)
    continue!(simulation)
    @test last(seen_carriers) isa PlantSimEngine.RefVector{Float32}
    @test collect(last(seen_carriers)) == Float32[10, 30]
    @test !isempty(outputs(simulation)[(:scatter, ObjectId(4), :x)])
end

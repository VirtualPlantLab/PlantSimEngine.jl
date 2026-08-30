using Dates
using MultiScaleTreeGraph
using PlantSimEngine
using Test

PlantSimEngine.@process "status_type_lifecycle_increment" verbose = false
PlantSimEngine.@process "status_type_lifecycle_stream_writer" verbose = false
PlantSimEngine.@process "status_type_lifecycle_stream_consumer" verbose = false

struct StatusTypeLifecycleIncrementModel <:
       AbstractStatus_Type_Lifecycle_IncrementModel end

PlantSimEngine.outputs_(::StatusTypeLifecycleIncrementModel) = (value=0.0,)

function PlantSimEngine.run!(
    ::StatusTypeLifecycleIncrementModel,
    status,
    environment,
    constants,
    context,
)
    status.value += one(status.value)
    return nothing
end

struct StatusTypeLifecycleStreamWriterModel <:
       AbstractStatus_Type_Lifecycle_Stream_WriterModel end

PlantSimEngine.outputs_(::StatusTypeLifecycleStreamWriterModel) =
    (private_value=0.0,)

function PlantSimEngine.run!(
    ::StatusTypeLifecycleStreamWriterModel,
    status,
    environment,
    constants,
    context,
)
    status.private_value += one(status.private_value)
    return nothing
end

struct StatusTypeLifecycleStreamConsumerModel <:
       AbstractStatus_Type_Lifecycle_Stream_ConsumerModel end

PlantSimEngine.inputs_(::StatusTypeLifecycleStreamConsumerModel) =
    (private_value=Required(Real),)
PlantSimEngine.outputs_(::StatusTypeLifecycleStreamConsumerModel) = (seen=0.0,)

function PlantSimEngine.run!(
    ::StatusTypeLifecycleStreamConsumerModel,
    status,
    environment,
    constants,
    context,
)
    status.seen = status.private_value
    return nothing
end

struct StatusTypeLifecycleTransformCounter
    calls::Base.RefValue{Int}
end

function (counter::StatusTypeLifecycleTransformCounter)(variable, value)
    counter.calls[] += 1
    return value
end

@testset "register_object! converts status after compilation" begin
    model = CompositeModel(
        Object(:scene; scale=:Scene),
        Object(:plant; scale=:Plant, parent=:scene);
        applications=(
            ModelSpec(
                StatusTypeLifecycleIncrementModel();
                name=:lifecycle_increment,
                on=Many(scale=:Leaf),
            ),
        ),
        environment=(duration=Hour(1),),
        type_promotion=Dict(Float64 => Float32),
    )
    simulation = run!(model; outputs=:all)

    late_leaf = Object(
        :late_leaf;
        scale=:Leaf,
        parent=:plant,
        status=Status(initial_value=2.5),
    )
    registered = register_object!(model, late_leaf)

    @test registered === late_leaf
    @test registered.status === model_status(model, :late_leaf)
    @test registered.status.initial_value === Float32(2.5)
    @test !(:value in propertynames(registered.status))

    continue!(simulation)

    @test registered.status === model_status(model, :late_leaf)
    @test registered.status.initial_value isa Float32
    @test registered.status.value === Float32(1)
    stream = outputs(simulation)[
        (:lifecycle_increment, ObjectId(:late_leaf), :value)
    ]
    @test fieldtype(eltype(stream), 2) === Float32
    @test stream == [(2.0, Float32(1))]
end

@testset "MTG import and add_organ! use the stored conversion policy" begin
    root = MultiScaleTreeGraph.Node(
        MultiScaleTreeGraph.NodeMTG("/", :Scene, 1, 0),
    )
    plant = MultiScaleTreeGraph.Node(
        root,
        MultiScaleTreeGraph.NodeMTG("+", :Plant, 1, 1),
    )
    leaf = MultiScaleTreeGraph.Node(
        plant,
        MultiScaleTreeGraph.NodeMTG("+", :Leaf, 1, 2),
    )
    imported_source = Status(node=leaf, biomass=2.5)

    model = CompositeModel(
        root;
        status=node -> node === leaf ? imported_source : nothing,
        type_promotion=Dict(Float64 => Float32),
    )
    imported = model_status(model, leaf)

    @test imported !== imported_source
    @test imported.node === leaf
    @test imported.biomass === Float32(2.5)
    @test imported_source.biomass === 2.5

    Advanced.refresh_bindings!(model)
    added = add_organ!(
        plant,
        model,
        :+,
        :Leaf,
        2;
        index=2,
        initial_status=(biomass=3.5, area=2.0),
    )
    registered = model_status(model, added.node)

    @test added === registered
    @test model_object(model, added.node).status === added
    @test added.biomass === Float32(3.5)
    @test added.area === Float32(2)
    @test added.node isa MultiScaleTreeGraph.Node
end

@testset "refresh, reparent, steps, and removal do not repeat transforms" begin
    calls = Ref(0)
    transform = StatusTypeLifecycleTransformCounter(calls)
    model = CompositeModel(
        Object(:scene; scale=:Scene),
        Object(:plant_a; scale=:Plant, parent=:scene),
        Object(:plant_b; scale=:Plant, parent=:scene),
        Object(:leaf; scale=:Leaf, parent=:plant_a);
        applications=(
            ModelSpec(
                StatusTypeLifecycleStreamWriterModel();
                name=:lifecycle_stream_writer,
                on=Many(scale=:Leaf),
                output_routing=(private_value=:stream_only,),
            ),
            ModelSpec(
                StatusTypeLifecycleStreamConsumerModel();
                name=:lifecycle_stream_consumer,
                on=Many(scale=:Leaf),
                inputs=(
                    private_value=One(
                        within=Self(),
                        application=:lifecycle_stream_writer,
                        var=:private_value,
                        policy=HoldLast(),
                    ),
                ),
            ),
        ),
        environment=(duration=Hour(1),),
        type_promotion=Dict(Float64 => Float32),
        status_transform=transform,
    )

    Advanced.refresh_bindings!(model)
    materialization_calls = calls[]
    @test materialization_calls > 0

    Advanced.refresh_bindings!(model; force=true)
    @test calls[] == materialization_calls

    simulation = run!(model; outputs=:all)
    @test calls[] == materialization_calls
    leaf_status = model_status(model, :leaf)
    @test leaf_status.seen isa Float32
    @test !(:private_value in propertynames(leaf_status))

    writer_key = (
        :lifecycle_stream_writer,
        ObjectId(:leaf),
        :private_value,
    )
    consumer_key = (
        :lifecycle_stream_consumer,
        ObjectId(:leaf),
        :seen,
    )
    retained_writer_stream = outputs(simulation)[writer_key]
    retained_consumer_stream = outputs(simulation)[consumer_key]
    @test fieldtype(eltype(retained_writer_stream), 2) === Float32
    @test fieldtype(eltype(retained_consumer_stream), 2) === Float32

    step!(simulation)
    @test calls[] == materialization_calls

    reparent_object!(model, :leaf, :plant_b)
    @test calls[] == materialization_calls
    continue!(simulation)
    @test calls[] == materialization_calls
    @test model_object(model, :leaf).parent == ObjectId(:plant_b)
    @test outputs(simulation)[writer_key] === retained_writer_stream
    @test outputs(simulation)[consumer_key] === retained_consumer_stream

    remove_object!(model, :leaf)
    @test calls[] == materialization_calls
    continue!(simulation)
    @test calls[] == materialization_calls
    @test outputs(simulation)[writer_key] === retained_writer_stream
    @test outputs(simulation)[consumer_key] === retained_consumer_stream
    @test last.(retained_writer_stream) == Float32[1, 2, 3]
    @test all(value -> value isa Float32, last.(retained_consumer_stream))
    @test length(retained_consumer_stream) == 3
end

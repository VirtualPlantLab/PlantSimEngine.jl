using Dates
using PlantSimEngine
using PlantSimEngine.Diagnostics
using Test

PlantSimEngine.@process "status_type_runtime_output_writer" verbose = false
PlantSimEngine.@process "status_type_runtime_input_consumer" verbose = false
PlantSimEngine.@process "status_type_runtime_callee" verbose = false
PlantSimEngine.@process "status_type_runtime_controller" verbose = false

struct StatusTypeRuntimeOutputWriterModel <:
       AbstractStatus_Type_Runtime_Output_WriterModel end

struct StatusTypeRuntimeInputConsumerModel <:
       AbstractStatus_Type_Runtime_Input_ConsumerModel end

struct StatusTypeRuntimeCalleeModel <:
       AbstractStatus_Type_Runtime_CalleeModel end

struct StatusTypeRuntimeControllerModel <:
       AbstractStatus_Type_Runtime_ControllerModel end

PlantSimEngine.inputs_(::StatusTypeRuntimeOutputWriterModel) = NamedTuple()
PlantSimEngine.outputs_(::StatusTypeRuntimeOutputWriterModel) = (
    canonical_value=0.0,
    private_value=0.0,
)

function PlantSimEngine.run!(
    ::StatusTypeRuntimeOutputWriterModel,
    status,
    environment,
    constants,
    context,
)
    status.canonical_value += one(status.canonical_value)
    status.private_value += one(status.private_value)
    destinations = output_targets(context, :leaves)
    for index in eachindex(destinations.columns.distributed_value)
        destinations.columns.distributed_value[index] =
            status.canonical_value +
            convert(typeof(status.canonical_value), index)
    end
    return nothing
end

PlantSimEngine.inputs_(::StatusTypeRuntimeInputConsumerModel) = (
    one_value=Required(Real),
    optional_value=Default(0.0),
    many_values=Required(AbstractVector),
    mixed_values=Required(AbstractVector),
)
PlantSimEngine.outputs_(::StatusTypeRuntimeInputConsumerModel) = (total=0.0,)

function PlantSimEngine.run!(
    ::StatusTypeRuntimeInputConsumerModel,
    status,
    environment,
    constants,
    context,
)
    status.total =
        status.one_value +
        status.optional_value +
        sum(status.many_values) +
        sum(status.mixed_values)
    return nothing
end

PlantSimEngine.inputs_(::StatusTypeRuntimeCalleeModel) = NamedTuple()
PlantSimEngine.outputs_(::StatusTypeRuntimeCalleeModel) = (value=0.0,)

function PlantSimEngine.run!(
    ::StatusTypeRuntimeCalleeModel,
    status,
    environment,
    constants,
    context,
)
    status.value += one(status.value)
    return nothing
end

PlantSimEngine.inputs_(::StatusTypeRuntimeControllerModel) = NamedTuple()
PlantSimEngine.outputs_(::StatusTypeRuntimeControllerModel) = (
    trial_value=0.0,
    accepted_value=0.0,
)

function PlantSimEngine.run!(
    ::StatusTypeRuntimeControllerModel,
    status,
    environment,
    constants,
    context,
)
    trial = only(run_call!(context, :callee; publish=false))
    status.trial_value = trial.status.value
    accepted = only(run_call!(context, :callee; publish=true))
    status.accepted_value = accepted.status.value
    return nothing
end

function _assert_status_type_runtime_stream(stream, expected_values)
    @test eltype(stream) === Tuple{Float64,Float32}
    @test all(sample -> sample[2] isa Float32, stream)
    @test last.(stream) == collect(Float32, expected_values)
    return nothing
end

@testset "effective canonical, distributed, and stream-only output types" begin
    model = CompositeModel(
        Object(:scene; scale=:Scene),
        Object(:leaf_a; scale=:Leaf, parent=:scene),
        Object(:leaf_b; scale=:Leaf, parent=:scene);
        applications=(
            ModelSpec(
                StatusTypeRuntimeOutputWriterModel();
                name=:status_type_runtime_writer,
                on=One(scale=:Scene),
                outputs_to=(
                    leaves=OutputTo(
                        Many(scale=:Leaf, within=SceneScope());
                        vars=(distributed_value=Default(0.0),),
                    ),
                ),
                output_routing=(private_value=:stream_only,),
            ),
        ),
        environment=(duration=Hour(1),),
        type_promotion=Dict(Float64 => Float32),
    )

    compiled = Advanced.refresh_bindings!(model)
    scene_status = model_status(model, :scene)
    @test scene_status.canonical_value isa Float32
    @test !(:private_value in propertynames(scene_status))
    private_status = compiled.status_views_by_target[
        (:status_type_runtime_writer, ObjectId(:scene))
    ].status
    @test private_status.private_value isa Float32

    for leaf_id in (:leaf_a, :leaf_b)
        @test model_status(model, leaf_id).distributed_value isa Float32
    end
    distributed_binding = only(compiled.distributed_outputs.bindings)
    @test distributed_binding.columns.distributed_value isa
          PlantSimEngine.RefVector{Float32}

    simulation = run!(model; steps=2, outputs=:all)
    @test final_state(simulation, :scene).canonical_value === Float32(2)
    @test !(:private_value in propertynames(final_state(simulation, :scene)))
    @test final_state(simulation, :leaf_a).distributed_value === Float32(3)
    @test final_state(simulation, :leaf_b).distributed_value === Float32(4)

    retained = outputs(simulation)
    _assert_status_type_runtime_stream(
        retained[
            (
                :status_type_runtime_writer,
                ObjectId(:scene),
                :canonical_value,
            )
        ],
        (1, 2),
    )
    _assert_status_type_runtime_stream(
        retained[
            (
                :status_type_runtime_writer,
                ObjectId(:scene),
                :private_value,
            )
        ],
        (1, 2),
    )
    _assert_status_type_runtime_stream(
        retained[
            (
                :status_type_runtime_writer,
                ObjectId(:leaf_a),
                :distributed_value,
            )
        ],
        (2, 3),
    )
    _assert_status_type_runtime_stream(
        retained[
            (
                :status_type_runtime_writer,
                ObjectId(:leaf_b),
                :distributed_value,
            )
        ],
        (3, 4),
    )

    rows = collect_outputs(simulation; sink=nothing)
    runtime_rows = filter(
        row -> row.application_id == :status_type_runtime_writer,
        rows,
    )
    @test length(runtime_rows) == 8
    @test all(row -> row.value isa Float32, runtime_rows)
end

@testset "effective One, OptionalOne, and Many carrier types" begin
    model = CompositeModel(
        Object(:scene; scale=:Scene),
        Object(
            :leaf_a;
            scale=:Leaf,
            name=:leaf_a,
            parent=:scene,
            status=Status(signal=1.0, token=2.0),
        ),
        Object(
            :leaf_b;
            scale=:Leaf,
            name=:leaf_b,
            parent=:scene,
            status=Status(signal=3.0, token=4),
        );
        applications=(
            ModelSpec(
                StatusTypeRuntimeInputConsumerModel();
                name=:status_type_runtime_consumer,
                on=One(scale=:Scene),
                inputs=(
                    one_value=One(
                        name=:leaf_a,
                        within=SceneScope(),
                        var=:signal,
                        from_status=true,
                    ),
                    optional_value=OptionalOne(
                        name=:leaf_b,
                        within=SceneScope(),
                        var=:signal,
                        from_status=true,
                    ),
                    many_values=Many(
                        scale=:Leaf,
                        within=SceneScope(),
                        var=:signal,
                        from_status=true,
                    ),
                    mixed_values=Many(
                        scale=:Leaf,
                        within=SceneScope(),
                        var=:token,
                        from_status=true,
                    ),
                ),
            ),
        ),
        environment=(duration=Hour(1),),
        type_promotion=Dict(Float64 => Float32),
    )

    compiled = Advanced.refresh_bindings!(model)
    bindings = Dict(binding.input => binding for binding in compiled.input_bindings)
    @test input_carrier(bindings[:one_value]) isa Base.RefValue{Float32}
    @test input_carrier(bindings[:optional_value]) isa Base.RefValue{Float32}
    @test input_carrier(bindings[:many_values]) isa
          PlantSimEngine.RefVector{Float32}
    @test input_carrier(bindings[:mixed_values]) isa
          PlantSimEngine.ObjectRefVector
    @test typeof.(collect(input_value(bindings[:many_values]))) ==
          [Float32, Float32]
    @test typeof.(collect(input_value(bindings[:mixed_values]))) ==
          [Float32, Int]

    rows = Dict(row.input => row for row in explain_bindings(compiled))
    @test rows[:one_value].multiplicity == :one
    @test rows[:optional_value].multiplicity == :optional_one
    @test rows[:many_values].multiplicity == :many
    @test rows[:mixed_values].multiplicity == :many
    @test rows[:many_values].carrier_kind == :ref_vector
    @test rows[:mixed_values].carrier_kind == :object_ref_vector

    simulation = run!(model; outputs=:all)
    consumer_status = final_state(simulation, :scene)
    @test consumer_status.one_value isa Float32
    @test consumer_status.optional_value isa Float32
    @test consumer_status.many_values isa PlantSimEngine.RefVector{Float32}
    @test consumer_status.mixed_values isa PlantSimEngine.ObjectRefVector
    @test consumer_status.total === Float32(14)
    total_stream = outputs(simulation)[
        (:status_type_runtime_consumer, ObjectId(:scene), :total)
    ]
    _assert_status_type_runtime_stream(total_stream, (14,))
end

@testset "hard-call trial stays unpublished and accepted value is typed" begin
    model = CompositeModel(
        Object(:scene; scale=:Scene),
        Object(
            :call_leaf;
            scale=:Leaf,
            name=:call_leaf,
            parent=:scene,
        );
        applications=(
            ModelSpec(
                StatusTypeRuntimeControllerModel();
                name=:status_type_runtime_controller,
                on=One(scale=:Scene),
                calls=(
                    callee=One(
                        name=:call_leaf,
                        application=:status_type_runtime_callee,
                    ),
                ),
            ),
            ModelSpec(
                StatusTypeRuntimeCalleeModel();
                name=:status_type_runtime_callee,
                on=One(scale=:Leaf),
            ),
        ),
        environment=(duration=Hour(1),),
        type_promotion=Dict(Float64 => Float32),
    )

    simulation = run!(model; outputs=:all)
    controller = final_state(simulation, :scene)
    callee = final_state(simulation, :call_leaf)
    @test controller.trial_value === Float32(1)
    @test controller.accepted_value === Float32(2)
    @test callee.value === Float32(2)

    callee_stream = outputs(simulation)[
        (:status_type_runtime_callee, ObjectId(:call_leaf), :value)
    ]
    @test length(callee_stream) == 1
    _assert_status_type_runtime_stream(callee_stream, (2,))
    _assert_status_type_runtime_stream(
        outputs(simulation)[
            (
                :status_type_runtime_controller,
                ObjectId(:scene),
                :trial_value,
            )
        ],
        (1,),
    )
    _assert_status_type_runtime_stream(
        outputs(simulation)[
            (
                :status_type_runtime_controller,
                ObjectId(:scene),
                :accepted_value,
            )
        ],
        (2,),
    )

    rows = collect_outputs(simulation; sink=nothing)
    callee_rows = filter(
        row -> row.application_id == :status_type_runtime_callee,
        rows,
    )
    @test length(callee_rows) == 1
    @test only(callee_rows).value === Float32(2)
end

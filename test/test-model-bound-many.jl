using PlantSimEngine
using Test

PlantSimEngine.@process "bound_many_probe" verbose = false
PlantSimEngine.@process "bound_many_source" verbose = false
PlantSimEngine.@process "bound_many_signal_probe" verbose = false
PlantSimEngine.@process "bound_many_hard_call_controller" verbose = false

struct BoundManyProbeToken
    value::Int
end

struct BoundManyProbeModel <: AbstractBound_Many_ProbeModel end
struct BoundManySourceModel <: AbstractBound_Many_SourceModel end
struct BoundManySignalProbeModel <: AbstractBound_Many_Signal_ProbeModel end
struct BoundManyHardCallControllerModel <:
       AbstractBound_Many_Hard_Call_ControllerModel end

PlantSimEngine.inputs_(::BoundManySourceModel) = NamedTuple()
PlantSimEngine.outputs_(::BoundManySourceModel) = (signal=0.0,)

function PlantSimEngine.run!(
    ::BoundManySourceModel,
    status,
    environment,
    constants,
    context,
)
    return nothing
end

PlantSimEngine.inputs_(::BoundManySignalProbeModel) = (
    signals=Required(Vector{Float64}),
)
PlantSimEngine.outputs_(::BoundManySignalProbeModel) = (
    seen_ids=ObjectId[],
    seen_signals=Float64[],
    total=0.0,
)

function PlantSimEngine.run!(
    ::BoundManySignalProbeModel,
    status,
    environment,
    constants,
    context,
)
    signals = bound_input(context, :signals)
    status.seen_ids = collect(object_ids(signals))
    status.seen_signals = collect(signals)
    status.total = sum(signals; init=0.0)
    return nothing
end

PlantSimEngine.inputs_(::BoundManyHardCallControllerModel) = NamedTuple()
PlantSimEngine.outputs_(::BoundManyHardCallControllerModel) = (callee_total=0.0,)

function PlantSimEngine.run!(
    ::BoundManyHardCallControllerModel,
    status,
    environment,
    constants,
    context,
)
    status.callee_total = only(run_call!(context, :probe)).status.total
    return nothing
end

PlantSimEngine.inputs_(::BoundManyProbeModel) = (
    signals=Required(Vector{Float64}),
    tokens=Required(Vector{Any}),
)
PlantSimEngine.outputs_(::BoundManyProbeModel) = (
    seen_ids=ObjectId[],
    seen_signals=Float64[],
    seen_tokens=Any[],
    total=0.0,
)

function PlantSimEngine.run!(
    ::BoundManyProbeModel,
    status,
    environment,
    constants,
    context,
)
    signals = bound_input(context, :signals)
    tokens = bound_input(context, :tokens)
    @assert object_ids(signals) == object_ids(tokens)
    status.seen_ids = collect(object_ids(signals))
    status.seen_signals = collect(signals)
    status.seen_tokens = collect(tokens)
    total = 0.0
    @inbounds for index in eachindex(signals)
        total += signals[index]
    end
    status.total = total
    return nothing
end

function bound_many_probe_target(
    simulation,
    object_id;
    application=:bound_probe,
)
    id = ObjectId(object_id)
    return only(
        target
        for batch in simulation.execution_plan.batches
        if batch.application.id == application
        for target in batch.targets
        if target.object_id == id
    )
end

function sum_bound_many_input(context)
    values = bound_input(context, :signals)
    total = 0.0
    @inbounds for index in eachindex(values)
        total += values[index]
    end
    return total
end

function sum_bound_many_input_allocations(context)
    sum_bound_many_input(context)
    return @allocated sum_bound_many_input(context)
end

refvector_dispatch(::PlantSimEngine.RefVector) = :ref_vector

struct BoundManyShiftedVector{T} <: AbstractVector{T}
    values::Vector{T}
    offset::Int
end

Base.size(values::BoundManyShiftedVector) = size(values.values)
Base.axes(values::BoundManyShiftedVector) = (
    values.offset:(values.offset + length(values.values) - 1),
)
Base.IndexStyle(::Type{<:BoundManyShiftedVector}) = IndexLinear()
Base.getindex(values::BoundManyShiftedVector, index::Int) =
    values.values[index - values.offset + 1]

@testset "BoundMany vector and identity interface" begin
    ids = ObjectId[ObjectId(:leaf_a), ObjectId(:leaf_b)]
    carrier = PlantSimEngine.RefVector([Ref(1.0), Ref(2.0)])
    values = BoundMany(ids, carrier)

    @test values isa AbstractVector{Float64}
    @test parent(values) === carrier
    @test object_ids(values) == ids
    @test object_ids(values) !== ids
    @test collect(values) == [1.0, 2.0]
    @test values[1] == 1.0
    @test values[ObjectId(:leaf_b)] == 2.0
    @test values .+ 1.0 == [2.0, 3.0]
    @test_throws BoundsError values[3]
    @test_throws BoundsError (values[3] = 5.0)

    values[1] = 3.0
    values[ObjectId(:leaf_b)] = 4.0
    @test collect(carrier) == [3.0, 4.0]
    @test_throws KeyError values[ObjectId(:missing)]
    @test_throws DimensionMismatch BoundMany(ids[1:1], carrier)
    @test_throws DimensionMismatch BoundMany(
        ids,
        BoundManyShiftedVector([1.0, 2.0], 0),
    )
    @test_throws ArgumentError BoundMany(
        BoundManyShiftedVector(ids, 0),
        BoundManyShiftedVector([1.0, 2.0], 0),
    )
    @test_throws ArgumentError BoundMany(reverse(ids), carrier)
    @test_throws ArgumentError BoundMany(
        ObjectId[ObjectId(:leaf_a), ObjectId(:leaf_a)],
        carrier,
    )

    heterogeneous = PlantSimEngine.ObjectRefVector(
        Base.RefValue[Ref{Any}(BoundManyProbeToken(1)), Ref{Any}(2)],
    )
    heterogeneous_values = BoundMany(ids, heterogeneous)
    @test eltype(heterogeneous_values) == Any
    @test heterogeneous_values[ObjectId(:leaf_a)] ==
          BoundManyProbeToken(1)
    heterogeneous_values[ObjectId(:leaf_b)] = :updated
    @test heterogeneous[2] == :updated
end

@testset "compiled BoundMany lifecycle alignment" begin
    model = CompositeModel(
        Object(:scene; scale=:Scene),
        Object(:plant_a; scale=:Plant, parent=:scene),
        Object(:plant_b; scale=:Plant, parent=:scene),
        Object(
            :leaf_b;
            scale=:Leaf,
            parent=:plant_a,
            status=Status(
                signal=2.0,
                token=BoundManyProbeToken(2),
            ),
        ),
        Object(
            :leaf_d;
            scale=:Leaf,
            parent=:plant_a,
            status=Status(signal=4.0, token=4),
        ),
        Object(
            :leaf_c;
            scale=:Leaf,
            parent=:plant_b,
            status=Status(signal=30.0, token=30),
        );
        applications=(
            ModelSpec(
                BoundManyProbeModel();
                name=:bound_probe,
                on=Many(scale=:Plant),
                inputs=(
                    :signals => Many(
                        scale=:Leaf,
                        within=Subtree(),
                        var=:signal,
                        from_status=true,
                    ),
                    :tokens => Many(
                        scale=:Leaf,
                        within=Subtree(),
                        var=:token,
                        from_status=true,
                    ),
                ),
            ),
        ),
    )

    simulation = run!(model; outputs=:none)
    plant_a = model_object(model, :plant_a).status
    plant_b = model_object(model, :plant_b).status
    @test plant_a.seen_ids == ObjectId[ObjectId(:leaf_b), ObjectId(:leaf_d)]
    @test plant_a.seen_signals == [2.0, 4.0]
    @test plant_a.seen_tokens == [BoundManyProbeToken(2), 4]
    @test plant_a.total == 6.0
    @test plant_b.seen_ids == ObjectId[ObjectId(:leaf_c)]
    @test plant_b.total == 30.0
    @test refvector_dispatch(plant_a.signals) == :ref_vector
    @test plant_a.tokens isa PlantSimEngine.ObjectRefVector

    initial_target = bound_many_probe_target(simulation, :plant_a)
    initial_values = initial_target.bound_inputs.signals
    @test bound_input(initial_target.context, :signals) === initial_values
    @test @inferred(bound_input(
        initial_target.context,
        Val(:signals),
    )) === initial_values
    @test @inferred(sum_bound_many_input(initial_target.context)) == 6.0
    @test sum_bound_many_input_allocations(initial_target.context) == 0
    @test_throws ArgumentError bound_input(initial_target.context, "signals")

    register_object!(
        model,
        Object(
            :leaf_z;
            scale=:Leaf,
            status=Status(signal=26.0, token=26),
        );
        parent=:plant_a,
    )
    continue!(simulation)
    appended_target = bound_many_probe_target(simulation, :plant_a)
    @test appended_target.bound_inputs.signals === initial_values
    @test object_ids(initial_values) ==
          ObjectId[ObjectId(:leaf_b), ObjectId(:leaf_d), ObjectId(:leaf_z)]
    @test plant_a.seen_signals == [2.0, 4.0, 26.0]

    register_object!(
        model,
        Object(
            :leaf_a;
            scale=:Leaf,
            status=Status(signal=1.0, token=1),
        );
        parent=:plant_a,
    )
    continue!(simulation)
    inserted_target = bound_many_probe_target(simulation, :plant_a)
    inserted_values = inserted_target.bound_inputs.signals
    @test inserted_values !== initial_values
    @test object_ids(inserted_values) == ObjectId[
        ObjectId(:leaf_a),
        ObjectId(:leaf_b),
        ObjectId(:leaf_d),
        ObjectId(:leaf_z),
    ]
    @test plant_a.seen_signals == [1.0, 2.0, 4.0, 26.0]

    remove_object!(model, :leaf_b)
    continue!(simulation)
    @test plant_a.seen_ids == ObjectId[
        ObjectId(:leaf_a),
        ObjectId(:leaf_d),
        ObjectId(:leaf_z),
    ]
    @test plant_a.seen_signals == [1.0, 4.0, 26.0]

    reparent_object!(model, :leaf_d, :plant_b)
    continue!(simulation)
    @test plant_a.seen_ids ==
          ObjectId[ObjectId(:leaf_a), ObjectId(:leaf_z)]
    @test plant_a.seen_signals == [1.0, 26.0]
    @test plant_b.seen_ids ==
          ObjectId[ObjectId(:leaf_c), ObjectId(:leaf_d)]
    @test plant_b.seen_signals == [30.0, 4.0]

    remove_object!(model, :leaf_a)
    remove_object!(model, :leaf_z)
    continue!(simulation)
    @test isempty(plant_a.seen_ids)
    @test isempty(plant_a.seen_signals)
    @test plant_a.total == 0.0
end

@testset "producer-qualified BoundMany updates in place" begin
    model = CompositeModel(
        Object(:scene; scale=:Scene),
        Object(:plant_a; scale=:Plant, parent=:scene),
        Object(:plant_b; scale=:Plant, parent=:scene),
        Object(
            :leaf_a;
            scale=:Leaf,
            parent=:plant_a,
            status=Status(signal=1.0),
        ),
        Object(
            :leaf_b;
            scale=:Leaf,
            parent=:plant_a,
            status=Status(signal=2.0),
        ),
        Object(
            :leaf_c;
            scale=:Leaf,
            parent=:plant_b,
            status=Status(signal=3.0),
        );
        applications=(
            ModelSpec(
                BoundManySourceModel();
                name=:bound_source,
                on=Many(scale=:Leaf),
            ),
            ModelSpec(
                BoundManySignalProbeModel();
                name=:bound_signal_probe,
                on=Many(scale=:Plant),
                inputs=(
                    :signals => Many(
                        scale=:Leaf,
                        within=Subtree(),
                        application=:bound_source,
                        var=:signal,
                    ),
                ),
            ),
        ),
    )

    simulation = run!(model; outputs=:none)
    target_a = bound_many_probe_target(
        simulation,
        :plant_a;
        application=:bound_signal_probe,
    )
    target_b = bound_many_probe_target(
        simulation,
        :plant_b;
        application=:bound_signal_probe,
    )
    values_a = target_a.bound_inputs.signals
    values_b = target_b.bound_inputs.signals

    register_object!(
        model,
        Object(:leaf_z; scale=:Leaf, status=Status(signal=26.0));
        parent=:plant_a,
    )
    continue!(simulation)
    @test bound_many_probe_target(
        simulation,
        :plant_a;
        application=:bound_signal_probe,
    ) === target_a
    @test target_a.bound_inputs.signals === values_a
    @test object_ids(values_a) == ObjectId[
        ObjectId(:leaf_a),
        ObjectId(:leaf_b),
        ObjectId(:leaf_z),
    ]

    remove_object!(model, :leaf_b)
    continue!(simulation)
    @test bound_many_probe_target(
        simulation,
        :plant_a;
        application=:bound_signal_probe,
    ) === target_a
    @test target_a.bound_inputs.signals === values_a
    @test object_ids(values_a) ==
          ObjectId[ObjectId(:leaf_a), ObjectId(:leaf_z)]

    reparent_object!(model, :leaf_z, :plant_b)
    continue!(simulation)
    @test bound_many_probe_target(
        simulation,
        :plant_a;
        application=:bound_signal_probe,
    ) === target_a
    @test bound_many_probe_target(
        simulation,
        :plant_b;
        application=:bound_signal_probe,
    ) === target_b
    @test target_a.bound_inputs.signals === values_a
    @test target_b.bound_inputs.signals === values_b
    @test object_ids(values_a) == ObjectId[ObjectId(:leaf_a)]
    @test object_ids(values_b) ==
          ObjectId[ObjectId(:leaf_c), ObjectId(:leaf_z)]
end

@testset "BoundMany empty, temporal, and hard-call paths" begin
    empty_model = CompositeModel(
        Object(:scene; scale=:Scene),
        Object(:plant; scale=:Plant, parent=:scene);
        applications=(
            ModelSpec(
                BoundManySourceModel();
                name=:bound_source,
                on=Many(scale=:Leaf),
            ),
            ModelSpec(
                BoundManySignalProbeModel();
                name=:bound_signal_probe,
                on=One(scale=:Plant),
                inputs=(
                    :signals => Many(
                        scale=:Leaf,
                        within=Subtree(),
                        application=:bound_source,
                        var=:signal,
                    ),
                ),
            ),
        ),
    )
    empty_simulation = run!(empty_model; outputs=:none)
    @test isempty(model_object(empty_model, :plant).status.seen_ids)
    register_object!(
        empty_model,
        Object(:leaf_first; scale=:Leaf, status=Status(signal=1.5));
        parent=:plant,
    )
    continue!(empty_simulation)
    typed_target = bound_many_probe_target(
        empty_simulation,
        :plant;
        application=:bound_signal_probe,
    )
    @test eltype(typed_target.bound_inputs.signals) == Float64
    @test model_object(empty_model, :plant).status.seen_ids ==
          ObjectId[ObjectId(:leaf_first)]

    temporal_model = CompositeModel(
        Object(
            :scene;
            scale=:Scene,
            status=Status(signals=[0.0, 0.0]),
        ),
        Object(
            :leaf_a;
            scale=:Leaf,
            parent=:scene,
            status=Status(signal=1.0),
        ),
        Object(
            :leaf_b;
            scale=:Leaf,
            parent=:scene,
            status=Status(signal=2.0),
        );
        applications=(
            ModelSpec(
                BoundManySourceModel();
                name=:bound_source,
                on=Many(scale=:Leaf),
            ),
            ModelSpec(
                BoundManySignalProbeModel();
                name=:temporal_probe,
                on=One(scale=:Scene),
                inputs=(
                    PreviousTimeStep(:signals) => Many(
                        scale=:Leaf,
                        within=SceneScope(),
                        application=:bound_source,
                        var=:signal,
                    ),
                ),
            ),
        ),
    )
    temporal_simulation = run!(temporal_model; steps=2, outputs=:none)
    temporal_target = bound_many_probe_target(
        temporal_simulation,
        :scene;
        application=:temporal_probe,
    )
    @test object_ids(temporal_target.bound_inputs.signals) ==
          ObjectId[ObjectId(:leaf_a), ObjectId(:leaf_b)]
    @test model_object(temporal_model, :scene).status.seen_signals == [1.0, 2.0]

    hard_call_model = CompositeModel(
        Object(:scene; scale=:Scene),
        Object(:plant; scale=:Plant, parent=:scene),
        Object(
            :leaf_a;
            scale=:Leaf,
            parent=:plant,
            status=Status(signal=4.0),
        ),
        Object(
            :leaf_b;
            scale=:Leaf,
            parent=:plant,
            status=Status(signal=6.0),
        );
        applications=(
            ModelSpec(
                BoundManySourceModel();
                name=:bound_source,
                on=Many(scale=:Leaf),
            ),
            ModelSpec(
                BoundManySignalProbeModel();
                name=:called_probe,
                on=One(scale=:Plant),
                inputs=(
                    :signals => Many(
                        scale=:Leaf,
                        within=Subtree(),
                        application=:bound_source,
                        var=:signal,
                    ),
                ),
            ),
            ModelSpec(
                BoundManyHardCallControllerModel();
                name=:controller,
                on=One(scale=:Scene),
                calls=(
                    :probe => One(
                        scale=:Plant,
                        within=Subtree(),
                        application=:called_probe,
                    ),
                ),
            ),
        ),
    )
    run!(hard_call_model; outputs=:none)
    @test model_object(hard_call_model, :scene).status.callee_total == 10.0
    @test model_object(hard_call_model, :plant).status.seen_ids ==
          ObjectId[ObjectId(:leaf_a), ObjectId(:leaf_b)]
end

@testset "bound_input errors name the compiled context" begin
    @test_throws ArgumentError bound_input(nothing, :signals)
end

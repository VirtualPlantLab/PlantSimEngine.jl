using PlantSimEngine
using Test

PlantSimEngine.@process "temporal_view_signal_source" verbose = false

struct TemporalViewSignalSource <: AbstractTemporal_View_Signal_SourceModel end

PlantSimEngine.inputs_(::TemporalViewSignalSource) = NamedTuple()
PlantSimEngine.outputs_(::TemporalViewSignalSource) = (signal=0.0,)

function PlantSimEngine.run!(
    ::TemporalViewSignalSource,
    status,
    environment,
    constants=nothing,
    context=nothing,
)
    status.signal += 1.0
    return nothing
end

PlantSimEngine.@process "temporal_view_signal_consumer" verbose = false

struct TemporalViewSignalConsumer <: AbstractTemporal_View_Signal_ConsumerModel end

PlantSimEngine.inputs_(::TemporalViewSignalConsumer) = (signal=Required(Float64), gain=Required(Float64))
PlantSimEngine.outputs_(::TemporalViewSignalConsumer) = (observed_signal=0.0,)

function PlantSimEngine.run!(
    ::TemporalViewSignalConsumer,
    status,
    environment,
    constants=nothing,
    context=nothing,
)
    status.observed_signal = status.signal * status.gain
    status.signal = -999.0
    return nothing
end

PlantSimEngine.@process "temporal_view_same_step_consumer" verbose = false

struct TemporalViewSameStepConsumer <:
       AbstractTemporal_View_Same_Step_ConsumerModel end

PlantSimEngine.inputs_(::TemporalViewSameStepConsumer) = (signal=Required(Float64),)
PlantSimEngine.outputs_(::TemporalViewSameStepConsumer) =
    (observed_signal=0.0,)

function PlantSimEngine.run!(
    ::TemporalViewSameStepConsumer,
    status,
    environment,
    constants=nothing,
    context=nothing,
)
    status.observed_signal = status.signal
    return nothing
end

PlantSimEngine.@process "temporal_view_many_consumer" verbose = false

struct TemporalViewManyConsumer <: AbstractTemporal_View_Many_ConsumerModel end

PlantSimEngine.inputs_(::TemporalViewManyConsumer) = (signals=Required(Vector{Float64}),)
PlantSimEngine.outputs_(::TemporalViewManyConsumer) = (signal_total=0.0,)

function PlantSimEngine.run!(
    ::TemporalViewManyConsumer,
    status,
    environment,
    constants=nothing,
    context=nothing,
)
    status.signal_total = sum(status.signals)
    status.signals .= -999.0
    return nothing
end

PlantSimEngine.@process "temporal_view_cycle_a" verbose = false
PlantSimEngine.@process "temporal_view_cycle_b" verbose = false

struct TemporalViewCycleA <: AbstractTemporal_View_Cycle_AModel end
struct TemporalViewCycleB <: AbstractTemporal_View_Cycle_BModel end

PlantSimEngine.inputs_(::TemporalViewCycleA) = (cycle_b=Required(Float64),)
PlantSimEngine.outputs_(::TemporalViewCycleA) = (cycle_a=0.0,)
PlantSimEngine.inputs_(::TemporalViewCycleB) = (cycle_a=Required(Float64),)
PlantSimEngine.outputs_(::TemporalViewCycleB) = (cycle_b=0.0,)

function PlantSimEngine.run!(
    ::TemporalViewCycleA,
    status,
    environment,
    constants=nothing,
    context=nothing,
)
    status.cycle_a = status.cycle_b + 1.0
    return nothing
end

function PlantSimEngine.run!(
    ::TemporalViewCycleB,
    status,
    environment,
    constants=nothing,
    context=nothing,
)
    status.cycle_b = 2.0 * status.cycle_a
    return nothing
end

PlantSimEngine.@process "temporal_view_ambiguous_overlap" verbose = false

struct TemporalViewAmbiguousOverlap <:
       AbstractTemporal_View_Ambiguous_OverlapModel end

PlantSimEngine.inputs_(::TemporalViewAmbiguousOverlap) = (signal=Required(Float64),)
PlantSimEngine.outputs_(::TemporalViewAmbiguousOverlap) = (signal=0.0,)

function _temporal_view_source_spec(; target=One(scale=:Leaf))
    return ModelSpec(TemporalViewSignalSource(); name=:signal_source, on=target)
end

function _temporal_view_consumer_spec(; target=One(scale=:Leaf), selector)
    return ModelSpec(TemporalViewSignalConsumer(); name=:lagged_consumer, on=target, inputs=(PreviousTimeStep(:signal) => selector))
end

function _materialization_allocations(
    compiled,
    application,
    status_view,
    streams,
    time,
)
    return @allocated PlantSimEngine._materialize_model_inputs!(
        status_view.status,
        status_view.temporal_inputs,
        compiled,
        application,
        streams,
        time,
    )
end

@testset "Application-local PreviousTimeStep status views" begin
    source_spec = _temporal_view_source_spec()
    consumer_spec = _temporal_view_consumer_spec(
        selector=One(
            within=Self(),
            application=:signal_source,
            var=:signal,
        ),
    )
    same_object = CompositeModel(
        Object(
            :leaf;
            scale=:Leaf,
            status=Status(signal=5.0, gain=2.0, observed_signal=0.0),
        );
        applications=(source_spec, consumer_spec),
    )
    compiled = Advanced.refresh_bindings!(same_object)
    @test compiled.application_order == [:signal_source, :lagged_consumer]

    lagged_binding = only(
        binding for binding in compiled.input_bindings
        if binding.application_id == :lagged_consumer &&
           binding.input == :signal
    )
    children = Dict{Symbol,Set{Symbol}}()
    PlantSimEngine._model_input_order_edges!(
        children,
        (lagged_binding,),
        Dict{Symbol,Set{Symbol}}(),
    )
    @test isempty(children)

    status_view = compiled.status_views_by_target[
        (:lagged_consumer, ObjectId(:leaf))
    ]
    canonical_status = only(model_objects(same_object)).status
    @test status_view.status !== canonical_status
    @test PlantSimEngine.refvalue(status_view.status, :signal) !==
          PlantSimEngine.refvalue(canonical_status, :signal)
    @test PlantSimEngine.refvalue(status_view.status, :gain) ===
          PlantSimEngine.refvalue(canonical_status, :gain)
    @test PlantSimEngine.refvalue(status_view.status, :observed_signal) ===
          PlantSimEngine.refvalue(canonical_status, :observed_signal)

    simulation = run!(
        same_object;
        steps=3,
        outputs=OutputRequest(
            :Leaf,
            :observed_signal;
            name=:observed_signal,
            application=:lagged_consumer,
        ),
    )
    @test canonical_status.signal == 8.0
    @test canonical_status.observed_signal == 14.0
    @test getproperty.(
        collect_outputs(
            simulation,
            :leaf,
            :observed_signal;
            sink=nothing,
        ),
        :value,
    ) == [10.0, 12.0, 14.0]
    dependency_stream = outputs(simulation)[
        (:signal_source, ObjectId(:leaf), :signal)
    ]
    @test dependency_stream isa PlantSimEngine.TemporalDependencyBuffer{Float64}
    @test length(dependency_stream.times) == 2
    @test dependency_stream == [(2.0, 7.0), (3.0, 8.0)]
    retention = only(
        row for row in explain_output_retention(simulation)
        if row.application_id == :signal_source
    )
    @test retention.reasons == (:temporal_dependency,)
    @test retention.retention_steps == 2.0

    execution_target = only(
        only(
            batch.targets for batch in simulation.execution_plan.batches
            if batch.application.id == :lagged_consumer
        ),
    )
    @test execution_target.status === status_view.status
    runtime_temporal_input = only(execution_target.input_bindings)
    @test runtime_temporal_input isa PlantSimEngine.RuntimeTemporalInput
    @test runtime_temporal_input.compiled === only(status_view.temporal_inputs)
    @test runtime_temporal_input.source_streams === dependency_stream
    @test isempty(execution_target.output_bindings)
    PlantSimEngine._materialize_model_inputs!(
        execution_target.status,
        execution_target.input_bindings,
        simulation.compiled,
        simulation.compiled.applications_by_id[:lagged_consumer],
        simulation.temporal_streams,
        4,
    )
    @test @allocated(
        PlantSimEngine._materialize_model_inputs!(
            execution_target.status,
            execution_target.input_bindings,
            simulation.compiled,
            simulation.compiled.applications_by_id[:lagged_consumer],
            simulation.temporal_streams,
            4,
        )
    ) == 0
    source_execution_target = only(
        only(
            batch.targets for batch in simulation.execution_plan.batches
            if batch.application.id == :signal_source
        ),
    )
    runtime_output = only(source_execution_target.output_bindings)
    @test PlantSimEngine._runtime_output_variable(runtime_output) ==
          :signal
    @test runtime_output.stream === dependency_stream
    @test runtime_output.reference ===
          PlantSimEngine.refvalue(canonical_status, :signal)
    materialized_status = PlantSimEngine._materialize_model_inputs!(
        simulation.compiled,
        simulation.compiled.applications_by_id[:lagged_consumer],
        ObjectId(:leaf),
        simulation.temporal_streams,
        4,
    )
    @test materialized_status === status_view.status
    _materialization_allocations(
        simulation.compiled,
        simulation.compiled.applications_by_id[:lagged_consumer],
        status_view,
        simulation.temporal_streams,
        4,
    )
    scalar_materialization_allocations = _materialization_allocations(
        simulation.compiled,
        simulation.compiled.applications_by_id[:lagged_consumer],
        status_view,
        simulation.temporal_streams,
        4,
    )
    @test scalar_materialization_allocations <
          Base.summarysize(status_view.status) +
          Base.summarysize(status_view.temporal_inputs)

    consumer_first = CompositeModel(
        Object(
            :leaf;
            scale=:Leaf,
            status=Status(signal=5.0, gain=2.0, observed_signal=0.0),
        );
        applications=(consumer_spec, source_spec),
    )
    @test Advanced.refresh_bindings!(consumer_first).application_order ==
          [:lagged_consumer, :signal_source]

    cycle_status = Status(cycle_a=0.0, cycle_b=2.0)
    unbroken_cycle = CompositeModel(
        Object(:leaf; scale=:Leaf, status=cycle_status);
        applications=(
            ModelSpec(TemporalViewCycleA(); name=:cycle_a, on=One(scale=:Leaf)),
            ModelSpec(TemporalViewCycleB(); name=:cycle_b, on=One(scale=:Leaf)),
        ),
    )
    @test_throws "dependency cycle" Advanced.refresh_bindings!(unbroken_cycle)

    opened_cycle = CompositeModel(
        Object(
            :leaf;
            scale=:Leaf,
            status=Status(cycle_a=0.0, cycle_b=2.0),
        );
        applications=(
            ModelSpec(TemporalViewCycleA(); name=:cycle_a, on=One(scale=:Leaf), inputs=(PreviousTimeStep(:cycle_b) => One(
                    within=Self(),
                    application=:cycle_b,
                    var=:cycle_b,
                ),)),
            ModelSpec(TemporalViewCycleB(); name=:cycle_b, on=One(scale=:Leaf)),
        ),
    )
    opened_simulation = run!(opened_cycle; steps=3)
    opened_status = only(model_objects(opened_cycle)).status
    @test opened_status.cycle_a == 15.0
    @test opened_status.cycle_b == 30.0
    @test haskey(
        outputs(opened_simulation),
        (:cycle_b, ObjectId(:leaf), :cycle_b),
    )

    cross_object = CompositeModel(
        Object(:scene; scale=:Scene),
        Object(
            :plant;
            scale=:Plant,
            parent=:scene,
            status=Status(signal=0.0, gain=1.0, observed_signal=0.0),
        ),
        Object(
            :leaf;
            scale=:Leaf,
            parent=:plant,
            status=Status(signal=10.0),
        );
        applications=(
            source_spec,
            _temporal_view_consumer_spec(
                target=One(scale=:Plant),
                selector=One(
                    scale=:Leaf,
                    within=Subtree(),
                    application=:signal_source,
                    var=:signal,
                ),
            ),
        ),
    )
    cross_simulation = run!(
        cross_object;
        steps=2,
        outputs=OutputRequest(
            :Plant,
            :observed_signal;
            name=:cross_observed,
            application=:lagged_consumer,
        ),
    )
    @test only(model_objects(cross_object; scale=:Leaf)).status.signal == 12.0
    @test getproperty.(
        collect_outputs(
            cross_simulation,
            :plant,
            :observed_signal;
            sink=nothing,
        ),
        :value,
    ) == [10.0, 11.0]

    many_object = CompositeModel(
        Object(
            :scene;
            scale=:Scene,
            status=Status(signals=[0.0, 0.0], signal_total=0.0),
        ),
        Object(
            :leaf_1;
            scale=:Leaf,
            parent=:scene,
            status=Status(signal=1.0),
        ),
        Object(
            :leaf_2;
            scale=:Leaf,
            parent=:scene,
            status=Status(signal=2.0),
        );
        applications=(
            _temporal_view_source_spec(target=Many(scale=:Leaf)),
            ModelSpec(TemporalViewManyConsumer(); name=:many_consumer, on=One(scale=:Scene), inputs=(PreviousTimeStep(:signals) => Many(
                    scale=:Leaf,
                    within=SceneScope(),
                    application=:signal_source,
                    var=:signal,
                ),)),
        ),
    )
    many_simulation = run!(
        many_object;
        steps=2,
        outputs=OutputRequest(
            :Scene,
            :signal_total;
            name=:many_total,
            application=:many_consumer,
        ),
    )
    @test [
        object.status.signal
        for object in model_objects(many_object; scale=:Leaf)
    ] == [3.0, 4.0]
    @test getproperty.(
        collect_outputs(
            many_simulation,
            :scene,
            :signal_total;
            sink=nothing,
        ),
        :value,
    ) == [3.0, 5.0]
    many_view = many_simulation.compiled.status_views_by_target[
        (:many_consumer, ObjectId(:scene))
    ]
    many_execution_target = only(
        only(
            batch.targets for batch in many_simulation.execution_plan.batches
            if batch.application.id == :many_consumer
        ),
    )
    PlantSimEngine._materialize_model_inputs!(
        many_execution_target.status,
        many_execution_target.input_bindings,
        many_simulation.compiled,
        many_simulation.compiled.applications_by_id[:many_consumer],
        many_simulation.temporal_streams,
        3,
    )
    @test @allocated(
        PlantSimEngine._materialize_model_inputs!(
            many_execution_target.status,
            many_execution_target.input_bindings,
            many_simulation.compiled,
            many_simulation.compiled.applications_by_id[:many_consumer],
            many_simulation.temporal_streams,
            3,
        )
    ) <= 512
    many_storage = many_view.status.signals
    PlantSimEngine._materialize_model_inputs!(
        many_view.status,
        many_view.temporal_inputs,
        many_simulation.compiled,
        many_simulation.compiled.applications_by_id[:many_consumer],
        many_simulation.temporal_streams,
        3,
    )
    @test many_view.status.signals === many_storage
    many_materialization_allocations = _materialization_allocations(
        many_simulation.compiled,
        many_simulation.compiled.applications_by_id[:many_consumer],
        many_view,
        many_simulation.temporal_streams,
        3,
    )
    @test many_materialization_allocations <
          Base.summarysize(many_view.status) +
          Base.summarysize(many_view.temporal_inputs)

    dynamic_object = CompositeModel(
        Object(
            :scene;
            scale=:Scene,
            status=Status(signals=[0.0], signal_total=0.0),
        ),
        Object(
            :leaf_1;
            scale=:Leaf,
            parent=:scene,
            status=Status(signal=1.0),
        );
        applications=(
            _temporal_view_source_spec(target=Many(scale=:Leaf)),
            ModelSpec(TemporalViewManyConsumer(); name=:many_consumer, on=One(scale=:Scene), inputs=(PreviousTimeStep(:signals) => Many(
                    scale=:Leaf,
                    within=SceneScope(),
                    application=:signal_source,
                    var=:signal,
                ),)),
        ),
    )
    dynamic_simulation = run!(
        dynamic_object;
        outputs=OutputRequest(
            :Scene,
            :signal_total;
            name=:dynamic_total,
            application=:many_consumer,
        ),
    )
    register_object!(
        dynamic_object,
        Object(:leaf_2; scale=:Leaf, status=Status(signal=10.0));
        parent=:scene,
    )
    continue!(dynamic_simulation; steps=2)
    @test getproperty.(
        collect_outputs(
            dynamic_simulation,
            :scene,
            :signal_total;
            sink=nothing,
        ),
        :value,
    ) == [1.0, 12.0, 14.0]
    dynamic_view = dynamic_simulation.compiled.status_views_by_target[
        (:many_consumer, ObjectId(:scene))
    ]
    @test length(dynamic_view.status.signals) == 2
    @test only(
        only(
            batch.targets for batch in dynamic_simulation.execution_plan.batches
            if batch.application.id == :many_consumer
        ),
    ).status === dynamic_view.status

    dynamic_same_step = CompositeModel(
        Object(:scene; scale=:Scene);
        applications=(
            ModelSpec(TemporalViewSameStepConsumer();
                name=:same_step_consumer, on=Many(scale=:Leaf)),
            _temporal_view_source_spec(target=Many(scale=:Leaf)),
        ),
    )
    initial_dynamic_order =
        Advanced.refresh_bindings!(dynamic_same_step).application_order
    @test initial_dynamic_order ==
          [:same_step_consumer, :signal_source]
    dynamic_same_step_simulation =
        run!(dynamic_same_step; outputs=:none)
    register_object!(
        dynamic_same_step,
        Object(
            :leaf;
            scale=:Leaf,
            status=Status(signal=5.0, observed_signal=0.0),
        );
        parent=:scene,
    )
    continue!(dynamic_same_step_simulation)
    @test dynamic_same_step_simulation.compiled.application_order ==
          [:signal_source, :same_step_consumer]
    dynamic_same_step_status =
        only(model_objects(dynamic_same_step; scale=:Leaf)).status
    @test dynamic_same_step_status.signal == 6.0
    @test dynamic_same_step_status.observed_signal == 6.0

    dynamic_temporal_target = CompositeModel(
        Object(:scene; scale=:Scene);
        applications=(
            _temporal_view_source_spec(target=Many(scale=:Leaf)),
            _temporal_view_consumer_spec(
                target=Many(scale=:Leaf),
                selector=One(
                    within=Self(),
                    application=:signal_source,
                    var=:signal,
                ),
            ),
        ),
    )
    dynamic_temporal_simulation =
        run!(dynamic_temporal_target; outputs=:none)
    register_object!(
        dynamic_temporal_target,
        Object(
            :leaf;
            scale=:Leaf,
            status=Status(signal=5.0, gain=1.0, observed_signal=0.0),
        );
        parent=:scene,
    )
    continue!(dynamic_temporal_simulation; steps=2)
    dynamic_temporal_status =
        only(model_objects(dynamic_temporal_target; scale=:Leaf)).status
    @test dynamic_temporal_status.signal == 7.0
    @test dynamic_temporal_status.observed_signal == 6.0
    @test dynamic_temporal_simulation.output_retention.temporal_dependencies ==
          Set([(:signal_source, :signal)])
    @test haskey(
        outputs(dynamic_temporal_simulation),
        (:signal_source, ObjectId(:leaf), :signal),
    )
    @test outputs(dynamic_temporal_simulation)[
        (:signal_source, ObjectId(:leaf), :signal)
    ] isa PlantSimEngine.TemporalDependencyBuffer{Float64}

    ambiguous_overlap = CompositeModel(
        Object(:leaf; scale=:Leaf, status=Status(signal=1.0));
        applications=(
            ModelSpec(TemporalViewAmbiguousOverlap();
                name=:ambiguous_overlap, on=One(scale=:Leaf), inputs=(PreviousTimeStep(:signal) => One(
                    within=Self(),
                    var=:signal,
                ),)),
        ),
    )
    @test_throws "both a temporal input and an output" Advanced.refresh_bindings!(
        ambiguous_overlap,
    )
end

@testset "PreviousTimeStep dependency storage scales by object, not duration" begin
    object_count = 2_000
    objects = [
        Object(
            Symbol(:leaf_, index);
            scale=:Leaf,
            status=Status(
                signal=0.0,
                gain=1.0,
                observed_signal=0.0,
            ),
        )
        for index in 1:object_count
    ]
    scene = CompositeModel(
        objects...;
        applications=(
            _temporal_view_source_spec(target=Many(scale=:Leaf)),
            _temporal_view_consumer_spec(
                target=Many(scale=:Leaf),
                selector=One(
                    within=Self(),
                    application=:signal_source,
                    var=:signal,
                ),
            ),
        ),
    )
    simulation = run!(scene; steps=3, outputs=:none)
    streams_by_key = copy(outputs(simulation))
    streams = collect(values(streams_by_key))
    @test length(streams) == object_count
    @test all(
        stream -> stream isa PlantSimEngine.TemporalDependencyBuffer{Float64},
        streams,
    )
    @test all(stream -> length(stream) == 2, streams)
    @test all(stream -> length(stream.times) == 2, streams)

    continue!(simulation)
    steady_allocations = @allocated continue!(simulation)
    @test steady_allocations <= 4_096 * object_count

    continue!(simulation; steps=16)
    @test all(
        outputs(simulation)[key] === stream
        for (key, stream) in streams_by_key
    )
    @test all(stream -> length(stream) == 2, streams)
end

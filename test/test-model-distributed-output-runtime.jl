using Dates
using PlantSimEngine
using Test

PlantSimEngine.@process "distributed_runtime_scene_writer" verbose = false
PlantSimEngine.@process "distributed_runtime_leaf_consumer" verbose = false
PlantSimEngine.@process "distributed_runtime_leaf_updater" verbose = false
PlantSimEngine.@process "distributed_runtime_stateful_writer" verbose = false
PlantSimEngine.@process "distributed_runtime_plant_integrator" verbose = false
PlantSimEngine.@process "distributed_runtime_aggregating_updater" verbose = false

const DistributedRuntimeEvent = Tuple{Int,Symbol,Symbol,Float64}

struct DistributedRuntimeSceneWriterModel <:
       AbstractDistributed_Runtime_Scene_WriterModel
    events::Vector{DistributedRuntimeEvent}
end

struct DistributedRuntimeLeafConsumerModel <:
       AbstractDistributed_Runtime_Leaf_ConsumerModel
    events::Vector{DistributedRuntimeEvent}
end

struct DistributedRuntimeLeafUpdaterModel <:
       AbstractDistributed_Runtime_Leaf_UpdaterModel
    events::Vector{DistributedRuntimeEvent}
end

struct DistributedRuntimeStatefulWriterModel <:
       AbstractDistributed_Runtime_Stateful_WriterModel end

struct DistributedRuntimePlantIntegratorModel <:
       AbstractDistributed_Runtime_Plant_IntegratorModel end

struct DistributedRuntimeAggregatingUpdaterModel <:
       AbstractDistributed_Runtime_Aggregating_UpdaterModel end

PlantSimEngine.inputs_(::DistributedRuntimeSceneWriterModel) = NamedTuple()
PlantSimEngine.outputs_(::DistributedRuntimeSceneWriterModel) = NamedTuple()

PlantSimEngine.inputs_(::DistributedRuntimeLeafConsumerModel) =
    (incident_par=Required(Float64),)
PlantSimEngine.outputs_(::DistributedRuntimeLeafConsumerModel) = (seen=0.0,)

PlantSimEngine.inputs_(::DistributedRuntimeLeafUpdaterModel) =
    (incoming=Required(Float64),)
PlantSimEngine.outputs_(::DistributedRuntimeLeafUpdaterModel) =
    (incident_par=0.0,)

PlantSimEngine.inputs_(::DistributedRuntimeStatefulWriterModel) = NamedTuple()
PlantSimEngine.outputs_(::DistributedRuntimeStatefulWriterModel) =
    (private_runs=0,)

PlantSimEngine.inputs_(::DistributedRuntimePlantIntegratorModel) =
    (integrated_incident_par=Required(Vector{Float64}),)
PlantSimEngine.outputs_(::DistributedRuntimePlantIntegratorModel) =
    (integrated_total=0.0, integration_runs=0)

PlantSimEngine.inputs_(::DistributedRuntimeAggregatingUpdaterModel) =
    (incoming=Required(Float64),)
PlantSimEngine.outputs_(::DistributedRuntimeAggregatingUpdaterModel) =
    (incident_par=0.0,)
PlantSimEngine.output_policy(
    ::Type{<:DistributedRuntimeAggregatingUpdaterModel},
) = (incident_par=Aggregate(),)

# Task 4 intentionally exercises the compiler-owned destination references.
# Task 5 will replace this test-only lookup with the public OutputTargets API.
function _distributed_runtime_destination(context, group::Symbol)
    groups = context.compiled.distributed_outputs.by_execution_target[
        (context.application.id, context.object_id)
    ]
    return getproperty(groups, group)
end

function _distributed_runtime_value(object_id::ObjectId, time::Real)
    coefficient = if object_id == ObjectId(:leaf_a)
        10.0
    elseif object_id == ObjectId(:leaf_b)
        20.0
    elseif object_id in (ObjectId(:late_leaf), ObjectId(:leaf_z))
        30.0
    else
        1.0
    end
    return coefficient * float(time)
end

function _distributed_runtime_execution_target(
    simulation,
    application_id::Symbol,
    object_id::ObjectId,
)
    return only(
        target
        for group in simulation.execution_plan.groups
        if group.application.id == application_id
        for batch in group.batches
        for target in batch.targets
        if target.object_id == object_id
    )
end

function PlantSimEngine.run!(
    model::DistributedRuntimeSceneWriterModel,
    status,
    environment,
    constants,
    context,
)
    push!(
        model.events,
        (Int(context.time), :writer, context.object_id.value, 0.0),
    )
    destinations = _distributed_runtime_destination(context, :leaves)
    for index in eachindex(destinations.destination_ids)
        object_id = destinations.destination_ids[index]
        destinations.columns.incident_par[index] =
            _distributed_runtime_value(object_id, context.time)
    end
    return nothing
end

function PlantSimEngine.run!(
    model::DistributedRuntimeLeafConsumerModel,
    status,
    environment,
    constants,
    context,
)
    status.seen = status.incident_par
    push!(
        model.events,
        (
            Int(context.time),
            :consumer,
            context.object_id.value,
            float(status.seen),
        ),
    )
    return nothing
end

function PlantSimEngine.run!(
    model::DistributedRuntimeLeafUpdaterModel,
    status,
    environment,
    constants,
    context,
)
    status.incident_par = status.incoming + 1.0
    push!(
        model.events,
        (
            Int(context.time),
            :updater,
            context.object_id.value,
            float(status.incident_par),
        ),
    )
    return nothing
end

function PlantSimEngine.run!(
    ::DistributedRuntimeStatefulWriterModel,
    status,
    environment,
    constants,
    context,
)
    status.private_runs += 1
    destinations = _distributed_runtime_destination(context, :leaves)
    for index in eachindex(destinations.destination_ids)
        destinations.columns.incident_par[index] =
            100.0 + status.private_runs
    end
    return nothing
end


function PlantSimEngine.run!(
    ::DistributedRuntimePlantIntegratorModel,
    status,
    environment,
    constants,
    context,
)
    status.integrated_total = sum(status.integrated_incident_par)
    status.integration_runs += 1
    return nothing
end


function PlantSimEngine.run!(
    ::DistributedRuntimeAggregatingUpdaterModel,
    status,
    environment,
    constants,
    context,
)
    status.incident_par = status.incoming + 1.0
    return nothing
end

function _distributed_runtime_applications(
    events;
    writer_every=nothing,
    consumer_every=nothing,
)
    # The consumer is deliberately declared first: the distributed producer
    # dependency, rather than tuple order, must schedule the writer first.
    return (
        ModelSpec(
            DistributedRuntimeLeafConsumerModel(events);
            name=:distributed_runtime_consumer,
            on=Many(scale=:Leaf),
            every=consumer_every,
        ),
        ModelSpec(
            DistributedRuntimeSceneWriterModel(events);
            name=:distributed_runtime_writer,
            on=One(scale=:Scene),
            outputs_to=(
                leaves=OutputTo(
                    Many(scale=:Leaf, within=SceneScope());
                    vars=(incident_par=Default(0.0),),
                ),
            ),
            every=writer_every,
        ),
    )
end

function _distributed_runtime_two_plant_scene(
    events=DistributedRuntimeEvent[];
    writer_every=nothing,
    consumer_every=nothing,
)
    # Reverse lexical declaration order to make incidental insertion order
    # visible if it leaks into the compiled Many target order.
    return CompositeModel(
        Object(:scene; scale=:Scene),
        Object(:plant_b; scale=:Plant, parent=:scene),
        Object(:leaf_b; scale=:Leaf, parent=:plant_b),
        Object(:plant_a; scale=:Plant, parent=:scene),
        Object(:leaf_a; scale=:Leaf, parent=:plant_a);
        applications=_distributed_runtime_applications(
            events;
            writer_every=writer_every,
            consumer_every=consumer_every,
        ),
        environment=(duration=Hour(1),),
    )
end

function _distributed_runtime_empty_scene(
    events=DistributedRuntimeEvent[],
)
    return CompositeModel(
        Object(:scene; scale=:Scene),
        Object(:plant; scale=:Plant, parent=:scene);
        applications=_distributed_runtime_applications(events),
        environment=(duration=Hour(1),),
    )
end

@testset "distributed writer schedules ordinary leaf consumers" begin
    events = DistributedRuntimeEvent[]
    model = _distributed_runtime_two_plant_scene(events)
    compiled = Advanced.refresh_bindings!(model)

    consumer_bindings = [
        row for row in Diagnostics.explain_bindings(compiled)
        if row.application_id == :distributed_runtime_consumer &&
           row.input == :incident_par
    ]
    @test length(consumer_bindings) == 2
    @test all(
        row.source_application_ids == [:distributed_runtime_writer]
        for row in consumer_bindings
    )
    schedule = Dict(
        row.application_id => row.execution_index
        for row in Diagnostics.explain_schedule(compiled)
    )
    @test schedule[:distributed_runtime_writer] <
          schedule[:distributed_runtime_consumer]

    simulation = run!(model; steps=2, outputs=:none)
    @test events == DistributedRuntimeEvent[
        (1, :writer, :scene, 0.0),
        (1, :consumer, :leaf_a, 10.0),
        (1, :consumer, :leaf_b, 20.0),
        (2, :writer, :scene, 0.0),
        (2, :consumer, :leaf_a, 20.0),
        (2, :consumer, :leaf_b, 40.0),
    ]
    states = final_state(simulation, Many(scale=:Leaf))
    @test states[:leaf_a].incident_par == states[:leaf_a].seen == 20.0
    @test states[:leaf_b].incident_par == states[:leaf_b].seen == 40.0
    @test isempty(outputs(simulation))
end

@testset "empty distributed destinations refresh before a new leaf runs" begin
    events = DistributedRuntimeEvent[]
    model = _distributed_runtime_empty_scene(events)
    simulation = run!(model; outputs=:none)
    @test events == DistributedRuntimeEvent[(1, :writer, :scene, 0.0)]

    register_object!(
        model,
        Object(:late_leaf; scale=:Leaf);
        parent=:plant,
    )
    continue!(simulation)

    @test events == DistributedRuntimeEvent[
        (1, :writer, :scene, 0.0),
        (2, :writer, :scene, 0.0),
        (2, :consumer, :late_leaf, 60.0),
    ]
    late_leaf = final_state(simulation, :late_leaf)
    @test late_leaf.incident_par == late_leaf.seen == 60.0
    binding = only(simulation.compiled.distributed_outputs.bindings)
    @test binding.destination_ids == ObjectId[ObjectId(:late_leaf)]
    @test isempty(outputs(simulation))

    retained_events = DistributedRuntimeEvent[]
    retained_model = _distributed_runtime_empty_scene(retained_events)
    request = OutputRequest(
        Many(scale=:Leaf),
        :incident_par;
        name=:dynamic_incident_par,
        application=:distributed_runtime_writer,
    )
    retained_simulation = run!(retained_model; outputs=request)
    empty_writer_target = _distributed_runtime_execution_target(
        retained_simulation,
        :distributed_runtime_writer,
        ObjectId(:scene),
    )
    empty_distributed_output = only(
        output for output in empty_writer_target.output_bindings
        if output isa PlantSimEngine.RuntimeDistributedOutputStream
    )
    @test isempty(empty_distributed_output.streams)
    register_object!(
        retained_model,
        Object(:late_leaf; scale=:Leaf);
        parent=:plant,
    )
    continue!(retained_simulation)
    populated_writer_target = _distributed_runtime_execution_target(
        retained_simulation,
        :distributed_runtime_writer,
        ObjectId(:scene),
    )
    @test populated_writer_target !== empty_writer_target
    @test length(only(
        output for output in populated_writer_target.output_bindings
        if output isa PlantSimEngine.RuntimeDistributedOutputStream
    ).streams) == 1
    @test outputs(retained_simulation)[
        (
            :distributed_runtime_writer,
            ObjectId(:late_leaf),
            :incident_par,
        )
    ] == [(2.0, 60.0)]
    retained_rows = collect_outputs(
        retained_simulation,
        :dynamic_incident_par;
        sink=nothing,
    )
    @test getproperty.(retained_rows, :timestep) == [2]
    @test getproperty.(retained_rows, :object_id) == [:late_leaf]
end

@testset "monotonic distributed additions extend retained streams in place" begin
    model = _distributed_runtime_two_plant_scene()
    simulation = run!(model; outputs=:all)
    writer_target = _distributed_runtime_execution_target(
        simulation,
        :distributed_runtime_writer,
        ObjectId(:scene),
    )
    distributed_output = only(
        output for output in writer_target.output_bindings
        if output isa PlantSimEngine.RuntimeDistributedOutputStream
    )
    runtime_streams = distributed_output.streams
    leaf_a_stream = outputs(simulation)[
        (:distributed_runtime_writer, ObjectId(:leaf_a), :incident_par)
    ]
    @test length(runtime_streams) == 2

    register_object!(
        model,
        Object(:z_late_leaf; scale=:Leaf);
        parent=:plant_a,
    )
    continue!(simulation)

    refreshed_writer_target = _distributed_runtime_execution_target(
        simulation,
        :distributed_runtime_writer,
        ObjectId(:scene),
    )
    refreshed_distributed_output = only(
        output for output in refreshed_writer_target.output_bindings
        if output isa PlantSimEngine.RuntimeDistributedOutputStream
    )
    @test refreshed_writer_target === writer_target
    @test refreshed_distributed_output === distributed_output
    @test refreshed_distributed_output.streams === runtime_streams
    @test length(runtime_streams) == 3
    @test runtime_streams[1] === leaf_a_stream
    @test outputs(simulation)[
        (:distributed_runtime_writer, ObjectId(:z_late_leaf), :incident_par)
    ] == [(2.0, 2.0)]
end

@testset "targeted stream initialization follows affected distributed writers" begin
    model = _distributed_runtime_two_plant_scene()
    compiled = Advanced.refresh_bindings!(model)
    retention = PlantSimEngine.compile_model_output_retention(
        compiled,
        ();
        retain_all=true,
    )
    streams = Dict{Tuple{Symbol,ObjectId,Symbol},Any}()
    PlantSimEngine._initialize_model_output_streams!(
        streams,
        compiled,
        retention,
        0,
        Set([(:distributed_runtime_writer, ObjectId(:scene))]),
    )

    @test Set(keys(streams)) == Set([
        (
            :distributed_runtime_writer,
            ObjectId(:leaf_a),
            :incident_par,
        ),
        (
            :distributed_runtime_writer,
            ObjectId(:leaf_b),
            :incident_par,
        ),
    ])
end

@testset "Updates defines the final distributed-output producer" begin
    events = DistributedRuntimeEvent[]
    model = CompositeModel(
        Object(:scene; scale=:Scene),
        Object(:leaf; scale=:Leaf, parent=:scene);
        applications=(
            ModelSpec(
                DistributedRuntimeSceneWriterModel(events);
                name=:distributed_runtime_writer,
                on=One(scale=:Scene),
                outputs_to=(
                    leaves=OutputTo(
                        Many(scale=:Leaf, within=SceneScope());
                        vars=(incident_par=Default(0.0),),
                    ),
                ),
            ),
            ModelSpec(
                DistributedRuntimeLeafUpdaterModel(events);
                name=:distributed_runtime_updater,
                on=One(scale=:Leaf),
                inputs=(
                    :incoming => One(
                        within=Self(),
                        application=:distributed_runtime_writer,
                        var=:incident_par,
                    ),
                ),
                updates=Updates(
                    :incident_par;
                    after=:distributed_runtime_writer,
                ),
            ),
            ModelSpec(
                DistributedRuntimeLeafConsumerModel(events);
                name=:distributed_runtime_consumer,
                on=One(scale=:Leaf),
            ),
        ),
        environment=(duration=Hour(1),),
    )

    compiled = Advanced.refresh_bindings!(model)
    consumer_binding = only(
        row for row in Diagnostics.explain_bindings(compiled)
        if row.application_id == :distributed_runtime_consumer &&
           row.input == :incident_par
    )
    @test consumer_binding.source_application_ids ==
          [:distributed_runtime_updater]
    writer = only(
        row for row in Diagnostics.explain_writers(compiled)
        if row.object_id == :leaf && row.variable == :incident_par
    )
    @test writer.application_ids == [
        :distributed_runtime_writer,
        :distributed_runtime_updater,
    ]

    simulation = run!(model; outputs=:none)
    @test events == DistributedRuntimeEvent[
        (1, :writer, :scene, 0.0),
        (1, :updater, :leaf, 2.0),
        (1, :consumer, :leaf, 2.0),
    ]
    @test final_state(simulation, :leaf).incident_par == 2.0
    @test final_state(simulation, :leaf).seen == 2.0
end

@testset "distributed histories use producer and destination identities" begin
    requested_model = _distributed_runtime_two_plant_scene()
    request = OutputRequest(
        Many(scale=:Leaf),
        :incident_par;
        name=:requested_incident_par,
        application=:distributed_runtime_writer,
    )
    requested = run!(requested_model; steps=3, outputs=request)
    expected_keys = Set([
        (
            :distributed_runtime_writer,
            ObjectId(:leaf_a),
            :incident_par,
        ),
        (
            :distributed_runtime_writer,
            ObjectId(:leaf_b),
            :incident_par,
        ),
    ])
    @test Set(keys(outputs(requested))) == expected_keys
    @test outputs(requested)[
        (:distributed_runtime_writer, ObjectId(:leaf_a), :incident_par)
    ] == [(1.0, 10.0), (2.0, 20.0), (3.0, 30.0)]
    @test outputs(requested)[
        (:distributed_runtime_writer, ObjectId(:leaf_b), :incident_par)
    ] == [(1.0, 20.0), (2.0, 40.0), (3.0, 60.0)]
    requested_rows = collect_outputs(
        requested,
        :requested_incident_par;
        sink=nothing,
    )
    @test unique(getproperty.(requested_rows, :application_id)) ==
          [:distributed_runtime_writer]
    @test Set(getproperty.(requested_rows, :object_id)) ==
          Set((:leaf_a, :leaf_b))

    all_model = _distributed_runtime_two_plant_scene()
    all_outputs = run!(all_model; steps=2, outputs=:all)
    distributed_keys = Set(
        key for key in keys(outputs(all_outputs))
        if first(key) == :distributed_runtime_writer
    )
    @test distributed_keys == expected_keys
    @test last.(outputs(all_outputs)[
        (:distributed_runtime_writer, ObjectId(:leaf_a), :incident_par)
    ]) == [10.0, 20.0]
    @test last.(outputs(all_outputs)[
        (:distributed_runtime_writer, ObjectId(:leaf_b), :incident_par)
    ]) == [20.0, 40.0]
end

@testset "distributed retention follows the producer cadence" begin
    model = _distributed_runtime_two_plant_scene(
        DistributedRuntimeEvent[];
        writer_every=Hour(2),
        consumer_every=Hour(1),
    )
    simulation = run!(model; steps=5, outputs=:all)

    writer_stream = outputs(simulation)[
        (:distributed_runtime_writer, ObjectId(:leaf_a), :incident_par)
    ]
    consumer_stream = outputs(simulation)[
        (:distributed_runtime_consumer, ObjectId(:leaf_a), :seen)
    ]
    @test first.(writer_stream) == [1.0, 3.0, 5.0]
    @test last.(writer_stream) == [10.0, 30.0, 50.0]
    @test first.(consumer_stream) == [1.0, 2.0, 3.0, 4.0, 5.0]
    @test last.(consumer_stream) == [10.0, 10.0, 30.0, 30.0, 50.0]
end

@testset "lifecycle preserves existing stream-only private output state" begin
    model = CompositeModel(
        Object(:scene; scale=:Scene),
        Object(:plant; scale=:Plant, parent=:scene);
        applications=(
            ModelSpec(
                DistributedRuntimeStatefulWriterModel();
                name=:distributed_runtime_stateful_writer,
                on=One(scale=:Scene),
                outputs_to=(
                    leaves=OutputTo(
                        Many(scale=:Leaf, within=SceneScope());
                        vars=(incident_par=Default(0.0),),
                    ),
                ),
                output_routing=(private_runs=:stream_only,),
            ),
        ),
        environment=(duration=Hour(1),),
    )

    simulation = run!(model; outputs=:all)
    @test outputs(simulation)[
        (
            :distributed_runtime_stateful_writer,
            ObjectId(:scene),
            :private_runs,
        )
    ] == [(1.0, 1)]
    @test !(:private_runs in propertynames(final_state(simulation, :scene)))

    register_object!(
        model,
        Object(:late_leaf; scale=:Leaf);
        parent=:plant,
    )
    continue!(simulation)

    @test outputs(simulation)[
        (
            :distributed_runtime_stateful_writer,
            ObjectId(:scene),
            :private_runs,
        )
    ] == [(1.0, 1), (2.0, 2)]
    @test final_state(simulation, :late_leaf).incident_par == 102.0
end

@testset "concrete output request selects disjoint distributed writer" begin
    model = CompositeModel(
        Object(:scene; scale=:Scene),
        Object(
            :sun_leaf;
            scale=:Leaf,
            kind=:sun,
            parent=:scene,
        ),
        Object(
            :shade_leaf;
            scale=:Leaf,
            kind=:shade,
            parent=:scene,
        );
        applications=(
            ModelSpec(
                DistributedRuntimeSceneWriterModel(
                    DistributedRuntimeEvent[],
                );
                name=:distributed_runtime_sun_writer,
                on=One(scale=:Scene),
                outputs_to=(
                    leaves=OutputTo(
                        Many(
                            scale=:Leaf,
                            kind=:sun,
                            within=SceneScope(),
                        );
                        vars=(incident_par=Default(0.0),),
                    ),
                ),
            ),
            ModelSpec(
                DistributedRuntimeSceneWriterModel(
                    DistributedRuntimeEvent[],
                );
                name=:distributed_runtime_shade_writer,
                on=One(scale=:Scene),
                outputs_to=(
                    leaves=OutputTo(
                        Many(
                            scale=:Leaf,
                            kind=:shade,
                            within=SceneScope(),
                        );
                        vars=(incident_par=Default(0.0),),
                    ),
                ),
            ),
        ),
        environment=(duration=Hour(1),),
    )

    simulation = run!(
        model;
        outputs=OutputRequest(
            One(kind=:sun),
            :incident_par;
            name=:sun_incident_par,
        ),
    )
    expected_key = (
        :distributed_runtime_sun_writer,
        ObjectId(:sun_leaf),
        :incident_par,
    )
    @test Set(keys(outputs(simulation))) == Set([expected_key])
    @test outputs(simulation)[expected_key] == [(1.0, 1.0)]
    rows = collect_outputs(simulation, :sun_incident_par; sink=nothing)
    @test getproperty.(rows, :application_id) ==
          [:distributed_runtime_sun_writer]
    @test getproperty.(rows, :object_id) == [:sun_leaf]
end

@testset "PreviousTimeStep retains bounded distributed history" begin
    events = DistributedRuntimeEvent[]
    model = CompositeModel(
        Object(:scene; scale=:Scene),
        Object(:lag_leaf; scale=:Leaf, parent=:scene);
        applications=(
            ModelSpec(
                DistributedRuntimeSceneWriterModel(events);
                name=:distributed_runtime_lag_writer,
                on=One(scale=:Scene),
                outputs_to=(
                    leaves=OutputTo(
                        Many(scale=:Leaf, within=SceneScope());
                        vars=(incident_par=Default(0.0),),
                    ),
                ),
            ),
            ModelSpec(
                DistributedRuntimeLeafConsumerModel(events);
                name=:distributed_runtime_lag_consumer,
                on=One(scale=:Leaf),
                inputs=(
                    PreviousTimeStep(:incident_par) => One(
                        within=Self(),
                        application=:distributed_runtime_lag_writer,
                        var=:incident_par,
                    ),
                ),
            ),
        ),
        environment=(duration=Hour(1),),
    )

    simulation = run!(model; steps=5, outputs=:none)
    @test [
        event[4] for event in events
        if event[2] == :consumer
    ] == [0.0, 1.0, 2.0, 3.0, 4.0]

    dependency_stream = outputs(simulation)[
        (
            :distributed_runtime_lag_writer,
            ObjectId(:lag_leaf),
            :incident_par,
        )
    ]
    @test dependency_stream isa
          PlantSimEngine.TemporalDependencyBuffer{Float64}
    @test length(dependency_stream.times) == 2
    @test dependency_stream == [(4.0, 4.0), (5.0, 5.0)]
    retention = only(
        row for row in Diagnostics.explain_output_retention(simulation)
        if row.application_id == :distributed_runtime_lag_writer &&
           row.variable == :incident_par
    )
    @test retention.reasons == (:temporal_dependency,)
    @test retention.retention_steps == 2.0
end

@testset "temporal Many uses final Updates writer after distributed output" begin
    events = DistributedRuntimeEvent[]
    model = CompositeModel(
        Object(:scene; scale=:Scene),
        Object(:plant; scale=:Plant, parent=:scene),
        Object(:leaf_a; scale=:Leaf, parent=:plant),
        Object(:leaf_b; scale=:Leaf, parent=:plant);
        applications=(
            ModelSpec(
                DistributedRuntimeSceneWriterModel(events);
                name=:distributed_runtime_integrated_writer,
                on=One(scale=:Scene),
                outputs_to=(
                    leaves=OutputTo(
                        Many(scale=:Leaf, within=SceneScope());
                        vars=(incident_par=Default(0.0),),
                    ),
                ),
                every=Hour(1),
            ),
            ModelSpec(
                DistributedRuntimeLeafUpdaterModel(events);
                name=:distributed_runtime_integrated_updater,
                on=Many(scale=:Leaf),
                inputs=(
                    :incoming => One(
                        within=Self(),
                        application=:distributed_runtime_integrated_writer,
                        var=:incident_par,
                    ),
                ),
                updates=Updates(
                    :incident_par;
                    after=:distributed_runtime_integrated_writer,
                ),
                every=Hour(1),
            ),
            ModelSpec(
                DistributedRuntimePlantIntegratorModel();
                name=:distributed_runtime_integrator,
                on=One(scale=:Plant),
                inputs=(
                    :integrated_incident_par => Many(
                        scale=:Leaf,
                        within=Subtree(),
                        var=:incident_par,
                        policy=Integrate(),
                        window=Hour(2),
                    ),
                ),
                every=Hour(2),
            ),
        ),
        environment=(duration=Hour(1),),
    )

    compiled = Advanced.refresh_bindings!(model)
    temporal_input = only(
        compiled.status_views_by_target[
            (:distributed_runtime_integrator, ObjectId(:plant))
        ].temporal_inputs,
    )
    @test temporal_input.source_applications == [
        :distributed_runtime_integrated_updater,
        :distributed_runtime_integrated_updater,
    ]

    simulation = run!(model; steps=3, outputs=:none)
    plant = final_state(simulation, :plant)
    @test plant.integration_runs == 2
    @test plant.integrated_total > 0.0
    for leaf_id in (:leaf_a, :leaf_b)
        @test outputs(simulation)[
            (
                :distributed_runtime_integrated_updater,
                ObjectId(leaf_id),
                :incident_par,
            )
        ] isa PlantSimEngine.TemporalDependencyBuffer{Float64}
    end
end

@testset "reparent and removal refresh destinations without losing history" begin
    model = CompositeModel(
        Object(:scene; scale=:Scene),
        Object(:plant_a; scale=:Plant, parent=:scene),
        Object(:plant_b; scale=:Plant, parent=:scene),
        Object(:moving_leaf; scale=:Leaf, parent=:plant_a);
        applications=(
            ModelSpec(
                DistributedRuntimeSceneWriterModel(
                    DistributedRuntimeEvent[],
                );
                name=:distributed_runtime_plant_writer,
                on=Many(scale=:Plant),
                outputs_to=(
                    leaves=OutputTo(
                        Many(scale=:Leaf, within=Subtree());
                        vars=(incident_par=Default(0.0),),
                    ),
                ),
            ),
        ),
        environment=(duration=Hour(1),),
    )

    simulation = run!(model; outputs=:all)
    stream_key = (
        :distributed_runtime_plant_writer,
        ObjectId(:moving_leaf),
        :incident_par,
    )
    retained_stream = outputs(simulation)[stream_key]
    @test retained_stream == [(1.0, 1.0)]
    plant_a_target = _distributed_runtime_execution_target(
        simulation,
        :distributed_runtime_plant_writer,
        ObjectId(:plant_a),
    )
    plant_b_target = _distributed_runtime_execution_target(
        simulation,
        :distributed_runtime_plant_writer,
        ObjectId(:plant_b),
    )
    initial_targets =
        simulation.compiled.distributed_outputs.by_execution_target
    @test initial_targets[
        (:distributed_runtime_plant_writer, ObjectId(:plant_a))
    ].leaves.destination_ids == ObjectId[ObjectId(:moving_leaf)]
    @test isempty(
        initial_targets[
            (:distributed_runtime_plant_writer, ObjectId(:plant_b))
        ].leaves.destination_ids,
    )

    reparent_object!(model, :moving_leaf, :plant_b)
    continue!(simulation)

    reparented_targets =
        simulation.compiled.distributed_outputs.by_execution_target
    reparented_plant_a_target = _distributed_runtime_execution_target(
        simulation,
        :distributed_runtime_plant_writer,
        ObjectId(:plant_a),
    )
    reparented_plant_b_target = _distributed_runtime_execution_target(
        simulation,
        :distributed_runtime_plant_writer,
        ObjectId(:plant_b),
    )
    @test reparented_plant_a_target !== plant_a_target
    @test reparented_plant_b_target !== plant_b_target
    @test isempty(
        reparented_targets[
            (:distributed_runtime_plant_writer, ObjectId(:plant_a))
        ].leaves.destination_ids,
    )
    plant_b_binding = reparented_targets[
        (:distributed_runtime_plant_writer, ObjectId(:plant_b))
    ].leaves
    @test plant_b_binding.destination_ids ==
          ObjectId[ObjectId(:moving_leaf)]
    moving_leaf = only(model_objects(model; scale=:Leaf))
    @test only(parent(plant_b_binding.columns.incident_par)) ===
          PlantSimEngine.refvalue(moving_leaf.status, :incident_par)
    owner = only(
        simulation.compiled.distributed_outputs.writer_ownership[
            (ObjectId(:moving_leaf), :incident_par)
        ],
    )
    @test owner.execution_object_id == ObjectId(:plant_b)
    @test outputs(simulation)[stream_key] === retained_stream
    @test retained_stream == [(1.0, 1.0), (2.0, 2.0)]

    remove_object!(model, :moving_leaf)
    continue!(simulation)

    removed_targets =
        simulation.compiled.distributed_outputs.by_execution_target
    removed_plant_b_target = _distributed_runtime_execution_target(
        simulation,
        :distributed_runtime_plant_writer,
        ObjectId(:plant_b),
    )
    @test removed_plant_b_target !== reparented_plant_b_target
    @test all(
        isempty(
            removed_targets[
                (:distributed_runtime_plant_writer, ObjectId(plant_id))
            ].leaves.destination_ids,
        )
        for plant_id in (:plant_a, :plant_b)
    )
    @test !haskey(
        simulation.compiled.distributed_outputs.writer_ownership,
        (ObjectId(:moving_leaf), :incident_par),
    )
    @test outputs(simulation)[stream_key] === retained_stream
    @test retained_stream == [(1.0, 1.0), (2.0, 2.0)]
end

@testset "Many application filter restricts distributed source membership" begin
    model = CompositeModel(
        Object(:scene; scale=:Scene),
        Object(:plant; scale=:Plant, parent=:scene),
        Object(:leaf_a; scale=:Leaf, kind=:sun, parent=:plant),
        Object(:leaf_b; scale=:Leaf, kind=:shade, parent=:plant);
        applications=(
            ModelSpec(
                DistributedRuntimeSceneWriterModel(
                    DistributedRuntimeEvent[],
                );
                name=:distributed_runtime_sun_only_writer,
                on=One(scale=:Scene),
                outputs_to=(
                    leaves=OutputTo(
                        Many(
                            scale=:Leaf,
                            kind=:sun,
                            within=SceneScope(),
                        );
                        vars=(incident_par=Default(0.0),),
                    ),
                ),
            ),
            ModelSpec(
                DistributedRuntimePlantIntegratorModel();
                name=:distributed_runtime_sun_only_consumer,
                on=One(scale=:Plant),
                inputs=(
                    :integrated_incident_par => Many(
                        scale=:Leaf,
                        within=Subtree(),
                        application=:distributed_runtime_sun_only_writer,
                        var=:incident_par,
                    ),
                ),
            ),
            ModelSpec(
                DistributedRuntimeSceneWriterModel(
                    DistributedRuntimeEvent[],
                );
                name=:distributed_runtime_shade_only_writer,
                on=One(scale=:Scene),
                outputs_to=(
                    leaves=OutputTo(
                        Many(
                            scale=:Leaf,
                            kind=:shade,
                            within=SceneScope(),
                        );
                        vars=(incident_par=Default(0.0),),
                    ),
                ),
            ),
        ),
        environment=(duration=Hour(1),),
    )

    compiled = Advanced.refresh_bindings!(model)
    binding = only(
        candidate for candidate in compiled.input_bindings
        if candidate.application_id ==
           :distributed_runtime_sun_only_consumer
    )
    @test binding.source_ids == ObjectId[ObjectId(:leaf_a)]
    @test binding.plan.potential_source_application_ids ==
          (:distributed_runtime_sun_only_writer,)
    @test binding.source_application_ids ==
          [:distributed_runtime_sun_only_writer]

    original_carrier = binding.carrier
    original_references = parent(original_carrier)
    simulation = run!(model; outputs=:none, performance=true)
    @test final_state(simulation, :plant).integrated_total == 10.0
    @test final_state(simulation, :leaf_b).incident_par == 20.0

    register_object!(
        model,
        Object(
            :leaf_z;
            scale=:Leaf,
            kind=:sun,
            parent=:plant,
        ),
    )
    continue!(simulation)

    refreshed = only(
        candidate for candidate in simulation.compiled.input_bindings
        if candidate.application_id ==
           :distributed_runtime_sun_only_consumer
    )
    @test refreshed === binding
    @test refreshed.carrier === original_carrier
    @test parent(refreshed.carrier) === original_references
    @test refreshed.source_ids == ObjectId.([:leaf_a, :leaf_z])
    @test parent(refreshed.carrier)[end] === PlantSimEngine.refvalue(
        model_status(model, :leaf_z),
        :incident_par,
    )
    @test final_state(simulation, :plant).integrated_total == 80.0
    counts = Advanced.runtime_performance(simulation).counts
    @test counts[:lifecycle_many_input_binding_direct_appends] == 1
    @test counts[:lifecycle_many_input_binding_direct_sources_appended] == 1
end

@testset "Many default policy follows final distributed Updates writer" begin
    model = CompositeModel(
        Object(:scene; scale=:Scene),
        Object(:plant; scale=:Plant, parent=:scene),
        Object(:leaf; scale=:Leaf, parent=:plant);
        applications=(
            ModelSpec(
                DistributedRuntimeSceneWriterModel(
                    DistributedRuntimeEvent[],
                );
                name=:distributed_runtime_policy_writer,
                on=One(scale=:Scene),
                outputs_to=(
                    leaves=OutputTo(
                        Many(scale=:Leaf, within=SceneScope());
                        vars=(incident_par=Default(0.0),),
                    ),
                ),
            ),
            ModelSpec(
                DistributedRuntimeAggregatingUpdaterModel();
                name=:distributed_runtime_policy_updater,
                on=One(scale=:Leaf),
                inputs=(
                    :incoming => One(
                        within=Self(),
                        application=:distributed_runtime_policy_writer,
                        var=:incident_par,
                    ),
                ),
                updates=Updates(
                    :incident_par;
                    after=:distributed_runtime_policy_writer,
                ),
            ),
            ModelSpec(
                DistributedRuntimePlantIntegratorModel();
                name=:distributed_runtime_policy_consumer,
                on=One(scale=:Plant),
                inputs=(
                    :integrated_incident_par => Many(
                        scale=:Leaf,
                        within=Subtree(),
                        var=:incident_par,
                    ),
                ),
            ),
        ),
        environment=(duration=Hour(1),),
    )

    compiled = Advanced.refresh_bindings!(model)
    binding = only(
        candidate for candidate in compiled.input_bindings
        if candidate.application_id == :distributed_runtime_policy_consumer
    )
    @test binding.source_application_ids ==
          [:distributed_runtime_policy_updater]
    @test binding.policy isa Aggregate
end

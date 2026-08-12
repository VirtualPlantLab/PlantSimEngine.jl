using Dates
using PlantSimEngine
using Test

PlantSimEngine.@process "boundary_counter" verbose = false
struct BoundaryCounterModel <: AbstractBoundary_CounterModel end
PlantSimEngine.inputs_(::BoundaryCounterModel) = NamedTuple()
PlantSimEngine.outputs_(::BoundaryCounterModel) = (count=0, ignored=0)
function PlantSimEngine.run!(::BoundaryCounterModel, status, environment, constants, context)
    status.count += 1
    status.ignored += 10
end

function boundary_output_publication_allocations(bindings, time)
    return @allocated PlantSimEngine._model_publish_runtime_outputs!(
        bindings,
        time,
    )
end

@testset "direct output bindings preserve stream type errors" begin
    stream = Tuple{Float64,Float64}[]
    reference = Ref{Any}(1.0)
    output = PlantSimEngine.RuntimeOutputStream{
        :value,
        typeof(stream),
        typeof(reference),
    }(stream, reference, 0.0)
    PlantSimEngine._model_publish_runtime_outputs!((output,), 1.0)
    @test stream == [(1.0, 1.0)]
    reference[] = :wrong_type
    @test_throws "stable output type" PlantSimEngine._model_publish_runtime_outputs!(
        (output,),
        2.0,
    )
end

PlantSimEngine.@process "boundary_manual_counter" verbose = false
PlantSimEngine.@process "boundary_manual_controller" verbose = false

struct BoundaryManualCounterModel <: AbstractBoundary_Manual_CounterModel end
struct BoundaryManualControllerModel <: AbstractBoundary_Manual_ControllerModel end

PlantSimEngine.inputs_(::BoundaryManualCounterModel) = NamedTuple()
PlantSimEngine.outputs_(::BoundaryManualCounterModel) = (count=0,)
function PlantSimEngine.run!(
    ::BoundaryManualCounterModel,
    status,
    environment,
    constants,
    context,
)
    status.count += 1
end

PlantSimEngine.inputs_(::BoundaryManualControllerModel) = NamedTuple()
PlantSimEngine.outputs_(::BoundaryManualControllerModel) = (step=0,)
function PlantSimEngine.run!(
    ::BoundaryManualControllerModel,
    status,
    environment,
    constants,
    context,
)
    status.step += 1
    status.step == 2 && run_call!(context, :counter; publish=true)
end

@testset "one step over several objects" begin
    model = CompositeModel(
        Object(:leaf_b; scale=:Leaf),
        Object(:leaf_a; scale=:Leaf);
        applications=(
            ModelSpec(BoundaryCounterModel(); name=:leaf_counter, on=Many(scale=:Leaf)),
        ),
        environment=(duration=Hour(1),),
    )
    simulation = run!(
        model;
        outputs=OutputRequest(:Leaf, :count; name=:leaf_counts),
    )
    requested = collect_outputs(simulation, :leaf_counts; sink=nothing)
    @test length(requested) == 2
    @test getproperty.(requested, :object_id) == [:leaf_a, :leaf_b]
    @test unique(getproperty.(requested, :timestep)) == [1]
    @test unique(getproperty.(requested, :application_id)) == [:leaf_counter]

    selected = collect_outputs(simulation, :leaf_counts; sink=nothing)
    @test length(selected) == 2
    @test all(row -> row.variable == :count, selected)
    @test Set(keys(outputs(simulation))) == Set([
        (:leaf_counter, ObjectId(:leaf_a), :count),
        (:leaf_counter, ObjectId(:leaf_b), :count),
    ])
    batch = only(simulation.execution_plan.batches)
    @test batch.output_publication.enabled
    @test batch.output_publication.variables == (:count,)
    @test only(explain_execution_plan(simulation)).output_publication ==
          :direct_stream_bindings
    for target in batch.targets
        output = only(target.output_bindings)
        @test PlantSimEngine._runtime_output_variable(output) == :count
        @test output.stream === outputs(simulation)[
            (:leaf_counter, target.object_id, :count)
        ]
        boundary_output_publication_allocations(target.output_bindings, 1.0)
        @test boundary_output_publication_allocations(
            target.output_bindings,
            1.0,
        ) == 0
    end
end

@testset "held manual output spans the requested timeline" begin
    model = CompositeModel(
        Object(:scene; scale=:Scene),
        Object(:leaf; scale=:Leaf, parent=:scene);
        applications=(
            ModelSpec(BoundaryManualControllerModel(); name=:controller, on=One(scale=:Scene), calls=(:counter => One(
                        scale=:Leaf,
                        application=:manual_counter,
                    ),)),
            ModelSpec(BoundaryManualCounterModel(); name=:manual_counter, on=One(scale=:Leaf)),
        ),
        environment=[(duration=Hour(1),) for _ in 1:4],
    )
    simulation = run!(
        model;
        steps=4,
        outputs=OutputRequest(
            :Leaf,
            :count;
            name=:held_manual_count,
            application=:manual_counter,
            policy=HoldLast(),
        ),
    )
    requested = collect_outputs(
        simulation,
        :held_manual_count;
        sink=nothing,
    )
    @test getproperty.(requested, :timestep) == [1, 2, 3, 4]
    @test getproperty.(requested, :value) == [0, 1, 1, 1]
    @test outputs(simulation)[
        (:manual_counter, ObjectId(:leaf), :count)
    ] == [(2.0, 1)]
end

@testset "implicit output request prefers the root-scheduled publisher" begin
    model = CompositeModel(
        Object(:scene; scale=:Scene),
        Object(:leaf; scale=:Leaf, parent=:scene);
        applications=(
            ModelSpec(BoundaryManualControllerModel(); name=:controller, on=One(scale=:Scene), calls=(:counter => One(
                        scale=:Leaf,
                        application=:manual_counter,
                    ),)),
            ModelSpec(BoundaryManualCounterModel(); name=:scheduled_counter, on=One(scale=:Leaf)),
            ModelSpec(BoundaryManualCounterModel(); name=:manual_counter, on=One(scale=:Leaf)),
        ),
        environment=[(duration=Hour(1),) for _ in 1:2],
    )
    simulation = run!(
        model;
        steps=2,
        outputs=OutputRequest(:Leaf, :count; name=:scheduled_count),
    )
    requested = collect_outputs(simulation, :scheduled_count; sink=nothing)
    @test length(requested) == 2
    @test unique(getproperty.(requested, :application_id)) == [:scheduled_counter]
end

@testset "object count multiplied by cadence" begin
    model = CompositeModel(
        Object(:leaf_2; scale=:Leaf),
        Object(:leaf_1; scale=:Leaf),
        Object(:plant; scale=:Plant);
        applications=(
            ModelSpec(BoundaryCounterModel(); name=:hourly_leaves, on=Many(scale=:Leaf), every=Hour(1)),
            ModelSpec(BoundaryCounterModel(); name=:daily_plant, on=One(scale=:Plant), every=Day(1)),
        ),
        environment=[(duration=Hour(1),) for _ in 1:48],
    )
    simulation = run!(model; steps=48, outputs=:all)
    rows = collect_outputs(simulation; sink=nothing)
    leaf_rows = filter(row -> row.application_id == :hourly_leaves && row.variable == :count, rows)
    plant_rows = filter(row -> row.application_id == :daily_plant && row.variable == :count, rows)
    @test length(leaf_rows) == 2 * 48
    @test length(plant_rows) == 2
    @test Set(getproperty.(leaf_rows, :object_id)) == Set((:leaf_1, :leaf_2))
    @test all(row -> row.object_id == :plant, plant_rows)
    @test all(
        batch.output_publication.variables == (:count, :ignored)
        for batch in simulation.execution_plan.batches
    )
end

@testset "lifecycle targets receive direct output bindings" begin
    model = CompositeModel(
        Object(:leaf_1; scale=:Leaf);
        applications=(
            ModelSpec(
                BoundaryCounterModel();
                name=:leaf_counter,
                on=Many(scale=:Leaf),
            ),
        ),
        environment=(duration=Hour(1),),
    )
    simulation = run!(
        model;
        outputs=OutputRequest(
            :Leaf,
            :count;
            name=:leaf_counts,
            application=:leaf_counter,
        ),
    )
    register_object!(model, Object(:leaf_2; scale=:Leaf))
    continue!(simulation)

    new_target = only(
        target for batch in simulation.execution_plan.batches
        for target in batch.targets
        if target.object_id == ObjectId(:leaf_2)
    )
    output = only(new_target.output_bindings)
    @test PlantSimEngine._runtime_output_variable(output) == :count
    @test output.stream === outputs(simulation)[
        (:leaf_counter, ObjectId(:leaf_2), :count)
    ]
    new_rows = filter(
        row -> row.object_id == :leaf_2,
        collect_outputs(simulation, :leaf_counts; sink=nothing),
    )
    @test getproperty.(new_rows, :timestep) == [2]
    @test getproperty.(new_rows, :value) == [1]
end

@testset "output request membership intervals follow topology" begin
    model = CompositeModel(
        Object(:scene; scale=:Scene),
        Object(:plant_1; scale=:Plant, parent=:scene),
        Object(:plant_2; scale=:Plant, parent=:scene),
        Object(:leaf; scale=:Leaf, parent=:plant_1);
        applications=(
            ModelSpec(
                BoundaryCounterModel();
                name=:leaf_counter,
                on=Many(scale=:Leaf),
            ),
        ),
        environment=(duration=Hour(1),),
    )
    request = OutputRequest(
        Many(scale=:Leaf, within=Subtree()),
        :count;
        name=:plant_1_leaves,
        application=:leaf_counter,
        context=:plant_1,
    )
    simulation = run!(model; steps=2, outputs=request)
    reparent_object!(model, :leaf, :plant_2)
    continue!(simulation; steps=2)
    reparent_object!(model, :leaf, :plant_1)
    continue!(simulation; steps=2)
    remove_object!(model, :leaf)
    continue!(simulation)

    rows = collect_outputs(
        simulation,
        :plant_1_leaves;
        sink=nothing,
    )
    @test getproperty.(rows, :timestep) == [1, 2, 5, 6]
    @test getproperty.(rows, :value) == [1, 2, 5, 6]
    @test all(row -> row.object_id == :leaf, rows)
    target = simulation.output_request_targets[
        :plant_1_leaves
    ][2][ObjectId(:leaf)]
    @test [
        (membership.start_time, membership.end_time)
        for membership in target.memberships
    ] == [(0.0, 2.0), (5.0, 6.0)]
end

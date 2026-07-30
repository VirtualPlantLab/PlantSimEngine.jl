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
end

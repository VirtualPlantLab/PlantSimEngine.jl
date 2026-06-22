using Dates
using PlantSimEngine
using Test

PlantSimEngine.@process "boundary_counter" verbose = false
struct BoundaryCounterModel <: AbstractBoundary_CounterModel end
PlantSimEngine.inputs_(::BoundaryCounterModel) = NamedTuple()
PlantSimEngine.outputs_(::BoundaryCounterModel) = (count=0, ignored=0)
function PlantSimEngine.run!(::BoundaryCounterModel, models, status, meteo, constants, extra)
    status.count += 1
    status.ignored += 10
end

@testset "one step over several objects" begin
    model = CompositeModel(
        Object(:leaf_b; scale=:Leaf),
        Object(:leaf_a; scale=:Leaf);
        applications=(
            ModelSpec(BoundaryCounterModel(); name=:leaf_counter) |>
                AppliesTo(Many(scale=:Leaf)),
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

@testset "object count multiplied by cadence" begin
    model = CompositeModel(
        Object(:leaf_2; scale=:Leaf),
        Object(:leaf_1; scale=:Leaf),
        Object(:plant; scale=:Plant);
        applications=(
            ModelSpec(BoundaryCounterModel(); name=:hourly_leaves) |>
                AppliesTo(Many(scale=:Leaf)) |>
                TimeStep(Hour(1)),
            ModelSpec(BoundaryCounterModel(); name=:daily_plant) |>
                AppliesTo(One(scale=:Plant)) |>
                TimeStep(Day(1)),
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

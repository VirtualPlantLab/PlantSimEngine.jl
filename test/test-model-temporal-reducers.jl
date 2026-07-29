using Dates
using PlantSimEngine
using Test

PlantSimEngine.@process "temporal_reducer_source" verbose = false
PlantSimEngine.@process "temporal_reducer_one_arg" verbose = false
PlantSimEngine.@process "temporal_reducer_two_arg" verbose = false

struct TemporalReducerSourceModel <: AbstractTemporal_Reducer_SourceModel end
struct TemporalReducerOneArgModel <: AbstractTemporal_Reducer_One_ArgModel end
struct TemporalReducerTwoArgModel <: AbstractTemporal_Reducer_Two_ArgModel end
PlantSimEngine.inputs_(::TemporalReducerSourceModel) = NamedTuple()
PlantSimEngine.outputs_(::TemporalReducerSourceModel) = (signal=0.0,)
function PlantSimEngine.run!(::TemporalReducerSourceModel, status, meteo, constants, extra)
    status.signal += 1
end
PlantSimEngine.inputs_(::Union{TemporalReducerOneArgModel,TemporalReducerTwoArgModel}) = (reduced=0.0,)
PlantSimEngine.outputs_(::TemporalReducerOneArgModel) = (one_arg=0.0,)
PlantSimEngine.outputs_(::TemporalReducerTwoArgModel) = (two_arg=0.0,)
PlantSimEngine.run!(::TemporalReducerOneArgModel, status, meteo, constants, extra) =
    (status.one_arg = status.reduced)
PlantSimEngine.run!(::TemporalReducerTwoArgModel, status, meteo, constants, extra) =
    (status.two_arg = status.reduced)

@testset "duration-aware and callable reducers" begin
    @test RadiationEnergy()([100.0, 200.0], [1800.0, 3600.0]) ≈ 0.9
    @test RadiationEnergy()([big"100", big"200"], [1800.0, 3600.0]) isa BigFloat

    one_arg = values -> maximum(values) - minimum(values)
    two_arg = (values, durations) -> sum(values .* durations)
    model = CompositeModel(
        Object(:leaf; scale=:Leaf);
        applications=(
            ModelSpec(TemporalReducerSourceModel(); name=:source) |>
                AppliesTo(One(scale=:Leaf)) |>
                TimeStep(Hour(1)),
            ModelSpec(TemporalReducerOneArgModel(); name=:one_arg) |>
                AppliesTo(One(scale=:Leaf)) |>
                Inputs(:reduced => One(
                    scale=:Leaf,
                    application=:source,
                    var=:signal,
                    policy=Aggregate(one_arg),
                    window=Hour(3),
                )) |>
                TimeStep(Hour(3)),
            ModelSpec(TemporalReducerTwoArgModel(); name=:two_arg) |>
                AppliesTo(One(scale=:Leaf)) |>
                Inputs(:reduced => One(
                    scale=:Leaf,
                    application=:source,
                    var=:signal,
                    policy=Aggregate(two_arg),
                    window=Hour(3),
                )) |>
                TimeStep(Hour(3)),
        ),
        environment=(duration=Hour(1),),
    )
    run!(model; steps=4)
    status = only(model_objects(model)).status
    @test status.one_arg == 2.0
    @test status.two_arg == 9 * 3600.0

    invalid = (a, b, c) -> 0
    invalid_scene = CompositeModel(
        Object(:leaf; scale=:Leaf);
        applications=(
            ModelSpec(TemporalReducerSourceModel(); name=:source) |>
                AppliesTo(One(scale=:Leaf)),
            ModelSpec(TemporalReducerOneArgModel(); name=:consumer) |>
                AppliesTo(One(scale=:Leaf)) |>
                Inputs(:reduced => One(
                    scale=:Leaf,
                    application=:source,
                    var=:signal,
                    policy=Aggregate(invalid),
                )),
        ),
    )
    @test_throws "must accept values or values and durations" Advanced.refresh_bindings!(invalid_scene)
end

@testset "coarse producer samples are weighted by held overlap" begin
    observed_segments = Ref{Any}(nothing)
    integral = function (values, durations)
        if length(values) == 3
            observed_segments[] = (values=copy(values), durations=copy(durations))
        end
        return sum(values .* durations)
    end
    weighted_mean = (values, durations) -> sum(values .* durations) / sum(durations)

    model = CompositeModel(
        Object(:leaf; scale=:Leaf);
        applications=(
            ModelSpec(TemporalReducerSourceModel(); name=:source) |>
                AppliesTo(One(scale=:Leaf)) |>
                TimeStep(Hour(2)),
            ModelSpec(TemporalReducerTwoArgModel(); name=:integral) |>
                AppliesTo(One(scale=:Leaf)) |>
                Inputs(:reduced => One(
                    scale=:Leaf,
                    application=:source,
                    var=:signal,
                    policy=Aggregate(integral),
                    window=Hour(4),
                )) |>
                TimeStep(Hour(4)),
            ModelSpec(TemporalReducerOneArgModel(); name=:weighted_mean) |>
                AppliesTo(One(scale=:Leaf)) |>
                Inputs(:reduced => One(
                    scale=:Leaf,
                    application=:source,
                    var=:signal,
                    policy=Aggregate(weighted_mean),
                    window=Hour(4),
                )) |>
                TimeStep(Hour(4)),
        ),
        environment=(duration=Hour(1),),
    )

    retention = only(
        row for row in explain_output_retention(model)
        if row.application_id == :source && row.variable == :signal
    )
    @test retention.retention_steps == 5.0

    run!(model; steps=5)
    @test observed_segments[].values == [1.0, 2.0, 3.0]
    @test observed_segments[].durations == [3600.0, 7200.0, 3600.0]
    status = only(model_objects(model)).status
    @test status.two_arg == 28_800.0
    @test status.one_arg == 2.0
end

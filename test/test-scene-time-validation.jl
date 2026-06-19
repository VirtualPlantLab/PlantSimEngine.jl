using Dates
using PlantSimEngine
using Test

PlantSimEngine.@process "time_validation_counter" verbose = false
struct TimeValidationCounterModel <: AbstractTime_Validation_CounterModel end
PlantSimEngine.inputs_(::TimeValidationCounterModel) = NamedTuple()
PlantSimEngine.outputs_(::TimeValidationCounterModel) = (count=0,)
function PlantSimEngine.run!(::TimeValidationCounterModel, models, status, meteo, constants, extra)
    status.count += 1
end

function time_validation_scene(environment; cadence=nothing)
    spec = ModelSpec(TimeValidationCounterModel(); name=:counter) |>
           AppliesTo(One(scale=:Scene))
    isnothing(cadence) || (spec = spec |> TimeStep(cadence))
    return Scene(
        Object(:scene; scale=:Scene);
        applications=(spec,),
        environment=environment,
    )
end

@testset "environment duration validation" begin
    @test_throws "Missing required `duration` in meteorology row 1" Advanced.refresh_bindings!(
        time_validation_scene([(T=20.0,)])
    )
    @test_throws "meteorology row 2" Advanced.refresh_bindings!(
        time_validation_scene([(T=20.0, duration=Hour(1)), (T=21.0,)])
    )
    @test_throws "Invalid duration" Advanced.refresh_bindings!(
        time_validation_scene([(duration="one hour",)])
    )
    @test_throws "positive period" Advanced.refresh_bindings!(
        time_validation_scene([(duration=Hour(0),)])
    )
    @test_throws "positive period" Advanced.refresh_bindings!(
        time_validation_scene([(duration=Hour(-1),)])
    )
    @test_throws "Inconsistent `duration` in meteorology row 2" Advanced.refresh_bindings!(
        time_validation_scene([(duration=Hour(1),), (duration=Minute(30),)])
    )
    @test_throws "shorter than the simulation base step" Advanced.refresh_bindings!(
        time_validation_scene([(duration=Hour(1),)]; cadence=Minute(30))
    )
    @test_throws "Unsupported non-fixed period" Advanced.refresh_bindings!(
        time_validation_scene([(duration=Hour(1),)]; cadence=Month(1))
    )
end

@testset "CompoundPeriod base step" begin
    base = Dates.CompoundPeriod(Minute(30))
    scene = time_validation_scene([(duration=base,) for _ in 1:48]; cadence=Day(1))
    compiled = Advanced.refresh_bindings!(scene)
    schedule = only(explain_schedule(compiled))
    @test schedule.dt_steps == 48.0
    @test schedule.dt_seconds == 86_400.0
    simulation = run!(scene; steps=1, outputs=:all)
    @test only(scene_objects(scene)).status.count == 1
    @test length(scene_outputs(simulation)[(:counter, ObjectId(:scene), :count)]) == 1
end

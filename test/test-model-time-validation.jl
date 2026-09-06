using Dates
using PlantSimEngine
using Test

PlantSimEngine.@process "time_validation_counter" verbose = false
struct TimeValidationCounterModel <: AbstractTime_Validation_CounterModel end
PlantSimEngine.inputs_(::TimeValidationCounterModel) = NamedTuple()
PlantSimEngine.outputs_(::TimeValidationCounterModel) = (count=0,)
function PlantSimEngine.run!(::TimeValidationCounterModel, status, environment, constants, context)
    status.count += 1
end

PlantSimEngine.@process "time_validation_override_hint" verbose = false
struct TimeValidationOverrideHintModel <: AbstractTime_Validation_Override_HintModel end
PlantSimEngine.inputs_(::TimeValidationOverrideHintModel) = NamedTuple()
PlantSimEngine.outputs_(::TimeValidationOverrideHintModel) = (count=0,)
PlantSimEngine.timestep_hint(::Type{<:TimeValidationOverrideHintModel}) = Day(1)
function PlantSimEngine.run!(::TimeValidationOverrideHintModel, status, environment, constants, context)
    status.count += 1
end

struct TimeValidationBackend <: PlantSimEngine.EnvironmentAPI.AbstractEnvironmentBackend end
PlantSimEngine.EnvironmentAPI.base_step_seconds(::TimeValidationBackend) = Inf

struct TimeValidationRangeHintModel <: AbstractTime_Validation_CounterModel end
PlantSimEngine.outputs_(::TimeValidationRangeHintModel) = (count=0,)
PlantSimEngine.timestep_hint(::TimeValidationRangeHintModel) = (Microsecond(100), Microsecond(100))
function PlantSimEngine.run!(::TimeValidationRangeHintModel, status, environment, constants, context)
    status.count += 1
    return nothing
end

@testset "equivalent duration representations at hint range endpoints" begin
    for duration in (1.0e-4, Microsecond(100))
        model = CompositeModel(TimeValidationRangeHintModel(); environment=(duration=duration,))
        @test final_state(run!(model; steps=3)).count == 3
    end
    @test_throws "outside `timestep_hint.required" run!(CompositeModel(
        TimeValidationRangeHintModel(); environment=(duration=1.01e-4,),
    ))
end

function time_validation_scene(environment; cadence=nothing)
    spec = ModelSpec(
        TimeValidationCounterModel();
        name=:counter,
        on=One(scale=:Scene),
        every=cadence,
    )
    return CompositeModel(
        Object(:scene; scale=:Scene);
        applications=(spec,),
        environment=environment,
    )
end

@testset "environment duration validation" begin
    @test_throws "Missing required `duration` in environment row 1" Advanced.refresh_bindings!(
        time_validation_scene([(T=20.0,)])
    )
    @test_throws "environment row 2" Advanced.refresh_bindings!(
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
    @test_throws "Inconsistent `duration` in environment row 2" Advanced.refresh_bindings!(
        time_validation_scene([(duration=Hour(1),), (duration=Minute(30),)])
    )
    @test_throws "shorter than the simulation base step" Advanced.refresh_bindings!(
        time_validation_scene([(duration=Hour(1),)]; cadence=Minute(30))
    )
    @test_throws "Unsupported non-fixed period" Advanced.refresh_bindings!(
        time_validation_scene([(duration=Hour(1),)]; cadence=Month(1))
    )
    @test_throws "integer multiple" Advanced.refresh_bindings!(
        time_validation_scene((duration=Hour(1),); cadence=Minute(90))
    )
    @test_throws "finite duration" Advanced.refresh_bindings!(
        time_validation_scene((duration=Inf,))
    )
    @test_throws "invalid base step seconds" Advanced.refresh_bindings!(
        time_validation_scene(TimeValidationBackend())
    )
    @test_throws "Inconsistent `duration` in environment row 2" Advanced.refresh_bindings!(
        time_validation_scene([(duration=Nanosecond(1),), (duration=Nanosecond(2),)])
    )
end

@testset "subsecond fixed periods preserve cadence" begin
    for (base, cadence) in (
        (Millisecond(100), Millisecond(200)),
        (Microsecond(100), Microsecond(300)),
        (Nanosecond(100), Nanosecond(300)),
    )
        model = time_validation_scene((duration=base,); cadence=cadence)
        simulation = run!(model; steps=7, outputs=:all)
        interval = div(Dates.value(cadence), Dates.value(base))
        samples = outputs(simulation)[(:counter, ObjectId(:scene), :count)]
        @test first.(samples) == collect(1:interval:7)
        @test final_state(simulation).count == length(1:interval:7)
        @test only(explain_schedule(simulation)).dt_steps == interval
    end
    @test PlantSimEngine._seconds_from_period(Microsecond(1)) == 1.0e-6
    @test PlantSimEngine._period_to_seconds(Day(365_000)) == 31_536_000_000.0
    mixed_units = time_validation_scene((duration=1.0e-4,); cadence=Microsecond(100))
    @test final_state(run!(mixed_units; steps=3)).count == 3
end

@testset "CompoundPeriod base step" begin
    base = Dates.CompoundPeriod(Minute(30))
    model = time_validation_scene([(duration=base,) for _ in 1:48]; cadence=Day(1))
    compiled = Advanced.refresh_bindings!(model)
    schedule = only(explain_schedule(compiled))
    @test schedule.dt_steps == 48.0
    @test schedule.dt_seconds == 86_400.0
    simulation = run!(model; steps=1, outputs=:all)
    @test only(model_objects(model)).status.count == 1
    @test length(outputs(simulation)[(:counter, ObjectId(:scene), :count)]) == 1
end

@testset "object overrides preserve timestep hints" begin
    template = CompositeModelTemplate((
        ModelSpec(TimeValidationOverrideHintModel(); name=:counter, on=Many(scale=:Leaf)),
    ))
    instance = ObjectInstance(
        :plant,
        template;
        root=Object(:plant_root; scale=:Plant),
        objects=(
            Object(:leaf_a; scale=:Leaf, parent=:plant_root),
            Object(:leaf_b; scale=:Leaf, parent=:plant_root),
        ),
        object_overrides=(
            Override(
                object=:leaf_b,
                application=:counter,
                model=TimeValidationOverrideHintModel(),
            ),
        ),
    )
    model = CompositeModel(instance; environment=(duration=Hour(1),))
    @test_throws "outside `timestep_hint.required=1 day`" Advanced.refresh_bindings!(model)
end

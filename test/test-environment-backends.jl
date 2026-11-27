using Dates

@testset "Environment backend contract" begin
    context = EnvironmentContext(
        :leaf_energy,
        ObjectId(:leaf_1),
        :Leaf,
        :energy_balance,
    )
    handle = nothing
    backend = GlobalConstant(
        Atmosphere(
            T=20.0,
            Rh=0.65,
            Wind=1.0,
            CO2=410.0,
            duration=Dates.Hour(1),
        ),
    )

    @test sample(backend, handle, :T, 1.0) == 20.0
    @test sample(backend, handle, (T=23.0,), :T, 1.0) == 23.0
    @test sample_environment(backend, handle, 1.0, (:T,)).T == 20.0
    @test sample_environment(backend, handle, (T=23.0,), 1.0, (:T,)).T == 23.0
    @test PlantSimEngine.EnvironmentAPI.get_nsteps(backend) == 1
    @test base_step_seconds(backend) == 3600.0
    @test environment_variables(GlobalConstant(nothing)) == Set{Symbol}()

    @test_throws "does not provide variable `missing`" sample(
        backend,
        handle,
        :missing,
        1.0,
    )
    @test_throws "GlobalConstant is immutable" commit_environment!(
        backend,
        handle,
        (T=21.0,),
        1.0,
    )
end

@testset "GlobalConstant infers duration from heterogeneous time-step rows" begin
    sample_duration(backend, time) = sample(backend, nothing, :duration, time)
    sample_duration(backend, state, time) = sample(backend, nothing, state, :duration, time)

    row = (
        date=DateTime(2026, 1, 1),
        duration=3600.0,
        air_temperature=20.0,
        raining=false,
        observation_index=1,
        source_temperature=22.0,
    )
    backend = GlobalConstant(TimeStepTable([row]))
    trial = TimeStepTable([merge(row, (duration=1800.0,))])

    @test (@inferred sample_duration(backend, 1.0)) === 3600.0
    @test (@inferred sample_duration(backend, trial, 1.0)) === 1800.0
end

@testset "GlobalConstant reads the base step from time-step table rows" begin
    for (duration, seconds) in (
        (1800.5, 1800.5),
        (Minute(30), 1800.0),
        (Dates.CompoundPeriod(Minute(30), Second(1)), 1801.0),
    )
        forcing = TimeStepTable([(T=20.0, duration=duration, raining=false)])
        @test base_step_seconds(GlobalConstant(forcing)) === seconds
    end

    @test_throws "Missing required `duration` in environment." base_step_seconds(
        GlobalConstant(TimeStepTable([(T=20.0, raining=false)])),
    )
    @test_throws "Invalid duration `nothing` in environment." base_step_seconds(
        GlobalConstant(TimeStepTable([(T=20.0, duration=nothing)])),
    )
    @test_throws "Invalid duration `missing` in environment." base_step_seconds(
        GlobalConstant(TimeStepTable([(T=20.0, duration=missing)])),
    )
    @test_throws "Expected a finite duration" base_step_seconds(
        GlobalConstant(TimeStepTable([(T=20.0, duration=Inf)])),
    )
end

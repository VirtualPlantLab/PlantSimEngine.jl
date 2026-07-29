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
    @test PlantSimEngine.get_nsteps(backend) == 1
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

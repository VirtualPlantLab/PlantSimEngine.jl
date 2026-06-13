using Dates

@testset "Environment backend contract" begin
    support = EnvironmentSupport(:leaf_energy, :Leaf, :energy_balance, nothing)
    backend = GlobalConstant(
        Atmosphere(
            T=20.0,
            Rh=0.65,
            Wind=1.0,
            CO2=410.0,
            duration=Dates.Hour(1),
        ),
    )

    @test sample(backend, :T, support, 1.0) == 20.0
    @test PlantSimEngine.get_nsteps(backend) == 1
    @test base_step_seconds(backend) == 3600.0
    @test environment_variables(GlobalConstant(nothing)) == Set{Symbol}()

    @test_throws "leaf_energy/Leaf/energy_balance" sample(
        backend,
        :missing,
        support,
        1.0,
    )
    @test_throws "GlobalConstant is immutable" scatter!(
        backend,
        :T,
        support,
        21.0,
        1.0,
    )
end

@testset "Chech status and weather correspond" begin
    st = Status(Rₛ=13.747, sky_fraction=1.0, d=0.03, PPFD=1500)
    tst1 = TimeStepTable([st])
    tst2 = TimeStepTable([st, st])
    tst3 = TimeStepTable([st, st, st])

    atm = Atmosphere(T=25.0, Wind=5.0, Rh=0.3)
    w1 = Weather([atm])
    w2 = Weather([atm, atm])
    w3 = Weather([atm, atm, atm])

    # Status and Atmosphere are always authorized
    @test PlantSimEngine.check_dimensions(st, atm) === nothing

    # TimeStepTable and Atmosphere are always authorized
    @test PlantSimEngine.check_dimensions(tst1, atm) === nothing
    @test PlantSimEngine.check_dimensions(tst2, atm) === nothing

    # Status and Weather are always authorized
    @test PlantSimEngine.check_dimensions(st, w1) === nothing
    @test PlantSimEngine.check_dimensions(st, w2) === nothing

    # TimeStepTable and Weather must be checked for equal length
    @test PlantSimEngine.check_dimensions(tst1, w1) === nothing
    @test PlantSimEngine.check_dimensions(tst2, w2) === nothing

    # This still works because one time step is recycled:
    @test PlantSimEngine.check_dimensions(tst1, w2) === nothing

    @test_throws DimensionMismatch PlantSimEngine.check_dimensions(tst2, w1)
    @test_throws DimensionMismatch PlantSimEngine.check_dimensions(tst3, w2)

    # ModelList and Weather must be checked for equal length
    ml = ModelList([st])
    @test PlantSimEngine.check_dimensions(ml, w1) === nothing
end
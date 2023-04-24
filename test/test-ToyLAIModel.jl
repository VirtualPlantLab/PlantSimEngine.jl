# include(joinpath(pkgdir(PlantSimEngine), "examples/ToyLAIModel.jl"))
meteo_day = CSV.read(joinpath(pkgdir(PlantSimEngine), "examples/meteo_day.csv"), DataFrame, header=18)

@testset "ToyLAIModel" begin

    @test_nowarn ModelList(ToyLAIModel())
    @test_nowarn ModelList(ToyLAIModel(), status=(degree_days_cu=10,))
    @test_nowarn ModelList(
        ToyLAIModel(),
        status=(degree_days_cu=cumsum(meteo_day.degree_days),),
    )

    m = ModelList(
        ToyLAIModel(),
        status=(degree_days_cu=cumsum(meteo_day.degree_days),),
    )

    @test_nowarn run!(m)

    @test m[:degree_days_cu] == cumsum(meteo_day.degree_days)
    @test m[:LAI][begin] ≈ 0.006318927533891692
    @test m[:LAI][end] ≈ 0.0
end
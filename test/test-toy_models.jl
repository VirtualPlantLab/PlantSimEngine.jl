# include(joinpath(pkgdir(PlantSimEngine), "examples/ToyLAIModel.jl"))
# include(joinpath(pkgdir(PlantSimEngine), "examples/Beer.jl"))

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
    @test m[:LAI][begin] ≈ 0.00554987593080316
    @test m[:LAI][end] ≈ 0.0
end

@testset "ToyLAIModel+Beer" begin
    models = ModelList(
        ToyLAIModel(),
        Beer(0.5),
        status=(degree_days_cu=cumsum(meteo_day.degree_days),),
    )

    run!(models, meteo_day)

    @test mean(models.status[:aPPFD]) ≈ 9.511021781482347
    @test mean(models.status[:LAI]) ≈ 1.098492557536525
end
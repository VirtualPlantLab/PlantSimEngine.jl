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

include(joinpath(pkgdir(PlantSimEngine), "examples/Beer.jl"))
models = ModelList(
    ToyLAIModel(),
    Beer(0.5),
    status=(degree_days_cu=cumsum(meteo_day.degree_days),),
)

run!(models, meteo_day)

models.status[:aPPFD] # mol m-2 d-1

model = ModelList(
    ToyLAIModel(),
    status=(degree_days_cu=1:1300,),
)
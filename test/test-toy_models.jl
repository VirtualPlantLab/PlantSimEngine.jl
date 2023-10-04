# include(joinpath(pkgdir(PlantSimEngine), "examples/ToyLAIModel.jl"))
# include(joinpath(pkgdir(PlantSimEngine), "examples/Beer.jl"))
# include(joinpath(pkgdir(PlantSimEngine), "examples/ToyAssimGrowthModel.jl"))
# include(joinpath(pkgdir(PlantSimEngine), "examples/ToyRUEGrowthModel.jl"))

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


@testset "ToyRUEGrowthModel" begin
    rue = 0.3
    @test_nowarn ModelList(ToyRUEGrowthModel(rue))
    @test_nowarn ModelList(ToyRUEGrowthModel(rue), status=(aPPFD=[10.0, 30.0, 25.0],))

    # One time step:
    model = ModelList(
        ToyRUEGrowthModel(rue),
        status=(aPPFD=30.0,),
    )

    run!(model, executor=SequentialEx())
    @test model.status[:biomass] ≈ rue * model.status[:aPPFD]

    # Several time steps:
    model = ModelList(
        ToyRUEGrowthModel(rue),
        status=(aPPFD=[10.0, 30.0, 25.0],),
    )

    run!(model, executor=SequentialEx())
    @test model.status[:biomass] ≈ cumsum(rue * model.status[:aPPFD])
end

@testset "ToyAssimGrowthModel" begin
    @test_nowarn ModelList(ToyAssimGrowthModel())
    @test_nowarn ModelList(ToyAssimGrowthModel(), status=(A=[10.0, 30.0, 25.0],))

    # Uninitialized:
    @test to_initialize(ModelList(ToyAssimGrowthModel())) == (growth=(:aPPFD,),)

    # One time step:
    model = ModelList(
        ToyAssimGrowthModel(),
        status=(aPPFD=30.0,),
    )

    @test to_initialize(model) == NamedTuple()

    run!(model)
    @test model.status[:biomass] ≈ [4.5]

    # Several time steps:
    model = ModelList(
        ToyAssimGrowthModel(),
        status=(aPPFD=[10.0, 30.0, 25.0],),
    )

    run!(model)
    @test model.status[:biomass] ≈ cumsum(model.status[:biomass_increment])
    @test model.status[:biomass_increment] ≈ [0.8333333333333334, 4.5, 3.5833333333333335]
end

@testset "ToyLAIModel+Beer+ToyRUEGrowthModel" begin
    rue = 0.3
    models = ModelList(
        ToyLAIModel(),
        Beer(0.5),
        ToyRUEGrowthModel(rue),
        status=(degree_days_cu=cumsum(meteo_day.degree_days),),
    )

    # Match the warning on the executor, the default is ThreadedEx() but ToyRUEGrowthModel can't be run in parallel:
    @test_logs (:warn, r"A parallel executor was provided") run!(models, meteo_day)

    # If we provide a serial executor, it works without a warning:
    @test_nowarn run!(models, meteo_day, executor=SequentialEx())

    @test mean(models.status[:aPPFD]) ≈ 9.511021781482347
    @test mean(models.status[:LAI]) ≈ 1.098492557536525
    @test models.status[:biomass][end] ≈ 1041.4687939085675 rtol = 1e-4
end
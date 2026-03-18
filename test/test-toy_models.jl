meteo_day = CSV.read(joinpath(pkgdir(PlantSimEngine), "examples/meteo_day.csv"), DataFrame, header=18)

# Note (smack) : The first test's behaviour is weird to me, because there is an [Info :] that correctly indicates
# :LAI is not initialised, yet @test_nowarn doesn't capture it. I'm not sure what the intended test was, between 'Info' and 'Warn'
@testset "ToyLAIModel" begin
    @test_nowarn ModelMapping(ToyLAIModel())
    @test_nowarn ModelMapping(ToyLAIModel(); status=(TT_cu=10,))
    @test_nowarn ModelMapping(
        ToyLAIModel();
        status=(TT_cu=cumsum(meteo_day.TT),),
    )

    mapping = ModelMapping(
        ToyLAIModel();
        status=(TT_cu=cumsum(meteo_day.TT),),
    )

    outputs = @test_nowarn run!(mapping)

    @test outputs[:TT_cu] == cumsum(meteo_day.TT)
    @test outputs[:LAI][begin] ≈ 0.00554987593080316
    @test outputs[:LAI][end] ≈ 0.0
end

@testset "ToyLAIModel+Beer" begin
    mapping = ModelMapping(
        ToyLAIModel(),
        Beer(0.5),
        status=(TT_cu=cumsum(meteo_day.TT),)
    )

    outputs = run!(mapping, meteo_day)

    @test mean(outputs[:aPPFD]) ≈ 9.511021781482347
    @test mean(outputs[:LAI]) ≈ 1.098492557536525
end


@testset "ToyRUEGrowthModel" begin
    rue = 0.3
    @test_nowarn ModelMapping(ToyRUEGrowthModel(rue))
    @test_nowarn ModelMapping(ToyRUEGrowthModel(rue); status=(aPPFD=[10.0, 30.0, 25.0],))

    # One time step:
    mapping = ModelMapping(ToyRUEGrowthModel(rue); status=(aPPFD=30.0,))

    outputs = run!(mapping, executor=SequentialEx())
    @test outputs[:biomass][1] ≈ rue * 30.0

    # Several time steps:
    aPPFD = [10.0, 30.0, 25.0]
    mapping = ModelMapping(ToyRUEGrowthModel(rue); status=(aPPFD=aPPFD,))

    outputs = run!(mapping, executor=SequentialEx())
    @test outputs[:biomass] ≈ cumsum(rue * aPPFD)
end

@testset "ToyAssimGrowthModel" begin
    @test_nowarn ModelMapping(ToyAssimGrowthModel())
    @test_nowarn ModelMapping(ToyAssimGrowthModel(); status=(carbon_assimilation=[10.0, 30.0, 25.0],))

    # Uninitialized:
    to_init_uninitialized = to_initialize(ModelMapping(ToyAssimGrowthModel()))
    if to_init_uninitialized isa AbstractDict
        @test haskey(to_init_uninitialized, :Default)
        @test :aPPFD in to_init_uninitialized[:Default]
    else
        @test :growth in keys(to_init_uninitialized)
        @test :aPPFD in to_init_uninitialized[:growth]
    end

    # One time step:
    mapping = ModelMapping(ToyAssimGrowthModel(); status=(aPPFD=30.0,))

    @test isempty(to_initialize(mapping))

    outputs = run!(mapping)
    @test outputs[:biomass] ≈ [4.5]

    # Several time steps:
    mapping = ModelMapping(ToyAssimGrowthModel(); status=(aPPFD=[10.0, 30.0, 25.0],))

    outputs = run!(mapping)
    @test outputs[:biomass] ≈ cumsum(outputs[:biomass_increment])
    @test outputs[:biomass_increment] ≈ [0.8333333333333334, 4.5, 3.5833333333333335]
end

@testset "ToyLAIModel+Beer+ToyRUEGrowthModel" begin
    rue = 0.3
    mapping = ModelMapping(
        ToyLAIModel(),
        Beer(0.5),
        ToyRUEGrowthModel(rue),
        status=(TT_cu=cumsum(meteo_day.TT),),
    )

    # Match the warning on the executor, the default is ThreadedEx() but ToyRUEGrowthModel can't be run in parallel:
    @test_logs (:warn, r"A parallel executor was provided") run!(mapping, meteo_day)

    # If we provide a serial executor, it works without a warning:
    outputs = @test_nowarn run!(mapping, meteo_day, executor=SequentialEx())

    @test mean(outputs[:aPPFD]) ≈ 9.511021781482347
    @test mean(outputs[:LAI]) ≈ 1.098492557536525
    @test outputs[:biomass][end] ≈ 1041.4687939085675 rtol = 1e-4
end

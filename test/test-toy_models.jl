using Dates

function toy_scene(status, models...; environment=nothing)
    applications = map(models) do model
        ModelSpec(model) |> AppliesTo(One(scale=:Plant))
    end
    CompositeModel(
        Object(:plant; scale=:Plant, kind=:plant, status=status);
        applications=Tuple(applications),
        environment=environment,
    )
end

@testset "Toy models through CompositeModel" begin
    lai_scene = toy_scene(Status(TT_cu=900.0), ToyLAIModel())
    run!(lai_scene)
    lai_status = only(model_objects(lai_scene; scale=:Plant)).status
    @test 0.0 < lai_status.LAI < 8.0

    meteo = Atmosphere(
        T=20.0,
        Wind=1.0,
        P=101.3,
        Rh=0.65,
        Ri_PAR_f=300.0,
        duration=Hour(1),
    )
    coupled = toy_scene(Status(TT_cu=900.0), ToyLAIModel(), Beer(0.5); environment=meteo)
    run!(coupled)
    coupled_status = only(model_objects(coupled; scale=:Plant)).status
    @test coupled_status.aPPFD > 0.0

    rue = 0.3
    rue_scene = toy_scene(Status(aPPFD=30.0), ToyRUEGrowthModel(rue))
    run!(rue_scene)
    rue_status = only(model_objects(rue_scene; scale=:Plant)).status
    @test rue_status.biomass ≈ rue * 30.0

    assimilation_scene = toy_scene(Status(aPPFD=30.0), ToyAssimGrowthModel())
    run!(assimilation_scene)
    assimilation_status = only(model_objects(assimilation_scene; scale=:Plant)).status
    @test assimilation_status.biomass ≈ 4.5

    full_scene = toy_scene(
        Status(TT_cu=900.0),
        ToyLAIModel(),
        Beer(0.5),
        ToyRUEGrowthModel(rue);
        environment=meteo,
    )
    run!(full_scene)
    full_status = only(model_objects(full_scene; scale=:Plant)).status
    @test full_status.LAI > 0.0
    @test full_status.aPPFD > 0.0
    @test full_status.biomass ≈ rue * full_status.aPPFD
end

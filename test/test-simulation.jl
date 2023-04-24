# include(joinpath(pkgdir(PlantSimEngine), "examples/dummy.jl"))

@testset "Check missing model" begin
    # No problem here:
    @test_nowarn ModelList(
        process1=Process1Model(1.0),
        process2=Process2Model(),
        process3=Process3Model(),
        status=(var1=15.0, var2=0.3)
    )

    # Missing model for process2:
    @test_logs (
        :info,
        "Model Process3Model from process process3 needs a model that is a subtype of Process2Model in process process2, but the process is not parameterized in the ModelList."
    ),
    (
        :info,
        "Some variables must be initialized before simulation: (process3 = (:var5,),) (see `to_initialize()`)"
    )
    ModelList(
        process1=Process1Model(1.0),
        process3=Process3Model(),
        status=(var1=15.0, var2=0.3)
    )
end;

@testset "Simulation: 1 time-step, 0 Atmosphere" begin
    models = ModelList(
        Process1Model(1.0),
        status=(var1=15.0, var2=0.3)
    )
    run!(models)

    vars = keys(status(models))
    @test [models[i][1] for i in vars] == [15.0, 0.3, 5.5]
end;


@testset "Simulation: 1 time-step, 1 Atmosphere" begin
    models = ModelList(
        process1=Process1Model(1.0),
        process2=Process2Model(),
        process3=Process3Model(),
        status=(var1=15.0, var2=0.3)
    )

    meteo = Atmosphere(T=20.0, Wind=1.0, Rh=0.65)

    run!(models, meteo)
    vars = keys(status(models))
    @test [models[i][1] for i in vars] == [22.0, 34.95, 56.95, 15.0, 5.5, 0.3]
end;

@testset "Simulation: 1 time-step, 1 Atmosphere, 2 objects" begin
    models = ModelList(
        process1=Process1Model(1.0),
        process2=Process2Model(),
        process3=Process3Model(),
        status=(var1=15.0, var2=0.3)
    )

    models2 = ModelList(
        process1=Process1Model(2.0),
        process2=Process2Model(),
        process3=Process3Model(),
        status=(var1=15.0, var2=0.3)
    )

    meteo = Atmosphere(T=20.0, Wind=1.0, Rh=0.65)

    @testset "simulation with an array of objects" begin
        run!([models, models2], meteo)
        @test [models[i][1] for i in keys(status(models))] == [22.0, 34.95, 56.95, 15.0, 5.5, 0.3]
        @test [models2[i][1] for i in keys(status(models2))] == [26.0, 36.95, 62.95, 15.0, 6.5, 0.3]
    end

    @testset "simulation with a dict of objects" begin
        run!(Dict("mod1" => models, "mod2" => models2), meteo)
        @test [models[i][1] for i in keys(status(models))] == [22.0, 34.95, 56.95, 15.0, 5.5, 0.3]
        @test [models2[i][1] for i in keys(status(models2))] == [26.0, 36.95, 62.95, 15.0, 6.5, 0.3]
    end
end;

@testset "Simulation: 2 time-steps, 1 Atmosphere" begin
    models = ModelList(
        process1=Process1Model(1.0),
        process2=Process2Model(),
        process3=Process3Model(),
        status=(var1=[15.0, 16.0], var2=0.3)
    )

    meteo = Atmosphere(T=20.0, Wind=1.0, Rh=0.65)

    run!(models, meteo)
    vars = keys(status(models))
    @test [models[i] for i in vars] == [
        [22.0, 23.2],
        [34.95, 35.550000000000004],
        [56.95, 58.75],
        [15.0, 16.0],
        [5.5, 5.8],
        [0.3, 0.3],
    ]
end;

@testset "Simulation: 2 time-steps, 2 Atmospheres" begin
    models = ModelList(
        process1=Process1Model(1.0),
        process2=Process2Model(),
        process3=Process3Model(),
        status=(var1=[15.0, 16.0], var2=0.3)
    )

    meteo = Weather(
        [
        Atmosphere(T=20.0, Wind=1.0, Rh=0.65),
        Atmosphere(T=25.0, Wind=0.5, Rh=0.8)
    ]
    )

    run!(models, meteo)
    vars = keys(status(models))
    @test [models[i] for i in vars] == [
        [22.0, 23.2],
        [34.95, 40.0],
        [56.95, 63.2],
        [15.0, 16.0],
        [5.5, 5.8],
        [0.3, 0.3],
    ]
end;


@testset "Simulation: 2 time-steps, 2 Atmospheres, 2 objects" begin
    models = ModelList(
        process1=Process1Model(1.0),
        process2=Process2Model(),
        process3=Process3Model(),
        status=(var1=[15.0, 16.0], var2=0.3)
    )

    models2 = ModelList(
        process1=Process1Model(2.0),
        process2=Process2Model(),
        process3=Process3Model(),
        status=(var1=[15.0, 16.0], var2=0.3)
    )

    meteo = Weather(
        [
        Atmosphere(T=20.0, Wind=1.0, Rh=0.65),
        Atmosphere(T=25.0, Wind=0.5, Rh=0.8)
    ]
    )

    @testset "simulation with an array of objects" begin
        run!([models, models2], meteo)
        @test [models[i] for i in keys(status(models))] == [
            [22.0, 23.2], [34.95, 40.0], [56.95, 63.2], [15.0, 16.0], [5.5, 5.8], [0.3, 0.3]
        ]
        @test [models2[i] for i in keys(status(models2))] == [
            [26.0, 27.2], [36.95, 42.0], [62.95, 69.2], [15.0, 16.0], [6.5, 6.8], [0.3, 0.3]
        ]
    end

    @testset "simulation with a dict of objects" begin
        run!(Dict("mod1" => models, "mod2" => models2), meteo)
        @test [models[i] for i in keys(status(models))] == [
            [22.0, 23.2], [34.95, 40.0], [56.95, 63.2], [15.0, 16.0], [5.5, 5.8], [0.3, 0.3]
        ]
        @test [models2[i] for i in keys(status(models2))] == [
            [26.0, 27.2], [36.95, 42.0], [62.95, 69.2], [15.0, 16.0], [6.5, 6.8], [0.3, 0.3]
        ]
    end
end;

@testset "Simulation: 2 time-steps, 2 Atmospheres, MTG" begin
    mtg = Node(MultiScaleTreeGraph.NodeMTG("/", "Plant", 1, 1))
    internode = Node(mtg, MultiScaleTreeGraph.NodeMTG("/", "Internode", 1, 2))
    leaf = Node(mtg, MultiScaleTreeGraph.NodeMTG("<", "Leaf", 1, 2))
    leaf[:var1] = [15.0, 16.0]
    leaf[:var2] = 0.3

    models = Dict(
        "Leaf" => ModelList(
            process1=Process1Model(1.0),
            process2=Process2Model(),
            process3=Process3Model()
        )
    )

    meteo = Weather(
        [
        Atmosphere(T=20.0, Wind=1.0, Rh=0.65),
        Atmosphere(T=25.0, Wind=0.5, Rh=0.8)
    ]
    )

    init_mtg_models!(mtg, models, length(meteo))
    run!(mtg, meteo)
    df_leaf = DataFrame(leaf)
    vars = (:var4, :var6, :var5, :var1, :var2, :var3)
    @test [df_leaf[1, i] for i in vars] == [
        [22.0, 23.2],
        [56.95, 63.2],
        [34.95, 40.0],
        [15.0, 16.0],
        [0.3, 0.3],
        [5.5, 5.8],
    ]
end;


@testset "Simulation: 2 time-step, 2 Atmospheres, MTG" begin
    mtg = Node(MultiScaleTreeGraph.NodeMTG("/", "Plant", 1, 1))
    internode = Node(mtg, MultiScaleTreeGraph.NodeMTG("/", "Internode", 1, 2))
    leaf = Node(mtg, MultiScaleTreeGraph.NodeMTG("<", "Leaf", 1, 2))
    leaf[:var1] = [15.0, 16.0]
    leaf[:var2] = 0.3

    models = Dict(
        "Leaf" => ModelList(
            process1=Process1Model(1.0),
            process2=Process2Model(),
            process3=Process3Model()
        )
    )

    meteo = Weather(
        [
        Atmosphere(T=20.0, Wind=1.0, Rh=0.65),
        Atmosphere(T=25.0, Wind=0.5, Rh=0.8)
    ]
    )

    init_mtg_models!(mtg, models, length(meteo))
    run!(mtg, meteo)

    df_leaf = DataFrame(leaf)
    vars = (:var4, :var6, :var5, :var1, :var2, :var3)
    @test [df_leaf[1, i] for i in vars] == [
        [22.0, 23.2],
        [56.95, 63.2],
        [34.95, 40.0],
        [15.0, 16.0],
        [0.3, 0.3],
        [5.5, 5.8],
    ]
end;
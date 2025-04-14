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
    outputs = run!(models)

    vars = keys(outputs)
    @test [outputs[i][1] for i in vars] == [15.0, 0.3, 5.5]
end;


@testset "Simulation: 1 time-step, 1 Atmosphere" begin
    
    status_nt = (var1=15.0, var2=0.3)
    models = ModelList(
        process1=Process1Model(1.0),
        process2=Process2Model(),
        process3=Process3Model(),
        status=status_nt
    )

    meteo = Atmosphere(T=20.0, Wind=1.0, Rh=0.65)

    modellist_outputs = run!(models, meteo)
    vars = keys(modellist_outputs)
    @test [modellist_outputs[i][1] for i in vars] == [34.95, 22.0, 56.95, 15.0, 5.5, 0.3]

    mtg, mapping, out = check_multiscale_simulation_is_equivalent_begin(models, status_nt, meteo)    
    @test check_multiscale_simulation_is_equivalent_end(modellist_outputs, mtg, mapping, out, meteo)
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
        outputs_vector = run!([models, models2], meteo)
        @test [outputs_vector[1][i][1] for i in keys(outputs_vector[1])] == [34.95, 22.0, 56.95, 15.0, 5.5, 0.3]
        @test [outputs_vector[2][i][1] for i in keys(outputs_vector[2])] == [36.95, 26.0, 62.95, 15.0, 6.5, 0.3]
    end

    @testset "simulation with a dict of objects" begin
        outputs_vector = run!(Dict("mod1" => models, "mod2" => models2), meteo)
        @test [outputs_vector["mod1"][1][i] for i in keys(outputs_vector["mod1"])] == [34.95, 22.0, 56.95, 15.0, 5.5, 0.3]
        @test [outputs_vector["mod2"][1][i] for i in keys(outputs_vector["mod2"])] == [36.95, 26.0, 62.95, 15.0, 6.5, 0.3]
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

    outputs = run!(models, meteo)
    vars = keys(outputs)
    @test [outputs[i] for i in vars] == [
        [34.95, 35.550000000000004],
        [22.0, 23.2],
        [56.95, 58.75],
        [15.0, 16.0],
        [5.5, 5.8],
        [0.3, 0.3],
    ]
end;

@testset "Simulation: 2 time-steps, 2 Atmospheres" begin
    
    status_nt = (var1=[15.0, 16.0], var2=0.3)

    models = ModelList(
        process1=Process1Model(1.0),
        process2=Process2Model(),
        process3=Process3Model(),
        status=status_nt
    )

    meteo = Weather(
        [
        Atmosphere(T=20.0, Wind=1.0, Rh=0.65),
        Atmosphere(T=25.0, Wind=0.5, Rh=0.8)
    ]
    )

    modellist_outputs = run!(models, meteo)
    vars = keys(modellist_outputs)
    @test [modellist_outputs[i] for i in vars] == [
        [34.95, 40.0],
        [22.0, 23.2],
        [56.95, 63.2],
        [15.0, 16.0],
        [5.5, 5.8],
        [0.3, 0.3],
    ]

    mtg, mapping, out = check_multiscale_simulation_is_equivalent_begin(models, status_nt, meteo)    
    @test check_multiscale_simulation_is_equivalent_end(modellist_outputs, mtg, mapping, out, meteo)
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
        outputs_vector = run!([models, models2], meteo)
        @test [outputs_vector[1][i] for i in keys(outputs_vector[1])] == [
            [34.95, 40.0], [22.0, 23.2], [56.95, 63.2], [15.0, 16.0], [5.5, 5.8], [0.3, 0.3]
        ]
        @test [outputs_vector[2][i] for i in keys(outputs_vector[2])] == [
            [36.95, 42.0], [26.0, 27.2], [62.95, 69.2], [15.0, 16.0], [6.5, 6.8], [0.3, 0.3]
        ]
    end

    @testset "simulation with a dict of objects" begin
        outputs_vector = run!(Dict("mod1" => models, "mod2" => models2), meteo)
        @test [[outputs_vector["mod1"][1][i], outputs_vector["mod1"][2][i]] for i in keys(outputs_vector["mod1"])] == [
            [34.95, 40.0], [22.0, 23.2], [56.95, 63.2], [15.0, 16.0], [5.5, 5.8], [0.3, 0.3]
        ]
        @test [[outputs_vector["mod2"][1][i], outputs_vector["mod2"][2][i]] for i in keys(outputs_vector["mod2"])] == [
            [36.95, 42.0], [26.0, 27.2], [62.95, 69.2], [15.0, 16.0], [6.5, 6.8], [0.3, 0.3]
        ]
    end
end;

@testset "Simulation: 2 time-steps, 2 Atmospheres, MTG" begin
    mtg = Node(MultiScaleTreeGraph.NodeMTG("/", "Plant", 1, 1))
    internode = Node(mtg, MultiScaleTreeGraph.NodeMTG("/", "Internode", 1, 2))
    leaf = Node(mtg, MultiScaleTreeGraph.NodeMTG("<", "Leaf", 1, 2))
    leaf[:var1] = [15.0, 16.0]
    leaf[:var2] = 0.3

    mapping = Dict(
        "Leaf" => (
            Process1Model(1.0),
            Process2Model(),
            Process3Model()
        )
    )

    meteo = Weather(
        [
        Atmosphere(T=20.0, Wind=1.0, Rh=0.65),
        Atmosphere(T=25.0, Wind=0.5, Rh=0.8)
    ]
    )

    # var1 is taken from the MTG attributes but is a vector instead of a scalar, expecting an error:
    VERSION >= v"1.8" && @test_throws AssertionError run!(mtg, mapping, meteo)

    leaf[:var1] = 15.0

    #out = @test_nowarn run!(mtg, mapping, meteo)
    nsteps = PlantSimEngine.get_nsteps(meteo)
    sim = PlantSimEngine.GraphSimulation(mtg, mapping, nsteps=nsteps, check=true)
    out = @test_nowarn run!(sim,meteo)

    vars = (:var4, :var6, :var5, :var1, :var2, :var3)
    @test [sim.statuses["Leaf"][1][i] for i in vars] == [
        22.0, 61.4, 39.4, 15.0, 0.3, 5.5
    ]
end;


@testset "Meteo+ModelList/mapping+outputs combos either valid or different status vector size vs meteo length either run successfully or return a DimensionMisMatch" begin
    
    meteos = get_simple_meteo_bank()
    modellists, status_tuples, outputs_tuples_vectors = get_modellist_bank()

    for i in 1:length(modellists)
#       i = 3
        modellist = modellists[i]
        status_tuple = status_tuples[i]
        outs_vector = outputs_tuples_vectors[i]

        for j in 1:length(meteos)
#        j = 1
            meteo = meteos[j]
            for k in 1:length(outs_vector)
#            k = 7
                out_tuple = outs_vector[k]                
                @test try outs_modellist = run!(modellist, meteo; tracked_outputs=out_tuple)
                    true
                catch e
                    print(i," ", j, " ", k)
                    println()
                    if isa(e, DimensionMismatch)
                        true
                    elseif isa(e, ErrorException)
                        showerror(stdout, e)
                        false
                    else
                        showerror(stdout, e)
                        false
                    end
                end
            end
        end
    end

    mtgs, mappings, outs_tuples_vectors_mappings = get_simple_mapping_bank()

    for i in 1:length(mappings)
#        i = 1
        mapping = mappings[i]
        outs_vector = outs_tuples_vectors_mappings[i]

        for j in 1:length(meteos)
#            j = 1
            meteo = meteos[j]
            for k in 1:length(outs_vector)
#                k = 4
                out_tuple = outs_vector[k]
               
                mtg = deepcopy(mtgs[i])
                try 
                    outs_multiscale = run!(mtg, mapping, meteo; tracked_outputs=out_tuple)
                    @test true                                       
                catch e
                    print(i," ", j, " ", k)
                    println()                    
                    if isa(e, DimensionMismatch)
                        @test true
                    #elseif isa(e, ErrorException)  
                    else
                        #@enter outs_multiscale = run!(mtg, mapping, meteo; tracked_outputs=out_tuple) 
                        showerror(stdout, e)
                        @test false
                    end
                end
            end
        end
    end
end
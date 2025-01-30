# Simple helper functions that can be used in various tests here and there


function compare_outputs_modellist_mapping(models, graphsim)
    graphsim_df = outputs(graphsim, DataFrame)

    graphsim_df_outputs_only = select(graphsim_df, Not([:timestep, :organ, :node]))
    models_df = DataFrame(status(models))
    
    models_df_sorted = models_df[:, sortperm(names(models_df))]
    graphsim_df_outputs_only_sorted = graphsim_df_outputs_only[:, sortperm(names(graphsim_df_outputs_only))]
    return graphsim_df_outputs_only_sorted == models_df_sorted
end

function compare_outputs_modellist_mapping(filtered_outputs, graphsim)
    graphsim_df = outputs(graphsim, DataFrame)

    graphsim_df_outputs_only = select(graphsim_df, Not([:timestep, :organ, :node]))
    models_df = DataFrame(filtered_outputs)
    
    models_df_sorted = models_df[:, sortperm(names(models_df))]
    graphsim_df_outputs_only_sorted = graphsim_df_outputs_only[:, sortperm(names(graphsim_df_outputs_only))]
    return graphsim_df_outputs_only_sorted == models_df_sorted
end

# doesn't check for mtg equality
function compare_outputs_graphsim(graphsim, graphsim2)
    graphsim_df = outputs(graphsim, DataFrame)
    graphsim_df_sorted = graphsim_df[:, sortperm(names(graphsim_df))]
    
    graphsim2_df = outputs(graphsim2, DataFrame)
    graphsim2_df_sorted = graphsim2_df[:, sortperm(names(graphsim2_df))]
    return graphsim_df_sorted == graphsim2_df_sorted
end

# Breaking this function into two to ensure eval() state synchronisation happens (see comments around the modellist_to_mapping definition)
# Naming could be better
function check_multiscale_simulation_is_equivalent_begin(models::ModelList, status, meteo)

    mtg, mapping, out = PlantSimEngine.modellist_to_mapping(models, status; nsteps=length(meteo), outputs=nothing)
    return mtg, mapping, out
end

function check_multiscale_simulation_is_equivalent_end(models::ModelList, mtg, mapping, out, meteo)
    graph_sim = PlantSimEngine.GraphSimulation(mtg, mapping, nsteps=length(meteo), check=true, outputs=out)

    sim = run!(graph_sim,
        meteo,
        PlantMeteo.Constants(),
        nothing;
        check=true,
        executor=SequentialEx()
    );

    return compare_outputs_modellist_mapping(models, graph_sim)
end


# Could make use of PlantMeteo's online meteo data recovery feature for more numerous examples
# or the random meteo generation used for the PBP benchmark

#=using PlantMeteo, Dates, DataFrames
# Define the period of the simulation:
period = [Dates.Date("2021-01-01"), Dates.Date("2021-12-31")]
# Get the weather data for CIRAD's site in Montpellier, France:
meteo = get_weather(43.649777, 3.869889, period, sink = DataFrame)=#

function get_simple_meteo_bank()
    meteos= 
    [Atmosphere(T=20.0, Wind=1.0, P=101.3, Rh=0.65, Ri_PAR_f=300.0),
    Weather(
        [
        Atmosphere(T=20.0, Wind=1.0, Rh=0.65, Ri_PAR_f=300.0),
        Atmosphere(T=25.0, Wind=0.5, Rh=0.8, Ri_PAR_f=500.0)
    ]),
    
    Weather([Atmosphere(T=20.0, Wind=1.0, Rh=0.65, Ri_PAR_f=200.0),
    Atmosphere(T=18.0, Wind=1.0, Rh=0.65, Ri_PAR_f=100.0),
    Atmosphere(T=19.0, Wind=1.0, Rh=0.65, Ri_PAR_f=200.0),
    Atmosphere(T=30.0, Wind=0.5, Rh=0.6, Ri_PAR_f=100.0),
    Atmosphere(T=20.0, Wind=1.0, Rh=0.6, Ri_PAR_f=200.0),
    Atmosphere(T=25.0, Wind=1.0, Rh=0.6, Ri_PAR_f=200.0),
    Atmosphere(T=10.0, Wind=0.5, Rh=0.6, Ri_PAR_f=200.0)]),
    
    CSV.read(joinpath(pkgdir(PlantSimEngine), "examples/meteo_day.csv"), DataFrame, header=18),

    ]
    return meteos
end

function get_modellist_bank()
    rue = 0.3

    vals = (var1=15.0, var2=0.3, TT_cu=cumsum(meteo_day.TT))
    vals2 = (TT_cu=cumsum(meteo_day.TT),)
    vals3 = (var1=15.0, var2=0.3)
    
    status_tuples = [vals, vals2, vals3, nothing, vals3, vals3]

    models = [ModelList(
        process1=Process1Model(1.0),
        process2=Process2Model(),
        status=vals
    ),
    ModelList(
        ToyLAIModel(),
        Beer(0.5),
        ToyRUEGrowthModel(rue),
        status=vals2,
    ),

     ModelList(
        process1=Process1Model(1.0),
        process2=Process2Model(),
        process3=Process3Model(),
        status=vals3
    ),

    ModelList(
        process1=Process1Model(1.0),
        process2=Process2Model(),
        process3=Process3Model(),
        process4=Process4Model(),
        process5=Process5Model(),
        process6=Process6Model(),
        # process7=Process7Model(),
        # status=(var1=15.0, var2=0.3)
    ),

    ModelList(
        process1=Process1Model(1.0),
        process2=Process2Model(),
        process3=Process3Model(),
        process4=Process4Model(),
        process5=Process5Model(),
        process6=Process6Model(),
        process7=Process7Model(),
        status=(var1=15.0, var2=0.3)
    ),

    ModelList(
        process1=Process1Model(1.0),
        process2=Process2Model(),
        process3=Process3Model(),
        process4=Process4Model(),
        process5=Process5Model(),
        status=(var1=15.0, var2=0.3)
    ),

    ]

    outputs_tuples_vectors = 
    [
        # this one has one tuple with a duplicate, and one with a nonexistent variable
        [NamedTuple(), (:var1,), (:var1, :var1), (:var1, :var2), (:var1, :var3), (:var1, :var4, :var5), 
        (:var2, :var7, :var3, :var1), (:var1, :var2, :var3, :var4, :var5)], 

        [NamedTuple(), (:TT_cu,), (:TT_cu,:LAI) , (:biomass,:LAI), (:TT_cu, :LAI, :PPFD, :biomass, :biomass_increment),], 

        [NamedTuple(), (:var1,), (:var1, :var4), (:var1, :var2), (:var1, :var3), (:var1, :var4, :var6, :var5), 
        (:var2, :var7, :var3, :var1), (:var1, :var2, :var3, :var4, :var5, :var6)], 

        [NamedTuple(), (:var1,), (:var1, :var4), (:var1, :var2), (:var1, :var3), (:var1, :var4, :var6, :var5), 
        (:var2, :var7, :var3, :var1), (:var1, :var2, :var3, :var4, :var5, :var6)], 
        
        [NamedTuple(), (:var1,), (:var1, :var4), (:var1, :var2), (:var1, :var3), (:var1, :var4, :var6, :var5), 
        (:var2, :var7, :var3, :var1), (:var1, :var2, :var3, :var4, :var5, :var6)
        , (:var1, :var2, :var3, :var4, :var5, :var6, :var7, :var8, :var9)], 

        [NamedTuple(), (:var1,), (:var1, :var1), (:var1, :var2), (:var1, :var3), (:var1, :var4, :var6, :var5), 
        (:var2, :var7, :var3, :var1), (:var1, :var2, :var3, :var4, :var5, :var6)
        , (:var1, :var2, :var3, :var4, :var5, :var6, :var7, :var8, :var9, :var0)], 

    ]

    return models, status_tuples, outputs_tuples_vectors
end
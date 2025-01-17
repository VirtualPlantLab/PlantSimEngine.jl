# Simple helper functions that can be used in various tests here and there


function compare_outputs_modellist_mapping(models, graphsim)
    graphsim_df = outputs(graphsim, DataFrame)

    graphsim_df_outputs_only = select(graphsim_df, Not([:timestep, :organ, :node]))
    models_df = DataFrame(status(models))
    
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
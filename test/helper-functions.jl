# doesn't check for mtg equality
function compare_outputs_graphsim(graphsim, graphsim2)
    outputs_df_dict = convert_outputs(graphsim.outputs, DataFrame)
    outputs2_df_dict = convert_outputs(graphsim2.outputs, DataFrame)

    if length(outputs_df_dict) != length(outputs2_df_dict)
        return false
    end

    for (organ, vals) in outputs2_df_dict
        outputs_df_sorted = outputs_df_dict[organ][:, sortperm(names(outputs_df_dict[organ]))]
        outputs2_df_sorted = outputs2_df_dict[organ][:, sortperm(names(outputs2_df_dict[organ]))]

        if outputs_df_sorted != outputs2_df_sorted
            return false
        end
    end

    return true
end

function compare_outputs_modellists(filtered_outputs_1, filtered_outputs_2)
    models_df_1 = DataFrame(filtered_outputs_1)
    models_df_sorted_1 = models_df_1[:, sortperm(names(models_df_1))]
    models_df_2 = DataFrame(filtered_outputs_2)
    models_df_sorted_2 = models_df_2[:, sortperm(names(models_df_2))]
    return models_df_sorted_2 == models_df_sorted_1
end

function compare_outputs_modellist_mapping(filtered_outputs_modellist, graphsim)
    modellist_df = DataFrame(filtered_outputs_modellist)
    modellist_sorted = modellist_df[:, sortperm(names(modellist_df))]

    outputs_df = convert_outputs(graphsim.outputs, DataFrame)
    @assert haskey(outputs_df, :Default)
    common_cols = filter(c -> c in names(outputs_df[:Default]), names(modellist_sorted))
    mapping_sorted = outputs_df[:Default][:, common_cols]
    modellist_sorted = modellist_sorted[:, common_cols]

    # Keep deterministic order in case columns are provided in different orders.
    mapping_sorted = mapping_sorted[:, sortperm(names(mapping_sorted))]
    modellist_sorted = modellist_sorted[:, sortperm(names(modellist_sorted))]

    return modellist_sorted == mapping_sorted
end

# Helper used to compare a single-scale `ModelMapping` run with its generated
# multiscale equivalent.
function check_multiscale_simulation_is_equivalent_begin(mapping::ModelMapping, meteo)
    _, models_at_scale = only(pairs(mapping))
    status_nt = NamedTuple(something(PlantSimEngine.get_status(models_at_scale), Status()))
    models = ModelMapping(PlantSimEngine.get_models(models_at_scale)...; status=status_nt)
    mtg, mapping, out = PlantSimEngine.modellist_to_mapping(models, status_nt; nsteps=length(meteo), outputs=nothing)
    return mtg, mapping, out
end

function check_multiscale_simulation_is_equivalent_end(modellist_outputs, mtg, mapping, out, meteo)
    graph_sim = PlantSimEngine.GraphSimulation(mtg, mapping, nsteps=PlantSimEngine.get_nsteps(meteo), check=true, outputs=out)

    sim = run!(graph_sim,
        meteo,
        PlantMeteo.Constants(),
        nothing;
        check=true,
        executor=SequentialEx()
    )

    return compare_outputs_modellist_mapping(modellist_outputs, graph_sim)
end

function check_multiscale_simulation_is_equivalent(mapping::ModelMapping, meteo)
    modellist_outputs = run!(mapping, meteo)
    mtg, mapping_mt, out = check_multiscale_simulation_is_equivalent_begin(mapping, meteo)
    return check_multiscale_simulation_is_equivalent_end(modellist_outputs, mtg, mapping_mt, out, meteo)
end

# Quick and naive first version. Doesn't check if everything is timestep parallelizable, doesn't check for nthreads etc.
function run_single_and_multi_thread_modellist(mapping::ModelMapping, tracked_outputs, meteo)
    out_seq = run!(mapping, meteo; tracked_outputs=tracked_outputs, executor=SequentialEx())
    mapping_mt = copy(mapping)
    out_mt = run!(mapping_mt, meteo; tracked_outputs=tracked_outputs, executor=ThreadedEx())
    return out_seq, out_mt
end

# Could make use of PlantMeteo's online meteo data recovery feature for more numerous examples
# or the random meteo generation used for the PBP benchmark

#=using PlantMeteo, Dates, DataFrames
# Define the period of the simulation:
period = [Dates.Date("2021-01-01"), Dates.Date("2021-12-31")]
# Get the weather data for CIRAD's site in Montpellier, France:
meteo = get_weather(43.649777, 3.869889, period, sink = DataFrame)=#

function get_simple_meteo_bank()

    df = CSV.read(joinpath(pkgdir(PlantSimEngine), "examples/meteo_day.csv"), DataFrame, header=18)


    meteos =
        [Atmosphere(T=20.0, Wind=1.0, P=101.3, Rh=0.65, Ri_PAR_f=300.0), #=nothing,=#
            Weather([Atmosphere(T=20.0, Wind=1.0, P=101.3, Rh=0.65)]),
            Weather(
                [
                Atmosphere(T=20.0, Wind=1.0, Rh=0.65, Ri_PAR_f=300.0),
                Atmosphere(T=25.0, Wind=0.5, Rh=0.8, Ri_PAR_f=500.0)
            ]), Weather([Atmosphere(T=20.0, Wind=1.0, Rh=0.65, Ri_PAR_f=200.0),
                Atmosphere(T=18.0, Wind=1.0, Rh=0.65, Ri_PAR_f=100.0),
                Atmosphere(T=19.0, Wind=1.0, Rh=0.65, Ri_PAR_f=200.0),
                Atmosphere(T=30.0, Wind=0.5, Rh=0.6, Ri_PAR_f=100.0),
                Atmosphere(T=20.0, Wind=1.0, Rh=0.6, Ri_PAR_f=200.0),
                Atmosphere(T=25.0, Wind=1.0, Rh=0.6, Ri_PAR_f=200.0),
                Atmosphere(T=10.0, Wind=0.5, Rh=0.6, Ri_PAR_f=200.0)]),
            df,
            df[1, :],
            DataFrame(df[1, :]),
        ]
    return meteos
end

function get_modellist_bank()
    meteo_day = CSV.read(joinpath(pkgdir(PlantSimEngine), "examples/meteo_day.csv"), DataFrame, header=18)

    rue = 0.3

    vals = (var1=15.0, var2=0.3)#, TT_cu=cumsum(meteo_day.TT))
    vals2 = (TT_cu=cumsum(meteo_day.TT),)
    vals3 = (var1=15.0, var2=0.3)
    vals4 = (var9=1.0, var0=1.0)
    vals5 = (var0=1.0,)
    vals6 = (var0=1.0,)

    status_tuples = [vals, vals2, vals3, vals4, vals5, vals6]

    models = [ModelMapping(
            process1=Process1Model(1.0),
            process2=Process2Model(),
            status=vals
        ),
        ModelMapping(
            ToyLAIModel(),
            Beer(0.5),
            ToyRUEGrowthModel(rue),
            status=vals2,
        ), ModelMapping(
            process1=Process1Model(1.0),
            process2=Process2Model(),
            process3=Process3Model(),
            status=vals3
        ), ModelMapping(
            process1=Process1Model(1.0),
            process2=Process2Model(),
            process3=Process3Model(),
            process4=Process4Model(),
            process5=Process5Model(),
            process6=Process6Model(),
            # process7=Process7Model(),
            status=vals4
        ), ModelMapping(
            process1=Process1Model(1.0),
            process2=Process2Model(),
            process3=Process3Model(),
            process4=Process4Model(),
            process5=Process5Model(),
            process6=Process6Model(),
            process7=Process7Model(),
            status=vals5
        ), ModelMapping(
            process1=Process1Model(1.0),
            process2=Process2Model(),
            process3=Process3Model(),
            process4=Process4Model(),
            process5=Process5Model(),
            status=vals6
        ),]

    outputs_tuples_vectors =
        [
            # this one has one tuple with a duplicate, and one with a nonexistent variable
            [NamedTuple(), (:var1,), (:var1, :var2), (:var1, :var3), (:var1, :var4, :var5), #=(:var1, :var1),=#
                (:var1, :var2, :var3, :var4, :var5)],        #=(:var2, :var7, :var3, :var1),=#
            [NamedTuple(), (:TT_cu,), (:TT_cu, :LAI), (:biomass, :LAI), (:TT_cu, :LAI, :aPPFD, :biomass, :biomass_increment),], [NamedTuple(), (:var1,), (:var1, :var4), (:var1, :var2), (:var1, :var3), (:var1, :var4, :var6, :var5),
                (:var1, :var2, :var3, :var4, :var5, :var6)],        #=(:var2, :var7, :var3, :var1),=#
            [NamedTuple(), (:var1,), (:var1, :var4), (:var1, :var2), (:var1, :var3), (:var1, :var4, :var6, :var5),
                (:var2, :var7, :var3, :var1), (:var1, :var2, :var3, :var4, :var5, :var6)], [NamedTuple(), (:var1,), (:var1, :var4), (:var1, :var2), (:var1, :var3), (:var1, :var4, :var6, :var5),
                (:var2, :var7, :var3, :var1), (:var1, :var2, :var3, :var4, :var5, :var6), (:var1, :var2, :var3, :var4, :var5, :var6, :var7, :var8, :var9)], [NamedTuple(), (:var1,), (:var1, :var2), (:var1, :var3), (:var1, :var4, :var6, :var5), #=(:var1, :var1),=#
                (:var2, :var7, :var3, :var1), (:var1, :var2, :var3, :var4, :var5, :var6),], #=(:var1, :var2, :var3, :var4, :var5, :var6, :var7, :var8, :var9, :var0)=#
        ]

    return models, status_tuples, outputs_tuples_vectors
end

function get_modelmapping_bank()
    meteo_day = CSV.read(joinpath(pkgdir(PlantSimEngine), "examples/meteo_day.csv"), DataFrame, header=18)

    rue = 0.3

    vals = (var1=15.0, var2=0.3)
    vals2 = (TT_cu=cumsum(meteo_day.TT),)
    vals3 = (var1=15.0, var2=0.3)
    vals4 = (var9=1.0, var0=1.0)
    vals5 = (var0=1.0,)
    vals6 = (var0=1.0,)

    status_tuples = [vals, vals2, vals3, vals4, vals5, vals6]

    mappings = [
        ModelMapping(
            process1=Process1Model(1.0),
            process2=Process2Model(),
            status=vals
        ),
        ModelMapping(
            ToyLAIModel(),
            Beer(0.5),
            ToyRUEGrowthModel(rue);
            status=vals2
        ),
        ModelMapping(
            process1=Process1Model(1.0),
            process2=Process2Model(),
            process3=Process3Model(),
            status=vals3
        ),
        ModelMapping(
            process1=Process1Model(1.0),
            process2=Process2Model(),
            process3=Process3Model(),
            process4=Process4Model(),
            process5=Process5Model(),
            process6=Process6Model(),
            status=vals4
        ),
        ModelMapping(
            process1=Process1Model(1.0),
            process2=Process2Model(),
            process3=Process3Model(),
            process4=Process4Model(),
            process5=Process5Model(),
            process6=Process6Model(),
            process7=Process7Model(),
            status=vals5
        ),
        ModelMapping(
            process1=Process1Model(1.0),
            process2=Process2Model(),
            process3=Process3Model(),
            process4=Process4Model(),
            process5=Process5Model(),
            status=vals6
        ),
    ]

    outputs_tuples_vectors =
        [
            [NamedTuple(), (:var1,), (:var1, :var2), (:var1, :var3), (:var1, :var4, :var5),
                (:var1, :var2, :var3, :var4, :var5)], [NamedTuple(), (:TT_cu,), (:TT_cu, :LAI), (:biomass, :LAI), (:TT_cu, :LAI, :aPPFD, :biomass, :biomass_increment),], [NamedTuple(), (:var1,), (:var1, :var4), (:var1, :var2), (:var1, :var3), (:var1, :var4, :var6, :var5),
                (:var1, :var2, :var3, :var4, :var5, :var6)], [NamedTuple(), (:var1,), (:var1, :var4), (:var1, :var2), (:var1, :var3), (:var1, :var4, :var6, :var5),
                (:var2, :var7, :var3, :var1), (:var1, :var2, :var3, :var4, :var5, :var6)], [NamedTuple(), (:var1,), (:var1, :var4), (:var1, :var2), (:var1, :var3), (:var1, :var4, :var6, :var5),
                (:var2, :var7, :var3, :var1), (:var1, :var2, :var3, :var4, :var5, :var6), (:var1, :var2, :var3, :var4, :var5, :var6, :var7, :var8, :var9)], [NamedTuple(), (:var1,), (:var1, :var2), (:var1, :var3), (:var1, :var4, :var6, :var5),
                (:var2, :var7, :var3, :var1), (:var1, :var2, :var3, :var4, :var5, :var6)],]

    return mappings, status_tuples, outputs_tuples_vectors
end

# Could add some mtg variation too
function get_simple_mapping_bank()
    mappings = [
        ModelMapping(
            :Scene => ToyDegreeDaysCumulModel(),
            :Plant => (
                MultiScaleModel(
                    model=ToyLAIModel(),
                    mapped_variables=[:TT_cu => (:Scene => :TT_cu),],),
                Beer(0.6),
                MultiScaleModel(
                    model=ToyCAllocationModel(),
                    mapped_variables=[
                        :carbon_assimilation => [:Leaf],
                        :carbon_demand => [:Leaf, :Internode],
                        :carbon_allocation => [:Leaf, :Internode],],),
                MultiScaleModel(
                    model=ToyPlantRmModel(),
                    mapped_variables=[:Rm_organs => [:Leaf => :Rm, :Internode => :Rm],],),),
            :Internode => (
                MultiScaleModel(
                    model=ToyCDemandModel(optimal_biomass=10.0, development_duration=200.0),
                    mapped_variables=[:TT => (:Scene => :TT),],),
                MultiScaleModel(
                    model=ToyInternodeEmergence(TT_emergence=20.0),
                    mapped_variables=[:TT_cu => (:Scene => :TT_cu)],),
                ToyMaintenanceRespirationModel(1.5, 0.06, 25.0, 0.6, 0.004),
                Status(carbon_biomass=1.0)),
            :Leaf => (
                MultiScaleModel(
                    model=ToyAssimModel(),
                    mapped_variables=[:soil_water_content => (:Soil => :soil_water_content), :aPPFD => (:Plant => :aPPFD)],),
                MultiScaleModel(
                    model=ToyCDemandModel(optimal_biomass=10.0, development_duration=200.0),
                    mapped_variables=[:TT => (:Scene => :TT),],),
                ToyMaintenanceRespirationModel(2.1, 0.06, 25.0, 1.0, 0.025),
                Status(carbon_biomass=1.0)),
            :Soil => (ToySoilWaterModel(),),),
        ##########
        ModelMapping(
            :Default => (
                Process1Model(1.0),
                Status(var1=15.0, var2=0.3,),),),
        ##########
        ModelMapping(
            :Plant => (
                MultiScaleModel(
                    model=ToyCAllocationModel(),
                    mapped_variables=[
                        # inputs
                        :carbon_assimilation => [:Leaf],
                        :carbon_demand => [:Leaf, :Internode],
                        # outputs
                        :carbon_allocation => [:Leaf, :Internode],],),
                MultiScaleModel(
                    model=ToyPlantRmModel(),
                    mapped_variables=[:Rm_organs => [:Leaf => :Rm, :Internode => :Rm],],),),
            :Internode => (
                ToyCDemandModel(optimal_biomass=10.0, development_duration=200.0),
                ToyMaintenanceRespirationModel(1.5, 0.06, 25.0, 0.6, 0.004),
                Status(TT=10.0, carbon_biomass=1.0)),
            :Leaf => (
                MultiScaleModel(
                    model=ToyAssimModel(),
                    mapped_variables=[:soil_water_content => (:Soil => :soil_water_content),],
                    # Notice we provide :Soil, not [:Soil], so a single value is expected here
                ),
                ToyCDemandModel(optimal_biomass=10.0, development_duration=200.0),
                Status(aPPFD=1300.0, TT=10.0, carbon_biomass=1.0),
                ToyMaintenanceRespirationModel(2.1, 0.06, 25.0, 1.0, 0.025),),
            :Soil => (ToySoilWaterModel(),),),
        ##################    
    ]

    out_vars_vectors = [
        [nothing,
            NamedTuple(),
            Dict(),
            #Dict(:Leaf => NamedTuple()), # incorrect
            Dict(:Leaf => (:carbon_allocation,),),
            Dict(:Leaf => (:carbon_demand,),),
            Dict(
                :Leaf => (:carbon_assimilation, :carbon_demand, :soil_water_content, :carbon_allocation),
                :Internode => (:carbon_allocation, :TT_cu_emergence),
                :Plant => (:carbon_allocation,),
                :Soil => (:soil_water_content,),),],
        #############
        [nothing,
            NamedTuple(),
            Dict(:Default => (:var1,))
        ],
        #############
        [
            nothing,
            NamedTuple(),
            Dict(
                :Leaf => (:carbon_assimilation, :carbon_demand),
                :Soil => (:soil_water_content,),
            ),],
    ]
    mtgs = [
        import_mtg_example(),
        MultiScaleTreeGraph.Node(MultiScaleTreeGraph.NodeMTG("/", :Default, 0, 0),),
        import_mtg_example()
    ]
    return mtgs, mappings, out_vars_vectors
end


function test_filtered_output_begin(m::ModelMapping, status_tuple, requested_outputs, meteo)

    nsteps = PlantSimEngine.get_nsteps(meteo)
    preallocated_outputs = PlantSimEngine.pre_allocate_outputs(m, requested_outputs, nsteps)
    @test length(preallocated_outputs) == nsteps
    if length(requested_outputs) > 0
        @test length(preallocated_outputs[1]) == length(requested_outputs)
    else
        # don't compare with the status because unnecessary variables in the status are discarded in the filtered outputs
        out_vars_all = merge(init_variables(m; verbose=false)...)
        println(out_vars_all)
        @test length(preallocated_outputs[1]) == length(out_vars_all)
    end

    filtered_outputs_modellist = run!(m, meteo; tracked_outputs=requested_outputs, executor=SequentialEx())

    # compare filtered output of a modellist with the filtered output of the equivalent simulation in multiscale mode
    mtg, mapping, outputs_mapping = PlantSimEngine.modellist_to_mapping(m, status_tuple; nsteps=nsteps, outputs=requested_outputs)

    return mtg, mapping, outputs_mapping, nsteps, filtered_outputs_modellist
end

function test_filtered_output(mtg, mapping, nsteps, outputs_mapping, meteo, filtered_outputs_modellist)
    graphsim = PlantSimEngine.GraphSimulation(mtg, mapping, nsteps=nsteps, check=true, outputs=outputs_mapping)

    sim2 = run!(graphsim,
        meteo,
        PlantMeteo.Constants(),
        nothing;
        check=true,
        executor=SequentialEx()
    )
    return compare_outputs_modellist_mapping(filtered_outputs_modellist, graphsim)
end

function test_filtered_output(m::ModelMapping, status_tuple, requested_outputs, meteo)
    mtg, mapping, outputs_mapping, nsteps, filtered_outputs_modellist =
        test_filtered_output_begin(m, status_tuple, requested_outputs, meteo)

    @test to_initialize(mapping) == Dict()
    return test_filtered_output(mtg, mapping, nsteps, outputs_mapping, meteo, filtered_outputs_modellist)
end

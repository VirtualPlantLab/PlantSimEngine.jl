mapping = Dict(
    "Plant" => (
        MultiScaleModel(
            model=ToyCAllocationModel(),
            mapping=[
                # inputs
                :carbon_assimilation => ["Leaf"],
                :carbon_demand => ["Leaf", "Internode"],
                # outputs
                :carbon_allocation => ["Leaf", "Internode"]
            ],
        ),
        MultiScaleModel(
            model=ToyPlantRmModel(),
            mapping=[:Rm_organs => ["Leaf" => :Rm, "Internode" => :Rm],],
        ),
    ),
    "Internode" => (
        ToyCDemandModel(optimal_biomass=10.0, development_duration=200.0),
        ToyMaintenanceRespirationModel(1.5, 0.06, 25.0, 0.6, 0.004),
        Status(TT=10.0)
    ),
    "Leaf" => (
        MultiScaleModel(
            model=ToyAssimModel(),
            mapping=[:soil_water_content => "Soil",],
            # Notice we provide "Soil", not ["Soil"], so a single value is expected here
        ),
        ToyCDemandModel(optimal_biomass=10.0, development_duration=200.0),
        ToyMaintenanceRespirationModel(2.1, 0.06, 25.0, 1.0, 0.025),
        Status(aPPFD=1300.0, TT=10.0),
    ),
    "Soil" => (
        ToySoilWaterModel(),
    ),
)

dep_graph = dep(mapping)

# The C allocation depends on the C demand at the leaf and internode levels,
# the maintenance respiration at the plant level, and the maintenance respiration at the plant level,
# which depends on the maintenance respiration at the leaf and internode levels.

# Expected root dependency nodes:
root_models = Dict(
    ("Soil" => :soil_water) => mapping["Soil"][1], # The only model from the soil is completely independent  
    ("Internode" => :carbon_demand) => mapping["Internode"][1], # The c allocation models dependent on TT, that is given as input:
    ("Leaf" => :carbon_demand) => mapping["Leaf"][2], # Same for the leaf
    ("Internode" => :maintenance_respiration) => mapping["Internode"][2], # The maintenance respiration model for the internode is independant
    ("Leaf" => :maintenance_respiration) => mapping["Leaf"][3], # The maintenance respiration model for the leaf is independant
)

for (proc, node) in dep_graph.roots # proc = ("Soil" => :soil_water) ; node = dep_graph.roots[proc]
    @test root_models[proc] == node.value
end



###########################
### ModelList vs Mapping comparison
### and Mapping with custom models vs mapping with generated models for user-provided vector
###########################

# Currently untested in 'real' multi-scale modes, or with complex configs (hard dependencies). 
# Need to place the simple timestep models in PlantSimEngine, and probably provide more complex ones at some point

# And then need to insert it at the graph sim generation level, and modify tests to consistently do modellist <-> mapping conversions
# And then implement tests with proper output filtering

@testset "check_statuses_contain_no_remaining_vectors behaviour" begin
    meteo_day = CSV.read(joinpath(pkgdir(PlantSimEngine), "examples/meteo_day.csv"), DataFrame, header=18)
    mapping_with_vector = Dict(
        "Scale" =>
            (ToyAssimGrowthModel(0.0, 0.0, 0.0),
            ToyCAllocationModel(),
            Status( TT_cu=Vector(cumsum(meteo_day.TT))),
            ),
        )
        
        mtg = import_mtg_example()
        @test !last(PlantSimEngine.check_statuses_contain_no_remaining_vectors(mapping_with_vector))
        @test_throws "call the function generate_models_from_status_vectors" PlantSimEngine.GraphSimulation(mtg, mapping_with_vector)
    
     mapping_with_empty_status = Dict(
        "Scale" =>
            (ToyAssimGrowthModel(0.0, 0.0, 0.0),
            ToyCAllocationModel(),
            Status(),
            ),
        )
    
     @test last(PlantSimEngine.check_statuses_contain_no_remaining_vectors(mapping_with_empty_status))
end

# simple conversion to a mapping, with a manually written model
function modellist_to_mapping_manual(modellist_original::ModelList, modellist_status, nsteps; check=true, outputs=nothing, TT_cu_vec=Vector{Float64}())
    
    modellist = Base.copy(modellist_original, modellist_original.status)

    default_scale = "Default"
    mtg = MultiScaleTreeGraph.Node(MultiScaleTreeGraph.NodeMTG("/", default_scale, 0, 0),)

    #models = collect(values(object))
    models = modellist.models
    #status_ts = modellist.status.ts

    mapping = Dict(
        default_scale => (
        models..., 
        ToyTestDegreeDaysCumulModel(TT_cu_vec=TT_cu_vec),
        PlantSimEngine.HelperNextTimestepModel(),
        MultiScaleModel(
        model=PlantSimEngine.HelperCurrentTimestepModel(),
        mapping=[PreviousTimeStep(:next_timestep),],
        ),
        Status(current_timestep=1,next_timestep=1)
        ),
    )
    
    if isnothing(outputs)
        f = []
        for i in 1:length(modellist.models)
            aa = init_variables(modellist.models[i])
            bb = keys(aa)
            for j in 1:length(bb)
                push!(f, bb[j])
            end
            #f = (f..., bb...)
        end

        f = unique!(f)
        all_vars = (f...,)
        #all_vars = merge((keys(init_variables(object.models[i])) for i in 1:length(object.models))...)
    else 
        all_vars = outputs
        # TODO sanity check
    end

    sim = PlantSimEngine.GraphSimulation(mtg, mapping, nsteps=nsteps, check=check, outputs=Dict(default_scale => all_vars))
    return sim
end


PlantSimEngine.@process "Degreedays" verbose = false

struct ToyTestDegreeDaysCumulModel <: AbstractDegreedaysModel
    TT_cu_vec::Vector{Float64}
end

PlantSimEngine.inputs_(::ToyTestDegreeDaysCumulModel) = (current_timestep=1,)
PlantSimEngine.outputs_(::ToyTestDegreeDaysCumulModel) = (TT_cu=0.0,)

ToyTestDegreeDaysCumulModel(; TT_cu_vec = Vector{Float64}()) = ToyTestDegreeDaysCumulModel(TT_cu_vec)


function PlantSimEngine.run!(m::ToyTestDegreeDaysCumulModel, models, status, meteo, constants=nothing, extra=nothing)
    status.TT_cu = m.TT_cu_vec[status.current_timestep]
end

PlantSimEngine.ObjectDependencyTrait(::Type{<:ToyTestDegreeDaysCumulModel}) = PlantSimEngine.IsObjectDependent()

@testset "ModelList and Mapping result consistency" begin

    meteo_day = CSV.read(joinpath(pkgdir(PlantSimEngine), "examples/meteo_day.csv"), DataFrame, header=18)

    st = (TT_cu=cumsum(meteo_day.TT),)
    
    TT_cu_vec = Vector(cumsum(meteo_day.TT))

    rue = 0.3
    models = ModelList(
        ToyLAIModel(),
        Beer(0.5),
        ToyRUEGrowthModel(rue),
        status=st,
    )

    run!(models,
        meteo_day
        ;
        check=true,
        executor=ThreadedEx()
    )

    nsteps = nrow(meteo_day)
    graphsim = modellist_to_mapping_manual(models, st, nsteps; outputs=nothing, TT_cu_vec=TT_cu_vec)

    sim = run!(graphsim,
        meteo_day,
        PlantMeteo.Constants(),
        nothing;
        check=true,
        executor=SequentialEx()
    )

    @test compare_outputs_modellist_mapping(models, graphsim)

    # fully automated model generation
    st2 = (TT_cu=Vector(cumsum(meteo_day.TT)),)
   
    # TODO outputs name conflict if this is just named outputs
    # TODO when outputs filtering is implemented, can test it with this function
    mtg, mapping, outputs_mapping = PlantSimEngine.modellist_to_mapping(models, st2; nsteps=nsteps, outputs=nothing)
 
   graphsim2 = PlantSimEngine.GraphSimulation(mtg, mapping, nsteps=nsteps, check=true, outputs=outputs_mapping)

    sim2 = run!(graphsim2,
        meteo_day,
        PlantMeteo.Constants(),
        nothing;
        check=true,
        executor=SequentialEx()
    )
    @test compare_outputs_modellist_mapping(models, graphsim2)
    @test compare_outputs_graphsim(graphsim, graphsim2)

end

#[getproperty(a,i) for i in fieldnames(typeof(a))]


@testset "Vector in status in a multiscale context" begin
    meteo_day = CSV.read(joinpath(pkgdir(PlantSimEngine), "examples/meteo_day.csv"), DataFrame, header=18)
    TT_v = Vector(meteo_day.TT)
    TT_cu_vec = Vector(cumsum(meteo_day.TT))
    nsteps = length(meteo_day.TT)

    mapping_with_vector = Dict(
    
    "Plant" => (
        MultiScaleModel(
            model=ToyCAllocationModel(),
            mapping=[
                # inputs
                :carbon_assimilation => ["Leaf"],
                :carbon_demand => ["Leaf", "Internode"],
                # outputs
                :carbon_allocation => ["Leaf", "Internode"]
            ],
        ),
        MultiScaleModel(
            model=ToyPlantRmModel(),
            mapping=[:Rm_organs => ["Leaf" => :Rm, "Internode" => :Rm],],
        ),
    ),
    "Internode" => (
        ToyCDemandModel(optimal_biomass=10.0, development_duration=200.0),
        ToyMaintenanceRespirationModel(1.5, 0.06, 25.0, 0.6, 0.004),
        Status(TT=TT_v, carbon_biomass=1.0)
    ),
    "Leaf" => (
        MultiScaleModel(
            model=ToyAssimModel(),
            mapping=[:soil_water_content => "Soil",],
            # Notice we provide "Soil", not ["Soil"], so a single value is expected here
        ),
        ToyCDemandModel(optimal_biomass=10.0, development_duration=200.0),
        ToyMaintenanceRespirationModel(2.1, 0.06, 25.0, 1.0, 0.025),
        Status(aPPFD=1300.0, carbon_biomass=2.0, TT=10.0), # TODO try calling the generated TT output through a variable mapping
    ),
    "Soil" => (
        ToySoilWaterModel(),
    ),
)

out_multiscale = Dict("Plant" => (:Rm_organs,),)
mtg = import_mtg_example();

mapping_without_vectors = PlantSimEngine.replace_mapping_status_vectors_with_generated_models(mapping_with_vector, "Soil", nsteps)

 graph_sim_multiscale = @test_nowarn PlantSimEngine.GraphSimulation(mtg, mapping_without_vectors, nsteps=nsteps, check=true, outputs=out_multiscale)

    sim_multiscale = run!(graph_sim_multiscale,
        meteo_day,
        PlantMeteo.Constants(),
        nothing;
        check=true,
        executor=SequentialEx()
    )

    #replace a value with a constant vector and ensure no changes happen in the simulation 
    carbon_biomass_vec = Vector{Float64}(undef, nsteps)
    for i in nsteps
        carbon_biomass_vec[i] = 2.0
    end
    mapping_with_two_vectors = Dict("Plant" => (
            MultiScaleModel(
                model=ToyCAllocationModel(),
                mapping=[
                    # inputs
                    :carbon_assimilation => ["Leaf"],
                    :carbon_demand => ["Leaf", "Internode"],
                    # outputs
                    :carbon_allocation => ["Leaf", "Internode"]
                ],
            ),
            MultiScaleModel(
                model=ToyPlantRmModel(),
                mapping=[:Rm_organs => ["Leaf" => :Rm, "Internode" => :Rm],],
            ),
        ),
        "Internode" => (
            ToyCDemandModel(optimal_biomass=10.0, development_duration=200.0),
            ToyMaintenanceRespirationModel(1.5, 0.06, 25.0, 0.6, 0.004),
            Status(TT=TT_v, carbon_biomass=1.0)
        ),
        "Leaf" => (
            MultiScaleModel(
                model=ToyAssimModel(),
                mapping=[:soil_water_content => "Soil",],
            ),
            ToyCDemandModel(optimal_biomass=10.0, development_duration=200.0),
            ToyMaintenanceRespirationModel(2.1, 0.06, 25.0, 1.0, 0.025),
            Status(aPPFD=1300.0, carbon_biomass=carbon_biomass_vec, TT=10.0), # Replaced with vector here
        ),
        "Soil" => (
            ToySoilWaterModel(),
        ),
    )

    mtg = import_mtg_example()
    mapping_without_vectors_2 = PlantSimEngine.replace_mapping_status_vectors_with_generated_models(mapping_with_two_vectors, "Soil", nsteps)
    graph_sim_multiscale_2 = @test_nowarn PlantSimEngine.GraphSimulation(mtg, mapping_without_vectors_2, nsteps=nsteps, check=true, outputs=out_multiscale)

    sim_multiscale_2 = run!(graph_sim_multiscale_2,
        meteo_day,
        PlantMeteo.Constants(),
        nothing;
        check=true,
        executor=SequentialEx()
    )

    @test compare_outputs_graphsim(graph_sim_multiscale, graph_sim_multiscale_2)
end
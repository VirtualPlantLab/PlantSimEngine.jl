
mtg = import_mtg_example()
# Example meteo:
meteo = Weather(
    [
    Atmosphere(T=20.0, Wind=1.0, Rh=0.65, Ri_PAR_f=300.0),
    Atmosphere(T=25.0, Wind=0.5, Rh=0.8, Ri_PAR_f=500.0)
]
)

out_vars = Dict(
    "Plant" => (:carbon_allocation,),
    "Leaf" => (:carbon_demand, :carbon_allocation, :carbon_biomass),
    "Internode" => (:carbon_demand, :carbon_allocation, :carbon_biomass),
)

@testset "Cyclic dependency -> error" begin
    mapping_cyclic = Dict(
        "Plant" => (
            MultiScaleModel(
                model=ToyCAllocationModel(),
                mapped_variables=[
                    :carbon_demand => ["Leaf", "Internode"],
                    :carbon_allocation => ["Leaf", "Internode"]
                ],
            ),
            MultiScaleModel(
                model=ToyPlantRmModel(),
                mapped_variables=[:Rm_organs => ["Leaf" => :Rm, "Internode" => :Rm],],
            ),
            Status(total_surface=0.001, aPPFD=1300.0, soil_water_content=0.6),
        ),
        "Internode" => (
            ToyCDemandModel(optimal_biomass=10.0, development_duration=200.0),
            ToyMaintenanceRespirationModel(1.5, 0.06, 25.0, 0.6, 0.004),
            Status(TT=10.0, carbon_biomass=1.0),
        ),
        "Leaf" => (
            ToyCDemandModel(optimal_biomass=10.0, development_duration=200.0),
            ToyMaintenanceRespirationModel(2.1, 0.06, 25.0, 1.0, 0.025),
            ToyCBiomassModel(1.2),
            Status(TT=10.0),
        )
    )
    # In this mapping, we have a cyclic dependency with the carbon allocation and the carbon biomass. The carbon biomass depends on the carbon allocation, which itself depends on the
    # plant Rm, which depends on the Rm organs, which depends on the carbon biomass. This is a cyclic dependency that we need to break somewhere.

    @test_throws "Cyclic dependency detected in the graph. Cycle:" dep(mapping_cyclic)

    soft_dep_graphs_roots, hard_dep_dict = PlantSimEngine.hard_dependencies(mapping_cyclic)
    dep_graph = PlantSimEngine.soft_dependencies_multiscale(soft_dep_graphs_roots, mapping_cyclic, hard_dep_dict)
    iscyclic, cycle_vec = PlantSimEngine.is_graph_cyclic(dep_graph; warn=false)

    @test iscyclic
    @test cycle_vec == [ToyPlantRmModel() => "Plant", ToyMaintenanceRespirationModel{Float64}(2.1, 0.06, 25.0, 1.0, 0.025) => "Leaf", ToyCBiomassModel{Float64}(1.2) => "Leaf", ToyCAllocationModel() => "Plant", ToyPlantRmModel() => "Plant"]
end


@testset "Cyclic dependency -> fixed with `PreviousTimeStep`" begin
    mapping_nocyclic = Dict(
        "Plant" => (
            MultiScaleModel(
                model=ToyCAllocationModel(),
                mapped_variables=[
                    :carbon_demand => ["Leaf", "Internode"],
                    :carbon_allocation => ["Leaf", "Internode"]
                ],
            ),
            MultiScaleModel(
                model=ToyPlantRmModel(),
                mapped_variables=[:Rm_organs => ["Leaf" => :Rm, "Internode" => :Rm],],
            ),
            Status(total_surface=0.001, aPPFD=1300.0, soil_water_content=0.6, carbon_assimilation=5.0),
        ),
        "Internode" => (
            ToyCDemandModel(optimal_biomass=10.0, development_duration=200.0),
            MultiScaleModel(
                model=ToyMaintenanceRespirationModel(1.5, 0.06, 25.0, 0.6, 0.004),
                mapped_variables=[PreviousTimeStep(:carbon_biomass),], #! this is where we break the cyclic dependency (first break)
            ),
            Status(TT=10.0, carbon_biomass=1.0),
        ),
        "Leaf" => (
            ToyCDemandModel(optimal_biomass=10.0, development_duration=200.0),
            MultiScaleModel(
                model=ToyMaintenanceRespirationModel(2.1, 0.06, 25.0, 1.0, 0.025),
                mapped_variables=[PreviousTimeStep(:carbon_biomass),], #! this is where we break the cyclic dependency (second break)
            ),
            ToyCBiomassModel(1.2),
            Status(TT=10.0),
        )
    )
    # In this mapping, we have a cyclic dependency with the carbon allocation and the carbon biomass like the test above, but we 
    # break the cyclic dependency by using the value of the biomass from the previous time-step instead of taking the current computation.

    @test_nowarn dep(mapping_nocyclic)

    soft_dep_graphs_roots, hard_dep_dict = PlantSimEngine.hard_dependencies(mapping_nocyclic)
    # soft_dep_graphs_roots.roots["Leaf"].inputs
    dep_graph = PlantSimEngine.soft_dependencies_multiscale(soft_dep_graphs_roots, mapping_nocyclic, hard_dep_dict)
    iscyclic, cycle_vec = PlantSimEngine.is_graph_cyclic(dep_graph; warn=false)

    @test !iscyclic
    @test length(cycle_vec) == 7
    @test to_initialize(mapping_nocyclic) == Dict()


    #out = @test_nowarn run!(mtg, mapping_nocyclic, meteo, tracked_outputs=out_vars, executor=SequentialEx())
    nsteps = PlantSimEngine.get_nsteps(meteo)
    sim = PlantSimEngine.GraphSimulation(mtg, mapping, nsteps=nsteps, check=true, outputs=out_vars)
    out = @test_nowarn run!(sim,meteo)
    st = status(sim)

    st["Leaf"][1].carbon_biomass = 2.0
    @test st["Leaf"][2].carbon_biomass != 2.0
end

@testset "Mutiscale simulation -> cyclic dependency" begin
    mapping = Dict(
        "Scene" => (
            ToyDegreeDaysCumulModel(),
            MultiScaleModel(
                model=ToyLAIfromLeafAreaModel(1.0),
                mapped_variables=[
                    :plant_surfaces => ["Plant" => :surface],
                ],
            ),
            Beer(0.6),
        ),
        "Plant" => (
            MultiScaleModel(
                model=ToyPlantLeafSurfaceModel(),
                mapped_variables=[PreviousTimeStep(:leaf_surfaces) => ["Leaf" => :surface],],
                #! We use PreviousTimeStep to break the cyclic dependency between the LAI and the leaf surface 
                # that is computed as one of the latest sub-models. Now the LAI used for light interception
                # will be the one from the previous time-step, and at the end of the time-step we will update
                # the leaf surface.
            ),
            MultiScaleModel(
                model=ToyLightPartitioningModel(),
                mapped_variables=[
                    :aPPFD_larger_scale => "Scene" => :aPPFD,
                    :total_surface => "Scene"
                ],
            ),
            MultiScaleModel(
                model=ToyAssimModel(),
                mapped_variables=[
                    :soil_water_content => "Soil",
                ],
            ),
            MultiScaleModel(
                model=ToyCAllocationModel(),
                mapped_variables=[
                    :carbon_demand => ["Leaf", "Internode"],
                    :carbon_allocation => ["Leaf", "Internode"]
                ],
            ),
            MultiScaleModel(
                model=ToyPlantRmModel(),
                mapped_variables=[:Rm_organs => ["Leaf" => :Rm, "Internode" => :Rm],],
            ),
        ),
        "Internode" => (
            MultiScaleModel(
                model=ToyCDemandModel(optimal_biomass=10.0, development_duration=200.0),
                mapped_variables=[:TT => "Scene",],
            ),
            MultiScaleModel(
                model=ToyInternodeEmergence(TT_emergence=20.0),
                mapped_variables=[:TT_cu => "Scene"],
            ),
            MultiScaleModel(
                model=ToyMaintenanceRespirationModel(1.5, 0.06, 25.0, 0.6, 0.004),
                mapped_variables=[PreviousTimeStep(:carbon_biomass),], #! this is where we break the cyclic dependency (first break)
            ),
            ToyCBiomassModel(1.1),
            Status(carbon_biomass=0.0)
        ),
        "Leaf" => (
            MultiScaleModel(
                model=ToyCDemandModel(optimal_biomass=10.0, development_duration=200.0),
                mapped_variables=[:TT => "Scene",],
            ),
            MultiScaleModel(
                model=ToyMaintenanceRespirationModel(2.1, 0.06, 25.0, 1.0, 0.025),
                mapped_variables=[PreviousTimeStep(:carbon_biomass),], #! this is where we break the cyclic dependency (first break)
            ),
            ToyCBiomassModel(1.2),
            ToyLeafSurfaceModel(0.1),
            Status(carbon_biomass=0.0, surface=0.001,)
        ),
        "Soil" => (
            ToySoilWaterModel(),
        ),
    )
    # In this mapping, we have a cyclic dependency. The leaf surface is computed using the leaf biomass, which is computed using the carbon allocation, which itself depends on the 
    # light interception, which is computed using the LAI at scene scale, itself coming from the plant total leaf surface, computed as the sum of all leaves surfaces. 
    # This is a cyclic dependency that we need to break somewhere. We can break it by using the value of the leaf surface from the previous time-step, which is a common practice in
    # plant models. This is done by flagging the leaf surface as a PreviousTimeStep variable in the mapping of the leaf node.

    out_vars = Dict(
        "Scene" => (:TT_cu, :LAI, :plant_surfaces, :aPPFD),
        "Plant" => (:carbon_assimilation, :carbon_allocation, :aPPFD, :soil_water_content, :leaf_surfaces, :surface, :total_surface),
        "Leaf" => (:carbon_demand, :carbon_allocation, :carbon_biomass),
        "Internode" => (:carbon_demand, :carbon_allocation, :TT_cu_emergence, :carbon_biomass),
        "Soil" => (:soil_water_content,),
    )
    mtg = import_mtg_example()
    meteo = Weather(
        [
        Atmosphere(T=20.0, Wind=1.0, Rh=0.65, Ri_PAR_f=300.0),
        Atmosphere(T=25.0, Wind=0.5, Rh=0.8, Ri_PAR_f=500.0)
    ]
    )

    d = @test_nowarn dep(mapping)
    @test to_initialize(mapping) == Dict()
    #out = @test_nowarn run!(mtg, mapping, meteo, tracked_outputs=out_vars, executor=SequentialEx())
    
    nsteps = PlantSimEngine.get_nsteps(meteo)
    sim = PlantSimEngine.GraphSimulation(mtg, mapping, nsteps=nsteps, check=true, outputs=out_vars)
    out = run!(sim,meteo)
    
    # To update the reference:
    ref_path = joinpath(pkgdir(PlantSimEngine), "test/references/ref_output_simulation.csv")
    # CSV.write(ref_path, sort(convert_outputs(out, DataFrame, no_value=missing), [:timestep, :node]), transform=(col, val) -> something(val, missing))
    ref_df = CSV.read(ref_path, DataFrame)
    
    @test sort(unique(ref_df.organ)) == sort(collect(keys(out)))
    
    out_df_dict = convert_outputs(out, DataFrame, no_value=missing)

    for organ in keys(out)        
        reduced_ref_df = ref_df[(ref_df.organ .== organ), Not(:organ)]
        reduced_ref_df_no_missing = reduced_ref_df[:, any.(!ismissing, eachcol(reduced_ref_df))]
        sorted_reduced_ref_df_no_missing = select(reduced_ref_df_no_missing, sort(propertynames(reduced_ref_df_no_missing)))
        sorted_out_df_dict_organ = select(out_df_dict[organ], sort(propertynames(out_df_dict[organ])))
        @test sorted_reduced_ref_df_no_missing == sorted_out_df_dict_organ
    end
end
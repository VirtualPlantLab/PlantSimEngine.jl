using Dates

function toy_scene(status, models...; environment=nothing)
    applications = map(models) do model
        ModelSpec(model; on=One(scale=:Plant))
    end
    CompositeModel(
        Object(:plant; scale=:Plant, kind=:plant, status=status);
        applications=Tuple(applications),
        environment=environment,
    )
end

@testset "Toy model declarations" begin
    models = (
        ToyDegreeDaysCumulModel(),
        ToyLAIModel(),
        Beer(0.5),
        ToyRUEGrowthModel(0.3),
        ToyAssimGrowthModel(),
        ToyAssimModel(),
        ToyCDemandModel(; optimal_biomass=2.0, development_duration=100.0),
        ToyCAllocationModel(),
        ToyCBiomassModel(1.2),
        ToyLeafSurfaceModel(0.02),
        ToyPlantLeafSurfaceModel(),
        ToyLAIfromLeafAreaModel(1.0),
        ToyLightPartitioningModel(),
        ToyMaintenanceRespirationModel(2.0, 0.06, 25.0, 0.8, 0.02),
        ToyPlantRmModel(),
        ToySoilWaterModel(),
    )
    expected_inputs = (
        (),
        (:TT_cu,),
        (:LAI,),
        (:aPPFD,),
        (:aPPFD,),
        (:aPPFD, :soil_water_content),
        (:TT,),
        (:carbon_assimilation, :Rm, :carbon_demand),
        (:carbon_allocation,),
        (:carbon_biomass,),
        (:leaf_surfaces,),
        (:plant_surfaces,),
        (:aPPFD_larger_scale, :total_surface, :surface),
        (:carbon_biomass,),
        (:Rm_organs,),
        (),
    )
    expected_outputs = (
        (:TT, :TT_cu),
        (:LAI,),
        (:aPPFD,),
        (:biomass, :biomass_increment),
        (:carbon_assimilation, :Rm, :Rg, :biomass_increment, :biomass),
        (:carbon_assimilation,),
        (:carbon_demand,),
        (:carbon_offer, :carbon_allocation),
        (:carbon_biomass_increment, :carbon_biomass, :growth_respiration),
        (:surface,),
        (:surface,),
        (:LAI, :total_surface),
        (:aPPFD,),
        (:Rm,),
        (:Rm,),
        (:soil_water_content,),
    )
    expected_environment_inputs = (
        (:T,),
        (),
        (:Ri_PAR_f,),
        (),
        (),
        (),
        (),
        (),
        (),
        (),
        (),
        (),
        (),
        (:T,),
        (),
        (),
    )

    for (model, expected_input, expected_output, expected_environment_input) in zip(
        models,
        expected_inputs,
        expected_outputs,
        expected_environment_inputs,
    )
        @test Tuple(inputs(model)) == expected_input
        @test Tuple(outputs(model)) == expected_output
        @test Tuple(PlantSimEngine.environment_inputs(model)) ==
              expected_environment_input
    end

    @test Tuple(PlantSimEngine.environment_inputs(Process2Model())) == (:T, :Wind, :Rh)
end

@testset "Toy model generic numeric parameters" begin
    degree_days = ToyDegreeDaysCumulModel(;
        init_TT=Float32(2),
        T_base=Float32(10),
        T_max=Float32(43),
    )
    lai = ToyLAIModel(;
        max_lai=Float32(8),
        dd_incslope=Float32(800),
        inc_slope=Float32(110),
        dd_decslope=Float32(1500),
        dec_slope=Float32(20),
    )
    respiration = ToyMaintenanceRespirationModel(
        Float32(2),
        Float32(0.06),
        Float32(25),
        Float32(0.8),
        Float32(0.02),
    )

    @test degree_days isa ToyDegreeDaysCumulModel{Float32}
    @test lai isa ToyLAIModel{Float32}
    @test respiration isa ToyMaintenanceRespirationModel{Float32}
    @test all(value -> value isa Float32, values(PlantSimEngine.outputs_(degree_days)))
    @test all(value -> value isa Float32, values(PlantSimEngine.outputs_(lai)))
    @test all(value -> value isa Float32, values(PlantSimEngine.outputs_(respiration)))
    @test PlantSimEngine.outputs_(ToySoilWaterModel(Float32[0.25])).soil_water_content isa
          Float32
end

@testset "Toy environment contracts compose with declared-only forcing" begin
    forcing = (
        T=Float32(20),
        Ri_PAR_f=Float32(300),
        duration=Day(1),
    )
    model = CompositeModel(
        ToyDegreeDaysCumulModel(;
            init_TT=Float32(0),
            T_base=Float32(10),
            T_max=Float32(43),
        ),
        ToyLAIModel(
            max_lai=Float32(8),
            dd_incslope=Float32(30),
            inc_slope=Float32(10),
            dd_decslope=Float32(200),
            dec_slope=Float32(20),
        ),
        Beer(Float32(0.5));
        environment=forcing,
    )

    @test validate_environment_inputs(model) === nothing
    @test_throws "Ri_PAR_f" validate_environment_inputs(
        model,
        (T=Float32(20), duration=Day(1)),
    )

    simulation = run!(model; steps=3, outputs=:all)
    status = only(model_objects(model)).status
    @test status.TT_cu == Float32(30)
    @test status.LAI isa Float32
    @test status.aPPFD isa Float32
    @test length(outputs(simulation)) == 4

    respiration = ToyMaintenanceRespirationModel(
        Float32(2),
        Float32(0.06),
        Float32(25),
        Float32(0.8),
        Float32(0.02),
    )
    respiration_model = toy_scene(
        Status(carbon_biomass=Float32(2)),
        respiration;
        environment=(T=Float32(20), duration=Day(1)),
    )
    @test validate_environment_inputs(respiration_model) === nothing
    run!(respiration_model)
    @test only(model_objects(respiration_model)).status.Rm isa Float32
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

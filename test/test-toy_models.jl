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

@testset "One-plant tutorial composition" begin
    scalar_model = CompositeModel(
        Object(
            :plant;
            scale=:Plant,
            kind=:plant,
            status=Status(aPPFD=120.0, surface=3.0),
        ),
        Object(
            :leaf_1;
            scale=:Leaf,
            kind=:leaf,
            parent=:plant,
            status=Status(surface=1.0),
        ),
        Object(
            :leaf_2;
            scale=:Leaf,
            kind=:leaf,
            parent=:plant,
            status=Status(surface=2.0),
        );
        applications=(
            ModelSpec(
                ToyLightPartitioningModel();
                name=:leaf_light,
                on=Many(scale=:Leaf),
                inputs=(
                    :aPPFD_larger_scale => One(
                        scale=:Plant,
                        within=SelfPlant(),
                        var=:aPPFD,
                    ),
                    :total_surface => One(
                        scale=:Plant,
                        within=SelfPlant(),
                        var=:surface,
                    ),
                ),
            ),
        ),
    )
    scalar_simulation = run!(scalar_model)
    scalar_states = final_state(scalar_simulation, Many(scale=:Leaf))
    @test scalar_states[:leaf_1].aPPFD == 40.0
    @test scalar_states[:leaf_2].aPPFD == 80.0

    computed_model = CompositeModel(
        Object(
            :plant;
            scale=:Plant,
            kind=:plant,
            status=Status(aPPFD=120.0),
        ),
        Object(
            :leaf_1;
            scale=:Leaf,
            kind=:leaf,
            parent=:plant,
            status=Status(carbon_biomass=50.0),
        ),
        Object(
            :leaf_2;
            scale=:Leaf,
            kind=:leaf,
            parent=:plant,
            status=Status(carbon_biomass=100.0),
        );
        applications=(
            ModelSpec(
                ToyLeafSurfaceModel(0.02);
                name=:leaf_surface,
                on=Many(scale=:Leaf),
            ),
            ModelSpec(
                ToyPlantLeafSurfaceModel();
                name=:plant_surface,
                on=One(scale=:Plant),
                inputs=(
                    :leaf_surfaces => Many(
                        scale=:Leaf,
                        within=Subtree(),
                        application=:leaf_surface,
                        var=:surface,
                    ),
                ),
            ),
            ModelSpec(
                ToyLightPartitioningModel();
                name=:leaf_light,
                on=Many(scale=:Leaf),
                inputs=(
                    :aPPFD_larger_scale => One(
                        scale=:Plant,
                        within=SelfPlant(),
                        var=:aPPFD,
                    ),
                    :total_surface => One(
                        scale=:Plant,
                        within=SelfPlant(),
                        application=:plant_surface,
                        var=:surface,
                    ),
                ),
            ),
        ),
    )
    computed_simulation = run!(computed_model)
    plant_state = final_state(computed_simulation, One(scale=:Plant))
    leaf_states = final_state(computed_simulation, Many(scale=:Leaf))
    @test plant_state.surface == 3.0
    @test leaf_states[:leaf_1].surface == 1.0
    @test leaf_states[:leaf_2].surface == 2.0
    @test leaf_states[:leaf_1].aPPFD == 40.0
    @test leaf_states[:leaf_2].aPPFD == 80.0
    @test only(
        row for row in Diagnostics.explain_bindings(computed_model)
        if row.application_id == :plant_surface
    ).carrier_kind == :ref_vector
end

@testset "Several-plant tutorial composition" begin
    plant_template = CompositeModelTemplate((
        ModelSpec(
            ToyLeafSurfaceModel(0.02);
            name=:leaf_surface,
            on=Many(scale=:Leaf),
        ),
        ModelSpec(
            ToyPlantLeafSurfaceModel();
            name=:plant_surface,
            on=One(scale=:Plant),
            inputs=(
                :leaf_surfaces => Many(
                    scale=:Leaf,
                    within=Subtree(),
                    application=:leaf_surface,
                    var=:surface,
                ),
            ),
        ),
        ModelSpec(
            ToyLightPartitioningModel();
            name=:leaf_light,
            on=Many(scale=:Leaf),
            inputs=(
                :aPPFD_larger_scale => One(
                    scale=:Plant,
                    within=SelfPlant(),
                    var=:aPPFD,
                ),
                :total_surface => One(
                    scale=:Plant,
                    within=SelfPlant(),
                    application=:plant_surface,
                    var=:surface,
                ),
            ),
        ),
    ))

    plant_a = ObjectInstance(
        :plant_a,
        plant_template;
        root=Object(
            :plant_a_root;
            scale=:Plant,
            kind=:plant,
            status=Status(aPPFD=120.0),
        ),
        objects=(
            Object(
                :plant_a_leaf_1;
                scale=:Leaf,
                kind=:leaf,
                parent=:plant_a_root,
                status=Status(carbon_biomass=50.0),
            ),
            Object(
                :plant_a_leaf_2;
                scale=:Leaf,
                kind=:leaf,
                parent=:plant_a_root,
                status=Status(carbon_biomass=100.0),
            ),
        ),
    )
    plant_b = ObjectInstance(
        :plant_b,
        plant_template;
        root=Object(
            :plant_b_root;
            scale=:Plant,
            kind=:plant,
            status=Status(aPPFD=200.0),
        ),
        objects=(
            Object(
                :plant_b_leaf_1;
                scale=:Leaf,
                kind=:leaf,
                parent=:plant_b_root,
                status=Status(carbon_biomass=50.0),
            ),
            Object(
                :plant_b_leaf_2;
                scale=:Leaf,
                kind=:leaf,
                parent=:plant_b_root,
                status=Status(carbon_biomass=50.0),
            ),
        ),
    )

    model = CompositeModel(plant_a, plant_b)
    simulation = run!(model)
    plant_states = final_state(simulation, Many(scale=:Plant))
    leaf_states = final_state(simulation, Many(scale=:Leaf))
    @test plant_states[:plant_a_root].surface == 3.0
    @test plant_states[:plant_b_root].surface == 2.0
    @test sum(
        leaf_states[id].aPPFD
        for id in (:plant_a_leaf_1, :plant_a_leaf_2)
    ) == 120.0
    @test sum(
        leaf_states[id].aPPFD
        for id in (:plant_b_leaf_1, :plant_b_leaf_2)
    ) == 200.0
    @test Set(row.name for row in Diagnostics.explain_instances(model)) ==
          Set((:plant_a, :plant_b))

    plant_c = ObjectInstance(
        :plant_c,
        plant_template;
        root=Object(
            :plant_c_root;
            scale=:Plant,
            kind=:plant,
            status=Status(aPPFD=120.0),
        ),
        objects=(
            Object(
                :plant_c_leaf_1;
                scale=:Leaf,
                kind=:leaf,
                parent=:plant_c_root,
                status=Status(carbon_biomass=50.0),
            ),
            Object(
                :plant_c_leaf_2;
                scale=:Leaf,
                kind=:leaf,
                parent=:plant_c_root,
                status=Status(carbon_biomass=100.0),
            ),
        ),
        overrides=(leaf_surface=ToyLeafSurfaceModel(0.04),),
    )
    override_simulation = run!(CompositeModel(plant_c))
    @test final_state(override_simulation, One(scale=:Plant)).surface == 6.0
end

@testset "Environment tutorial composition" begin
    forcing = (
        air_temperature=20.0,
        incident_par=300.0,
        duration=Day(1),
    )
    global_model = CompositeModel(
        Object(:plant; scale=:Plant, kind=:plant);
        applications=(
            ModelSpec(
                ToyDegreeDaysCumulModel();
                name=:degree_days,
                on=One(scale=:Plant),
                environment=Environment(
                    provider=:global,
                    sources=(T=:air_temperature,),
                ),
            ),
            ModelSpec(
                ToyLAIModel();
                name=:lai,
                on=One(scale=:Plant),
            ),
            ModelSpec(
                Beer(0.6);
                name=:light,
                on=One(scale=:Plant),
                environment=Environment(
                    provider=:global,
                    sources=(Ri_PAR_f=:incident_par,),
                ),
            ),
        ),
        environment=forcing,
    )
    @test validate_environment_inputs(global_model) === nothing
    global_state = final_state(run!(global_model))
    @test global_state.TT_cu == 10.0
    global_environment_rows =
        Diagnostics.explain_environment_bindings(global_model)
    @test only(
        row for row in global_environment_rows
        if row.application_id == :degree_days
    ).source_inputs == [:air_temperature]
    @test only(
        row for row in global_environment_rows
        if row.application_id == :light
    ).source_inputs == [:incident_par]

    backend = ToySpatialEnvironment(
        Dict(
            :sun => (Ri_PAR_f=400.0,),
            :shade => (Ri_PAR_f=100.0,),
        );
        step_seconds=3600.0,
    )
    spatial_model = CompositeModel(
        Object(
            :sun_leaf;
            scale=:Leaf,
            kind=:leaf,
            geometry=(cell=:sun,),
            status=Status(LAI=2.0),
        ),
        Object(
            :shade_leaf;
            scale=:Leaf,
            kind=:leaf,
            geometry=(cell=:shade,),
            status=Status(LAI=2.0),
        );
        applications=(
            ModelSpec(
                Beer(0.6);
                name=:light,
                on=Many(scale=:Leaf),
                environment=Environment(backend=backend),
            ),
        ),
    )
    spatial_states = final_state(run!(spatial_model), Many(scale=:Leaf))
    @test spatial_states[:sun_leaf].aPPFD >
          spatial_states[:shade_leaf].aPPFD
    handles = Dict(
        row.object_id => row.handle.cell
        for row in Diagnostics.explain_environment_bindings(spatial_model)
    )
    @test handles == Dict(:sun_leaf => :sun, :shade_leaf => :shade)
end

@testset "Cadence tutorial composition" begin
    model = CompositeModel(
        Object(:plant; scale=:Plant, kind=:plant);
        applications=(
            ModelSpec(
                ToyDegreeDaysCumulModel();
                name=:degree_days,
                on=One(scale=:Plant),
                every=Day(1),
            ),
            ModelSpec(
                ToyLAIModel();
                name=:lai,
                on=One(scale=:Plant),
                every=Day(1),
            ),
            ModelSpec(
                Beer(0.6);
                name=:light,
                on=One(scale=:Plant),
                inputs=(
                    :LAI => One(
                        within=Self(),
                        application=:lai,
                        var=:LAI,
                        policy=HoldLast(),
                        window=Day(1),
                    ),
                ),
                every=Hour(1),
            ),
        ),
        environment=[
            (T=20.0, Ri_PAR_f=300.0, duration=Hour(1))
            for _ in 1:25
        ],
    )
    simulation = run!(model; steps=25, outputs=:all)
    schedule = Dict(
        row.application_id => row
        for row in Diagnostics.explain_schedule(model)
    )
    @test schedule[:degree_days].dt_steps == 24.0
    @test schedule[:lai].dt_steps == 24.0
    @test schedule[:light].dt_steps == 1.0
    hold_binding = only(
        row for row in Diagnostics.explain_bindings(model)
        if row.application_id == :light
    )
    @test hold_binding.policy isa HoldLast
    @test hold_binding.carrier_kind == :temporal_stream
    summaries = Dict(
        (row.application_id, row.variable) => row.nsamples
        for row in Diagnostics.explain_outputs(simulation)
    )
    @test summaries[(:degree_days, :TT_cu)] == 2
    @test summaries[(:lai, :LAI)] == 2
    @test summaries[(:light, :aPPFD)] == 25
end

@testset "Structure-change tutorial composition" begin
    model = CompositeModel(
        Object(:plant; scale=:Plant, kind=:plant),
        Object(:branch; scale=:Axis, kind=:axis, parent=:plant),
        Object(
            :leaf_1;
            scale=:Leaf,
            kind=:leaf,
            parent=:plant,
            status=Status(TT=10.0),
        ),
        Object(
            :leaf_2;
            scale=:Leaf,
            kind=:leaf,
            parent=:plant,
            status=Status(TT=15.0),
        );
        applications=(
            ModelSpec(
                ToyCDemandModel(
                    optimal_biomass=12.0,
                    development_duration=120.0,
                );
                name=:carbon_demand,
                on=Many(scale=:Leaf),
            ),
            ModelSpec(
                ToyCBiomassModel(1.2);
                name=:biomass,
                on=Many(scale=:Leaf),
                inputs=(
                    :carbon_allocation => One(
                        within=Self(),
                        application=:carbon_demand,
                        var=:carbon_demand,
                    ),
                ),
            ),
        ),
    )
    simulation = run!(model; outputs=:all)
    initial_targets = only(
        row for row in Diagnostics.explain_applications(simulation)
        if row.application_id == :biomass
    ).target_ids
    @test initial_targets == [:leaf_1, :leaf_2]

    register_object!(
        model,
        Object(
            :leaf_3;
            scale=:Leaf,
            kind=:leaf,
            status=Status(TT=20.0),
        );
        parent=:plant,
    )
    @test only(
        row for row in Diagnostics.explain_applications(simulation)
        if row.application_id == :biomass
    ).target_ids == initial_targets
    continue!(simulation)
    @test only(
        row for row in Diagnostics.explain_applications(simulation)
        if row.application_id == :biomass
    ).target_ids == [:leaf_1, :leaf_2, :leaf_3]
    @test only(
        object.parent for object in model_objects(model)
        if object.id == ObjectId(:leaf_3)
    ) == ObjectId(:plant)

    reparent_object!(model, :leaf_3, :branch)
    continue!(simulation)
    @test only(
        object.parent for object in model_objects(model)
        if object.id == ObjectId(:leaf_3)
    ) == ObjectId(:branch)

    @test remove_object!(model, :leaf_2).id == ObjectId(:leaf_2)
    continue!(simulation)
    @test Set(object_ids(model; scale=:Leaf)) ==
          Set(ObjectId.((:leaf_1, :leaf_3)))
    @test only(
        row for row in Diagnostics.explain_applications(simulation)
        if row.application_id == :biomass
    ).target_ids == [:leaf_1, :leaf_3]

    rows = collect_outputs(simulation; sink=nothing)
    demand = Dict(
        (row.timestep, row.object_id) => row.value
        for row in rows
        if row.application_id == :carbon_demand &&
           row.variable == :carbon_demand
    )
    increment = Dict(
        (row.timestep, row.object_id) => row.value
        for row in rows
        if row.application_id == :biomass &&
           row.variable == :carbon_biomass_increment
    )
    respiration = Dict(
        (row.timestep, row.object_id) => row.value
        for row in rows
        if row.application_id == :biomass &&
           row.variable == :growth_respiration
    )
    @test all(
        demand[key] ≈ increment[key] + respiration[key]
        for key in keys(demand)
    )
    @test Dict(
        id => length(collect_outputs(
            simulation,
            id,
            :carbon_biomass;
            sink=nothing,
        ))
        for id in (:leaf_1, :leaf_2, :leaf_3)
    ) == Dict(:leaf_1 => 4, :leaf_2 => 3, :leaf_3 => 3)
end

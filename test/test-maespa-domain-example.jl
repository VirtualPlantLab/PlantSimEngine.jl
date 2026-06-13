include("../examples/maespa_domain_example.jl")

@testset "MAESPA-style domain example" begin
    result = run_maespa_example(; nhours=24, check=true)
    sim = result.simulation

    @test length(status(sim, :Leaf)) == 5
    @test length(status(sim, :plant_A, :Leaf)) == 2
    @test length(status(sim, :plant_B, :Leaf)) == 3

    scene_status = status(sim, :scene)
    last_meteo = last(maespa_meteo(; nhours=24))
    vpd_above = max(0.01, last_meteo.VPD)
    @test isfinite(scene_status.canopy_tair)
    @test isfinite(scene_status.canopy_vpd)
    @test isfinite(scene_status.canopy_rh)
    @test isfinite(scene_status.canopy_htot)
    @test isfinite(scene_status.canopy_gcanop)
    @test scene_status.canopy_tair >= last_meteo.T - 10.0
    @test scene_status.canopy_tair <= last_meteo.T + 10.0
    @test scene_status.canopy_vpd >= max(0.01, vpd_above - 1.5)
    @test scene_status.canopy_vpd <= vpd_above + 1.5
    @test scene_status.canopy_vpd > 0.0
    @test 0.0 <= scene_status.canopy_rh <= 1.0
    @test isfinite(scene_status.scene_transpiration)
    @test scene_status.scene_transpiration > 0.0
    @test scene_status.iterations > 0
    @test scene_status.leaf_area ≈ sum(st.leaf_area for st in status(sim, :Leaf))
    @test scene_status.lai ≈ scene_status.leaf_area
    @test scene_status.leaf_areas ≈ getproperty.(status(sim, :Leaf), :leaf_area)

    leaf_statuses = status(sim, :Leaf)
    @test all(st -> isfinite(st.Tₗ), leaf_statuses)
    @test all(st -> isfinite(st.A), leaf_statuses)
    @test all(st -> isfinite(st.λE), leaf_statuses)
    @test any(st -> abs(st.Tₗ - scene_status.canopy_tair) > 1.0e-6, leaf_statuses)

    plant_a_status = only(status(sim, :plant_A, :Plant))
    plant_b_status = only(status(sim, :plant_B, :Plant))
    @test plant_a_status.daily_growth > 0.0
    @test plant_b_status.daily_growth > 0.0
    @test plant_a_status.daily_growth != plant_b_status.daily_growth
    @test plant_a_status.leaf_pool != plant_b_status.leaf_pool

    deps = PlantSimEngine.explain_domain_dependencies(sim)
    @test count(row -> row.mode == :hard_domain && row.dependency == :energy_balance, deps) == 2
    @test count(row -> row.mode == :hard_domain && row.dependency == :soil, deps) == 1

    @test length(sim.outputs[(PlantSimEngine.DomainModelKey(:plant_A, :Leaf, :energy_balance), :λE)]) == 2 * 24
    @test length(sim.outputs[(PlantSimEngine.DomainModelKey(:plant_B, :Leaf, :energy_balance), :λE)]) == 3 * 24
    @test length(sim.outputs[(PlantSimEngine.DomainModelKey(:soil, :Default, :soil_water), :psi_soil)]) == 24
    @test length(sim.outputs[(PlantSimEngine.DomainModelKey(:scene, :Default, :lai_dynamic), :lai)]) == 1
    @test length(sim.outputs[(PlantSimEngine.DomainModelKey(:scene, :Default, :scene_eb), :scene_transpiration)]) == 24
    @test status(sim, :soil).transpiration ≈ scene_status.scene_transpiration
    @test status(sim, :soil).psi_soil ≈ scene_status.psi_soil
end

@testset "MAESPA-style unified scene example" begin
    result = run_maespa_scene_example(; nhours=25, check=true)
    scene = result.scene
    compiled = result.compiled

    @test length(scene_objects(scene; scale=:Leaf)) == 5
    @test length(scene_objects(scene; scale=:Leaf, species=:A)) == 2
    @test length(scene_objects(scene; scale=:Leaf, species=:B)) == 3
    @test length(scene_objects(scene; scale=:Plant)) == 2
    @test length(scene_objects(scene; kind=:soil)) == 1

    instance_rows = explain_instances(scene)
    @test Set(row.name for row in instance_rows) == Set([:plant_A, :plant_B])
    plant_a_instance = only(row for row in instance_rows if row.name == :plant_A)
    plant_b_instance = only(row for row in instance_rows if row.name == :plant_B)
    @test plant_a_instance.object_ids == [:plant_A, :plant_A_axis, :plant_A_leaf_1, :plant_A_leaf_2]
    @test plant_b_instance.object_ids == [:plant_B, :plant_B_axis, :plant_B_leaf_1, :plant_B_leaf_2, :plant_B_leaf_3]
    @test :plant_A__energy_balance in plant_a_instance.application_ids
    @test :plant_B__allocation in plant_b_instance.application_ids

    calls = explain_calls(compiled)
    scene_energy_call = only(row for row in calls if row.application_id == :scene_eb && row.call == :energy_balance)
    @test scene_energy_call.callee_object_ids == [
        :plant_A_leaf_1,
        :plant_A_leaf_2,
        :plant_B_leaf_1,
        :plant_B_leaf_2,
        :plant_B_leaf_3,
    ]
    @test Set(scene_energy_call.callee_application_ids) == Set([:plant_A__energy_balance, :plant_B__energy_balance])
    @test scene_energy_call.publication_policy == :explicit_accept
    @test !scene_energy_call.default_publish
    @test scene_energy_call.accepted_publish
    scene_soil_call = only(row for row in calls if row.application_id == :scene_eb && row.call == :soil)
    @test scene_soil_call.callee_object_ids == [:soil]
    @test scene_soil_call.callee_application_ids == [:soil_water]
    @test count(row -> row.call == :photosynthesis, calls) == 5
    @test count(row -> row.call == :stomatal_conductance, calls) == 5

    leaf_energy_bundle = only(
        row for row in explain_model_bundles(compiled)
        if row.application_id == :plant_A__energy_balance &&
           row.object_id == :plant_A_leaf_1
    )
    @test leaf_energy_bundle.processes == [
        :energy_balance,
        :photosynthesis,
        :stomatal_conductance,
    ]
    @test leaf_energy_bundle.model_types == [Monteith{Float64,Int64}, Fvcb{Float64}, Tuzet{Float64}]

    bindings = explain_bindings(compiled)
    lai_binding = only(row for row in bindings if row.application_id == :lai_dynamic && row.input == :leaf_areas)
    @test lai_binding.carrier_kind == :ref_vector
    @test lai_binding.copy_semantics == :live_references
    @test lai_binding.source_ids == scene_energy_call.callee_object_ids
    plant_a_allocation_binding = only(row for row in bindings if row.application_id == :plant_A__allocation)
    plant_b_allocation_binding = only(row for row in bindings if row.application_id == :plant_B__allocation)
    @test plant_a_allocation_binding.source_ids == [:plant_A_leaf_1, :plant_A_leaf_2]
    @test plant_b_allocation_binding.source_ids == [:plant_B_leaf_1, :plant_B_leaf_2, :plant_B_leaf_3]

    schedule = explain_schedule(compiled)
    @test only(row for row in schedule if row.application_id == :scene_eb).root_scheduled
    @test only(row for row in schedule if row.application_id == :plant_A__energy_balance).manual_call_only
    @test only(row for row in schedule if row.application_id == :soil_water).manual_call_only
    @test only(row for row in schedule if row.application_id == :plant_A__allocation).dt_steps == 24.0
    @test only(row for row in schedule if row.application_id == :lai_dynamic).dt_steps == 24.0

    scene_simulation = result.simulation
    @test scene_simulation isa SceneSimulation
    output_rows = collect_outputs(scene_simulation; sink=nothing)
    @test count(row -> row.variable == :λE, output_rows) == 5 * 25
    @test count(row -> row.object_id == :soil && row.variable == :psi_soil, output_rows) == 25
    @test count(row -> row.object_id == :scene && row.variable == :scene_transpiration, output_rows) == 25
    @test count(row -> row.object_id == :scene && row.variable == :lai, output_rows) == 2
    @test count(row -> row.variable == :daily_growth, output_rows) == 2 * 2
    output_summary = explain_outputs(scene_simulation)
    @test only(row for row in output_summary if row.object_id == :scene && row.variable == :scene_transpiration).nsamples == 25
    @test only(row for row in output_summary if row.object_id == :plant_A_leaf_1 && row.variable == :λE).application_id == :plant_A__energy_balance

    scene_status = only(scene_objects(scene; scale=:Scene)).status
    last_meteo = last(maespa_meteo(; nhours=25))
    vpd_above = max(0.01, last_meteo.VPD)
    @test isfinite(scene_status.canopy_tair)
    @test isfinite(scene_status.canopy_vpd)
    @test isfinite(scene_status.canopy_rh)
    @test scene_status.canopy_tair >= last_meteo.T - 10.0
    @test scene_status.canopy_tair <= last_meteo.T + 10.0
    @test scene_status.canopy_vpd >= max(0.01, vpd_above - 1.5)
    @test scene_status.canopy_vpd <= vpd_above + 1.5
    @test scene_status.scene_transpiration > 0.0
    @test scene_status.iterations > 0

    leaf_statuses = [object.status for object in scene_objects(scene; scale=:Leaf)]
    @test scene_status.leaf_area ≈ sum(st.leaf_area for st in leaf_statuses)
    @test scene_status.lai ≈ scene_status.leaf_area
    @test collect(scene_status.leaf_areas) ≈ getproperty.(leaf_statuses, :leaf_area)
    @test all(st -> isfinite(st.Tₗ), leaf_statuses)
    @test all(st -> isfinite(st.A), leaf_statuses)
    @test all(st -> isfinite(st.λE), leaf_statuses)
    @test any(st -> abs(st.Tₗ - scene_status.canopy_tair) > 1.0e-6, leaf_statuses)

    plant_a_status = only(scene_objects(scene; name=:plant_A)).status
    plant_b_status = only(scene_objects(scene; name=:plant_B)).status
    @test plant_a_status.daily_growth > 0.0
    @test plant_b_status.daily_growth > 0.0
    @test plant_a_status.daily_growth != plant_b_status.daily_growth
    @test plant_a_status.leaf_pool != plant_b_status.leaf_pool

    soil_status = only(scene_objects(scene; kind=:soil)).status
    @test soil_status.transpiration ≈ scene_status.scene_transpiration
    @test soil_status.psi_soil ≈ scene_status.psi_soil
end

@testset "MAESPA-style domain example validation" begin
    mtg = build_maespa_scene()
    meteo = maespa_meteo(; nhours=1)

    soil_mapping = PlantSimEngine.ModelMapping(
        ModelSpec(SoilWater(0.45, -0.03, 4.4, 0.25, 0.75)) |> TimeStep(Dates.Hour(1)),
        status=(theta1=0.33, theta2=0.36, psi_soil=-0.10, transpiration=0.0, infiltration=0.0),
    )
    scene_mapping = PlantSimEngine.ModelMapping(
        ModelSpec(LAIModel(1.0)) |> TimeStep(Dates.Hour(1)),
        ModelSpec(SceneEB(25, 0.03, 0.005)) |>
        Calls(
            :energy_balance => Many(kind=:plant, scale=:Leaf, process=:energy_balance),
            :soil => One(kind=:soil, process=:soil_water),
        ) |>
        TimeStep(Dates.Hour(1)),
        status=(
            leaf_area=0.0,
            lai=0.0,
            canopy_tair=20.0,
            canopy_vpd=1.0,
            canopy_rh=0.7,
            canopy_htot=0.0,
            canopy_gcanop=0.0,
            scene_transpiration=0.0,
            scene_assimilation=0.0,
            psi_soil=-0.1,
            iterations=0,
        ),
    )
    missing_leaf_mapping = PlantSimEngine.SimulationMapping(
        PlantSimEngine.Domain(:soil, soil_mapping; kind=:soil),
        PlantSimEngine.Domain(:scene, scene_mapping; kind=:scene),
    )
    @test_throws "Hard domain dependency `energy_balance`" run!(mtg, missing_leaf_mapping, meteo, check=true, executor=SequentialEx())

    soil_target = (status=Status(psi_soil=-0.1),)
    scene_status = Status(lai=0.0, leaf_area=0.0)
    @test_throws "SceneEB did not converge after 0 iterations" _solve_scene_energy_balance!(
        SceneEB(0, 0.03, 0.005),
        PlantSimEngine.ModelTarget[],
        soil_target,
        scene_status,
        first(meteo),
    )
end

@testset "MAESPA-style canopy helper functions" begin
    lai_model = LAIModel(2.0)
    lai_status = Status(leaf_areas=[0.5, 1.0], leaf_area=0.0, lai=0.0)
    PlantSimEngine.run!(lai_model, nothing, lai_status, nothing, nothing)
    @test lai_status.leaf_area ≈ 1.5
    @test lai_status.lai ≈ 0.75

    m = SceneEB(25, 0.03, 0.005; ground_area=2.0)

    low_wind = gbcanms(0.0, m.zht, m.tree_height; gbcan_min=m.gbcan_min, von_karman=m.von_karman)
    @test low_wind.canopy_air_ms ≈ m.gbcan_min
    @test isfinite(low_wind.soil_canopy_ms)

    meteo_above = Atmosphere(T=25.0, Rh=0.50, Wind=1.2, Ri_PAR_f=800.0, Ri_SW_f=400.0, duration=Dates.Hour(1))
    canopy_meteo = Atmosphere(T=25.0, Rh=0.50, Wind=1.2, P=meteo_above.P, Ri_PAR_f=800.0, Ri_SW_f=400.0, duration=Dates.Hour(1))
    hot_fluxes = (rn=5000.0, lambda_e=-5000.0, a=0.0, lai=0.75, rad_interc=0.0)
    hot = tvpdcanopcalc(m, hot_fluxes, meteo_above, canopy_meteo, PlantMeteo.Constants())
    @test hot.tair <= meteo_above.T + 10.0
    @test hot.vpd <= max(0.01, meteo_above.VPD) + 1.5

    wet_fluxes = (rn=-5000.0, lambda_e=5000.0, a=0.0, lai=0.75, rad_interc=0.0)
    wet = tvpdcanopcalc(m, wet_fluxes, meteo_above, canopy_meteo, PlantMeteo.Constants())
    @test wet.tair >= meteo_above.T - 10.0
    @test wet.vpd >= max(0.01, meteo_above.VPD - 1.5)
    @test wet.vpd >= 0.01
    @test 0.0 <= wet.rh <= 1.0
    @test meteo_above.T == 25.0
    @test max(0.01, meteo_above.VPD) == meteo_above.VPD
end

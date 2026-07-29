include("../examples/maespa_model_example.jl")

@testset "MAESPA-style model example" begin
    result = run_maespa_example(; nhours=25, check=true)
    model = result.model
    compiled = result.compiled

    @test length(model_objects(model; scale=:Leaf)) == 5
    @test length(model_objects(model; scale=:Leaf, species=:A)) == 2
    @test length(model_objects(model; scale=:Leaf, species=:B)) == 3
    @test length(model_objects(model; scale=:Plant)) == 2
    @test length(model_objects(model; kind=:soil)) == 1

    instance_rows = explain_instances(model)
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
    expected_scene_leaf_inputs = (
        leaf_areas=:leaf_area,
        leaf_carbon=:leaf_carbon,
        leaf_Ra_SW_f=:Ra_SW_f,
        leaf_aPPFD=:aPPFD,
        Ψₗ=:Ψₗ,
        leaf_rn=:Rn,
        leaf_lambda_e=:λE,
        leaf_h=:H,
        leaf_a=:A,
    )
    for (input, source_var) in pairs(expected_scene_leaf_inputs)
        binding = only(
            row for row in bindings
            if row.application_id == :scene_eb && row.input == input
        )
        @test binding.source_ids == scene_energy_call.callee_object_ids
        @test binding.source_var == source_var
        @test binding.carrier_kind == :ref_vector
        @test binding.copy_semantics == :live_references
    end
    scene_psi_binding = only(
        row for row in bindings
        if row.application_id == :scene_eb && row.input == :psi_soil
    )
    @test scene_psi_binding.source_ids == [:soil]
    @test scene_psi_binding.source_application_ids == [:soil_water]
    @test scene_psi_binding.source_var == :psi_soil
    @test scene_psi_binding.carrier_kind == :ref
    @test scene_psi_binding.copy_semantics == :live_references
    soil_transpiration_binding = only(
        row for row in bindings
        if row.application_id == :soil_water && row.input == :transpiration
    )
    @test soil_transpiration_binding.source_ids == [:model]
    @test soil_transpiration_binding.source_application_ids == [:scene_eb]
    @test soil_transpiration_binding.source_var == :scene_transpiration
    @test soil_transpiration_binding.carrier_kind == :ref
    @test soil_transpiration_binding.copy_semantics == :live_references
    soil_infiltration_binding = only(
        row for row in bindings
        if row.application_id == :soil_water && row.input == :infiltration
    )
    @test soil_infiltration_binding.source_ids == [:model]
    @test soil_infiltration_binding.source_application_ids == [:scene_eb]
    @test soil_infiltration_binding.source_var == :scene_infiltration
    @test soil_infiltration_binding.carrier_kind == :ref
    @test soil_infiltration_binding.copy_semantics == :live_references

    scene_object = only(model_objects(model; scale=:Scene))
    soil_object = only(model_objects(model; kind=:soil))
    for input in keys(expected_scene_leaf_inputs)
        compiled_binding = only(
            binding for binding in compiled.input_bindings
            if binding.application_id == :scene_eb && binding.input == input
        )
        @test getproperty(scene_object.status, input) === input_carrier(compiled_binding)
    end
    compiled_scene_psi_binding = only(
        binding for binding in compiled.input_bindings
        if binding.application_id == :scene_eb && binding.input == :psi_soil
    )
    @test PlantSimEngine.refvalue(scene_object.status, :psi_soil) ===
          input_carrier(compiled_scene_psi_binding)
    @test input_carrier(compiled_scene_psi_binding) ===
          PlantSimEngine.refvalue(soil_object.status, :psi_soil)
    compiled_soil_transpiration_binding = only(
        binding for binding in compiled.input_bindings
        if binding.application_id == :soil_water && binding.input == :transpiration
    )
    @test PlantSimEngine.refvalue(soil_object.status, :transpiration) ===
          input_carrier(compiled_soil_transpiration_binding)
    @test input_carrier(compiled_soil_transpiration_binding) ===
          PlantSimEngine.refvalue(scene_object.status, :scene_transpiration)
    compiled_soil_infiltration_binding = only(
        binding for binding in compiled.input_bindings
        if binding.application_id == :soil_water && binding.input == :infiltration
    )
    @test PlantSimEngine.refvalue(soil_object.status, :infiltration) ===
          input_carrier(compiled_soil_infiltration_binding)
    @test input_carrier(compiled_soil_infiltration_binding) ===
          PlantSimEngine.refvalue(scene_object.status, :scene_infiltration)

    schedule = explain_schedule(compiled)
    @test only(row for row in schedule if row.application_id == :scene_eb).root_scheduled
    @test only(row for row in schedule if row.application_id == :plant_A__energy_balance).manual_call_only
    @test only(row for row in schedule if row.application_id == :soil_water).manual_call_only
    @test only(row for row in schedule if row.application_id == :plant_A__allocation).dt_steps == 24.0
    @test only(row for row in schedule if row.application_id == :lai_dynamic).dt_steps == 24.0

    environment_rows = explain_environment_bindings(result.environment)
    scene_environment = only(row for row in environment_rows if row.application_id == :scene_eb)
    @test scene_environment.handle.provider == :forcing
    @test scene_environment.handle.sink == :canopy
    @test scene_environment.produced_outputs == [:T, :Rh]
    leaf_environment = only(
        row for row in environment_rows
        if row.application_id == :plant_A__energy_balance && row.object_id == :plant_A_leaf_1
    )
    @test leaf_environment.handle.provider == :canopy
    @test isnothing(leaf_environment.handle.sink)
    @test :T in leaf_environment.required_inputs
    @test :Rh in leaf_environment.required_inputs

    scene_simulation = result.simulation
    @test scene_simulation isa Simulation
    output_rows = collect_outputs(scene_simulation; sink=nothing)
    @test count(row -> row.variable == :λE, output_rows) == 5 * 25
    @test count(row -> row.object_id == :soil && row.variable == :psi_soil, output_rows) == 25
    @test count(row -> row.object_id == :model && row.variable == :scene_transpiration, output_rows) == 25
    @test count(row -> row.object_id == :model && row.variable == :scene_infiltration, output_rows) == 25
    @test count(row -> row.object_id == :model && row.variable == :lai, output_rows) == 2
    @test count(row -> row.variable == :daily_growth, output_rows) == 2 * 2
    output_summary = explain_outputs(scene_simulation)
    @test only(row for row in output_summary if row.object_id == :model && row.variable == :scene_transpiration).nsamples == 25
    @test only(row for row in output_summary if row.object_id == :plant_A_leaf_1 && row.variable == :λE).application_id == :plant_A__energy_balance

    scene_status = only(model_objects(model; scale=:Scene)).status
    @test !hasproperty(scene_status, :T)
    @test !hasproperty(scene_status, :Rh)
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
    @test model.environment isa MaespaSingleLayerEnvironment
    @test model.environment.canopy.T ≈ scene_status.canopy_tair
    @test model.environment.canopy.Rh ≈ scene_status.canopy_rh
    @test !(model.environment.canopy === model.environment.forcing)

    source = read(joinpath(@__DIR__, "..", "examples", "maespa_model_example.jl"), String)
    @test !occursin("support.process", source)
    @test !occursin("providers_by_application", source)
    @test !occursin("MaespaEnvironmentWrite", source)
    @test !occursin("cells_by_status", source)
    @test !occursin("geometry(object)", source)
    @test !occursin("PlantSimEngine.meteo_outputs_(::CanopyAir)", source)
    @test !occursin("with_environment!", source)
    @test !occursin("update_environment!", source)
    @test !occursin("EnvironmentSupport", source)

    leaf_statuses = [object.status for object in model_objects(model; scale=:Leaf)]
    @test scene_status.leaf_area ≈ sum(st.leaf_area for st in leaf_statuses)
    @test scene_status.lai ≈ scene_status.leaf_area
    @test collect(scene_status.leaf_areas) ≈ getproperty.(leaf_statuses, :leaf_area)
    @test collect(scene_status.leaf_carbon) ≈ getproperty.(leaf_statuses, :leaf_carbon)
    @test collect(scene_status.leaf_Ra_SW_f) ≈ getproperty.(leaf_statuses, :Ra_SW_f)
    @test collect(scene_status.leaf_aPPFD) ≈ getproperty.(leaf_statuses, :aPPFD)
    @test collect(scene_status.Ψₗ) ≈ getproperty.(leaf_statuses, :Ψₗ)
    @test collect(scene_status.leaf_rn) ≈ getproperty.(leaf_statuses, :Rn)
    @test collect(scene_status.leaf_lambda_e) ≈ getproperty.(leaf_statuses, :λE)
    @test collect(scene_status.leaf_h) ≈ getproperty.(leaf_statuses, :H)
    @test collect(scene_status.leaf_a) ≈ getproperty.(leaf_statuses, :A)
    @test all(st -> isfinite(st.Tₗ), leaf_statuses)
    @test all(st -> isfinite(st.A), leaf_statuses)
    @test all(st -> isfinite(st.λE), leaf_statuses)
    @test any(st -> abs(st.Tₗ - scene_status.canopy_tair) > 1.0e-6, leaf_statuses)

    plant_a_status = only(model_objects(model; name=:plant_A)).status
    plant_b_status = only(model_objects(model; name=:plant_B)).status
    @test plant_a_status.daily_growth > 0.0
    @test plant_b_status.daily_growth > 0.0
    @test plant_a_status.daily_growth != plant_b_status.daily_growth
    @test plant_a_status.leaf_pool != plant_b_status.leaf_pool

    soil_status = only(model_objects(model; kind=:soil)).status
    @test soil_status.transpiration ≈ scene_status.scene_transpiration
    @test soil_status.infiltration ≈ scene_status.scene_infiltration
    @test soil_status.psi_soil ≈ scene_status.psi_soil
end

@testset "MAESPA-style model example validation" begin
    meteo = maespa_meteo(; nhours=1)

    scene_status = _maespa_model_status()
    @test_throws "SceneEB did not converge after 0 iterations" _solve_model_energy_balance!(
        SceneEB(0, 0.03, 0.005),
        nothing,
        scene_status,
        first(meteo),
    )
end

@testset "MAESPA-style canopy helper functions" begin
    lai_model = LAIModel(2.0)
    lai_status = Status(leaf_areas=[0.5, 1.0], leaf_area=0.0, lai=0.0)
    PlantSimEngine.run!(lai_model, lai_status, nothing, nothing, nothing)
    @test lai_status.leaf_area ≈ 1.5
    @test lai_status.lai ≈ 0.75

    m = SceneEB(25, 0.03, 0.005; ground_area=2.0)

    low_wind = gbcanms(0.0, m.zht, m.tree_height; gbcan_min=m.gbcan_min, von_karman=m.von_karman)
    @test low_wind.canopy_air_ms ≈ m.gbcan_min
    @test isfinite(low_wind.soil_canopy_ms)

    meteo_above = Atmosphere(T=25.0, Rh=0.50, Wind=1.2, Ri_PAR_f=800.0, Ri_SW_f=400.0, duration=Dates.Hour(1))
    canopy_meteo = Atmosphere(T=25.0, Rh=0.50, Wind=1.2, P=meteo_above.P, Ri_PAR_f=800.0, Ri_SW_f=400.0, duration=Dates.Hour(1))
    hot_fluxes = (rn=5000.0, lambda_e=-5000.0, a=0.0, lai=0.75, rad_interc=0.0)
    hot = canopy_air_update(m, hot_fluxes, meteo_above, canopy_meteo, PlantMeteo.Constants())
    @test hot.tair <= meteo_above.T + 10.0
    @test hot.vpd <= max(0.01, meteo_above.VPD) + 1.5

    wet_fluxes = (rn=-5000.0, lambda_e=5000.0, a=0.0, lai=0.75, rad_interc=0.0)
    wet = canopy_air_update(m, wet_fluxes, meteo_above, canopy_meteo, PlantMeteo.Constants())
    @test wet.tair >= meteo_above.T - 10.0
    @test wet.vpd >= max(0.01, meteo_above.VPD - 1.5)
    @test wet.vpd >= 0.01
    @test 0.0 <= wet.rh <= 1.0
    @test meteo_above.T == 25.0
    @test max(0.01, meteo_above.VPD) == meteo_above.VPD
end

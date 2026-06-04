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

    deps = explain_domain_dependencies(sim)
    @test count(row -> row.mode == :hard_domain && row.dependency == :energy_balance, deps) == 2
    @test count(row -> row.mode == :hard_domain && row.dependency == :soil, deps) == 1

    @test length(sim.outputs[(DomainModelKey(:plant_A, :Leaf, :energy_balance), :λE)]) == 2 * 24
    @test length(sim.outputs[(DomainModelKey(:plant_B, :Leaf, :energy_balance), :λE)]) == 3 * 24
    @test length(sim.outputs[(DomainModelKey(:soil, :Default, :soil_water), :psi_soil)]) == 24
    @test length(sim.outputs[(DomainModelKey(:scene, :Default, :lai_dynamic), :lai)]) == 24
    @test length(sim.outputs[(DomainModelKey(:scene, :Default, :scene_eb), :scene_transpiration)]) == 24
    @test status(sim, :soil).transpiration ≈ scene_status.scene_transpiration
    @test status(sim, :soil).psi_soil ≈ scene_status.psi_soil
end

@testset "MAESPA-style domain example validation" begin
    mtg = build_maespa_scene()
    meteo = maespa_meteo(; nhours=1)

    soil_mapping = ModelMapping(
        ModelSpec(SoilWater(0.45, -0.03, 4.4, 0.25, 0.75)) |> TimeStepModel(Dates.Hour(1)),
        status=(theta1=0.33, theta2=0.36, psi_soil=-0.10, transpiration=0.0, infiltration=0.0),
    )
    scene_mapping = ModelMapping(
        ModelSpec(LAIModel(1.0)) |> TimeStepModel(Dates.Hour(1)),
        ModelSpec(SceneEB(25, 0.03, 0.005)) |> TimeStepModel(Dates.Hour(1)),
        status=(
            leaf_areas=[0.0],
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
    missing_leaf_mapping = SimulationMapping(
        Domain(:soil, soil_mapping; kind=:soil),
        Domain(:scene, scene_mapping; kind=:scene),
    )
    @test_throws "Hard domain dependency `energy_balance`" run!(mtg, missing_leaf_mapping, meteo, check=true, executor=SequentialEx())

    soil_target = (status=Status(psi_soil=-0.1),)
    scene_status = Status(lai=0.0, leaf_area=0.0)
    @test_throws "SceneEB did not converge after 0 iterations" _solve_scene_energy_balance!(
        SceneEB(0, 0.03, 0.005),
        ModelTarget[],
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

    low_wind = gbcanms(0.0, m.zht, m.z0ht, m.zpd, m.tree_height, 0.75; gbcan_min=m.gbcan_min, von_karman=m.von_karman)
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

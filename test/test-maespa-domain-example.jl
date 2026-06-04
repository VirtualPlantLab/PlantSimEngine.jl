include("../examples/maespa_domain_example.jl")

@testset "MAESPA-style domain example" begin
    result = run_maespa_example(; nhours=24, check=true)
    sim = result.simulation

    @test length(status(sim, :Leaf)) == 5
    @test length(status(sim, :plant_A, :Leaf)) == 2
    @test length(status(sim, :plant_B, :Leaf)) == 3

    scene_status = status(sim, :scene)
    @test isfinite(scene_status.canopy_Tair)
    @test isfinite(scene_status.canopy_VPD)
    @test isfinite(scene_status.scene_transpiration)
    @test scene_status.scene_transpiration > 0.0
    @test scene_status.iterations > 0

    leaf_statuses = status(sim, :Leaf)
    @test all(st -> isfinite(st.Tleaf), leaf_statuses)
    @test all(st -> isfinite(st.An), leaf_statuses)
    @test all(st -> isfinite(st.E), leaf_statuses)
    @test any(st -> abs(st.Tleaf - st.Tair) > 1.0e-6, leaf_statuses)

    plant_a_status = only(status(sim, :plant_A, :Plant))
    plant_b_status = only(status(sim, :plant_B, :Plant))
    @test plant_a_status.daily_growth > 0.0
    @test plant_b_status.daily_growth > 0.0
    @test plant_a_status.daily_growth != plant_b_status.daily_growth
    @test plant_a_status.leaf_pool != plant_b_status.leaf_pool

    deps = explain_domain_dependencies(sim)
    @test count(row -> row.mode == :hard_domain && row.dependency == :leaf_eb, deps) == 2
    @test count(row -> row.mode == :hard_domain && row.dependency == :soil, deps) == 1

    @test length(sim.outputs[(DomainModelKey(:plant_A, :Leaf, :leaf_eb), :E)]) == 2 * 24
    @test length(sim.outputs[(DomainModelKey(:plant_B, :Leaf, :leaf_eb), :E)]) == 3 * 24
    @test length(sim.outputs[(DomainModelKey(:soil, :Default, :soil_water), :psi_soil)]) == 24
    @test length(sim.outputs[(DomainModelKey(:scene, :Default, :scene_eb), :scene_transpiration)]) == 24
    @test status(sim, :soil).transpiration ≈ scene_status.scene_transpiration
    @test status(sim, :soil).psi_soil ≈ scene_status.psi_soil
end

@testset "MAESPA-style domain example validation" begin
    mtg = build_maespa_scene()
    meteo = maespa_meteo(; nhours=1)

    soil_mapping = ModelMapping(
        ModelSpec(SoilWater(0.45, -0.03, 4.4, 0.25, 0.75, true)) |> TimeStepModel(Dates.Hour(1)),
        status=(theta1=0.33, theta2=0.36, psi_soil=-0.10, transpiration=0.0, infiltration=0.0),
    )
    scene_mapping = ModelMapping(
        ModelSpec(SceneEB(25, 0.03, 0.005)) |> TimeStepModel(Dates.Hour(1)),
        status=(canopy_Tair=20.0, canopy_VPD=1.0, scene_transpiration=0.0, scene_assimilation=0.0, psi_soil=-0.1, iterations=0),
    )
    missing_leaf_mapping = SimulationMapping(
        Domain(:soil, soil_mapping; kind=:soil),
        Domain(:scene, scene_mapping; kind=:scene),
    )
    @test_throws "Hard domain dependency `leaf_eb`" run!(mtg, missing_leaf_mapping, meteo, check=true, executor=SequentialEx())

    soil_target = (status=Status(psi_soil=-0.1),)
    @test_throws "SceneEB did not converge after 0 iterations" _solve_scene_energy_balance!(
        SceneEB(0, 0.03, 0.005),
        ModelTarget[],
        soil_target,
        first(meteo),
    )
end

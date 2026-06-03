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
end

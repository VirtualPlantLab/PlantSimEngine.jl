@testset "Testing Statistics" begin
    obs = [1.0, 2.0, 3.0]
    sim = [1.1, 2.1, 3.1]

    @test RMSE(obs, sim) == 0.10000000000000009
    @test NRMSE(obs, sim) == 0.050000000000000044
    @test EF(obs, sim) == 0.985
    @test dr(obs, sim) == 0.9249999999999999
end
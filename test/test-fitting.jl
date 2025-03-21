# Tests:
# Defining a list of models without status:
@testset "Fitting Beer" begin
    k = 0.6
    meteo = Atmosphere(T=20.0, Wind=1.0, P=101.3, Rh=0.65, Ri_PAR_f=300.0)
    m = ModelList(Beer(k), status=(LAI=2.0,))
    outs = run!(m, meteo)

    df = DataFrame(aPPFD=outs[:aPPFD][1], LAI=m.status.LAI[1], Ri_PAR_f=meteo.Ri_PAR_f[1])

    k_fit = fit(PlantSimEngine.Examples.Beer, df).k
    @test k_fit == k
end;


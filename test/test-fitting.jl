using Dates

@testset "Fitting Beer" begin
    constants = PlantMeteo.Constants()
    k = 0.6
    meteo = Atmosphere(
        T=20.0,
        Wind=1.0,
        P=101.3,
        Rh=0.65,
        Ri_PAR_f=300.0,
        duration=Dates.Hour(1),
    )
    model = CompositeModel(
        Object(:plant; scale=:Plant, status=Status(LAI=2.0));
        applications=(
            ModelSpec(Beer(k); name=:canopy_light, on=One(scale=:Plant)),
        ),
        environment=meteo,
    )
    run!(model)
    plant = only(model_objects(model; scale=:Plant))
    simulated = DataFrame(
        aPPFD=[plant.status.aPPFD],
        LAI=[plant.status.LAI],
        Ri_PAR_f=[meteo.Ri_PAR_f[1]],
    )
    incident_ppfd = meteo.Ri_PAR_f[1] * constants.J_to_umol
    simulated_f_abs = plant.status.aPPFD / incident_ppfd

    @test 0.0 < plant.status.aPPFD < incident_ppfd
    @test simulated_f_abs ≈ 1.0 - exp(-k * plant.status.LAI)
    @test fit(PlantSimEngine.Examples.Beer, simulated).k ≈ k

    lai = [1.0, 2.0, 3.0]
    incident_par = [200.0, 300.0, 400.0]
    expected_k = -log1p(-0.6) / 2.0
    expected_f_abs = @. 1.0 - exp(-expected_k * lai)
    observations = DataFrame(
        LAI=lai,
        Ri_PAR_f=incident_par,
        aPPFD=incident_par .* constants.J_to_umol .* expected_f_abs,
    )
    fitted = fit(PlantSimEngine.Examples.Beer, observations)
    reconstructed_f_abs = @. 1.0 - exp(-fitted.k * lai)

    @test expected_f_abs[2] ≈ 0.6
    @test fitted.k ≈ expected_k
    @test reconstructed_f_abs ≈ expected_f_abs

    observation(lai, f_abs; incident=300.0) = DataFrame(
        LAI=[lai],
        Ri_PAR_f=[incident],
        aPPFD=[incident * constants.J_to_umol * f_abs],
    )
    @test fit(PlantSimEngine.Examples.Beer, observation(2.0, 0.0)).k == 0.0

    tiny = observation(2.0, eps(Float64) / 2.0)
    tiny_f_abs = tiny.aPPFD[1] / (tiny.Ri_PAR_f[1] * constants.J_to_umol)
    tiny_k = fit(PlantSimEngine.Examples.Beer, tiny).k
    @test tiny_k > 0.0
    @test tiny_k ≈ -log1p(-tiny_f_abs) / tiny.LAI[1]

    @test_throws ArgumentError fit(
        PlantSimEngine.Examples.Beer,
        DataFrame(LAI=Float64[], Ri_PAR_f=Float64[], aPPFD=Float64[]),
    )

    for invalid_lai in (0.0, -1.0, Inf, NaN)
        @test_throws DomainError fit(
            PlantSimEngine.Examples.Beer,
            observation(invalid_lai, 0.6),
        )
    end
    for invalid_f_abs in (-0.1, 1.0, 1.1, Inf, NaN)
        @test_throws DomainError fit(
            PlantSimEngine.Examples.Beer,
            observation(2.0, invalid_f_abs),
        )
    end
    for invalid_incident in (0.0, -1.0, Inf, -Inf, NaN)
        @test_throws DomainError fit(
            PlantSimEngine.Examples.Beer,
            observation(2.0, 0.6; incident=invalid_incident),
        )
    end

    for invalid_J_to_umol in (0.0, -1.0, Inf, -Inf, NaN)
        @test_throws DomainError fit(
            PlantSimEngine.Examples.Beer,
            observation(2.0, 0.6);
            J_to_umol=invalid_J_to_umol,
        )
    end

    double_negative = DataFrame(
        LAI=[2.0],
        Ri_PAR_f=[-300.0],
        aPPFD=[300.0 * constants.J_to_umol * 0.6],
    )
    @test_throws DomainError fit(
        PlantSimEngine.Examples.Beer,
        double_negative;
        J_to_umol=-constants.J_to_umol,
    )
end

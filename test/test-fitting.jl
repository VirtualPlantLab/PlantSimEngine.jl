using Dates

# Tests:
# Defining a list of models without status:
@testset "Fitting Beer" begin
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
        Object(:leaf; scale=:Leaf, status=Status(LAI=2.0));
        applications=(
            ModelSpec(Beer(k)) |> AppliesTo(One(scale=:Leaf)),
        ),
        environment=meteo,
    )
    run!(model)
    leaf = only(model_objects(model; scale=:Leaf))
    df = DataFrame(
        aPPFD=[leaf.status.aPPFD],
        LAI=[leaf.status.LAI],
        Ri_PAR_f=[meteo.Ri_PAR_f[1]],
    )

    k_fit = fit(PlantSimEngine.Examples.Beer, df).k
    @test k_fit == k
end

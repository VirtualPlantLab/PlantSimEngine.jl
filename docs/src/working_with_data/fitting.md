# Parameter Fitting

`PlantSimEngine.fit` is a shared interface for model-specific calibration.
Model packages implement a method whose first argument is the model type and
whose second argument is Tables.jl-compatible observations.

```julia
function PlantSimEngine.fit(
    ::Type{Beer},
    data;
    J_to_umol=PlantMeteo.Constants().J_to_umol,
)
    k = Statistics.mean(
        log.(data.Ri_PAR_f ./ (data.aPPFD ./ J_to_umol)) ./ data.LAI,
    )
    return (k=k,)
end
```

The result should be a `NamedTuple` of fitted parameters.

```@example fitting
using PlantSimEngine, PlantMeteo, Dates, DataFrames
using PlantSimEngine.Examples

meteo = Atmosphere(
    T=20.0,
    Wind=1.0,
    P=101.3,
    Rh=0.65,
    Ri_PAR_f=300.0,
    duration=Hour(1),
)

scene = Scene(
    Beer(0.6);
    status=(LAI=2.0,),
    id=:leaf,
    scale=:Leaf,
    environment=meteo,
)

run!(scene)
leaf = only(scene_objects(scene; scale=:Leaf))
data = DataFrame(
    aPPFD=[leaf.status.aPPFD],
    LAI=[leaf.status.LAI],
    Ri_PAR_f=[meteo.Ri_PAR_f[1]],
)

fit(Beer, data)
```

This example recovers the parameter used to generate the synthetic
observation. Real calibration methods can use any optimizer or uncertainty
framework and may return additional diagnostics.

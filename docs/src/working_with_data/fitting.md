# Parameter Fitting

Parameter fitting means finding parameter values that make a model agree
with observations. PlantSimEngine provides `Evaluation.fit` as a common
function name; each model package supplies the fitting method for its own
models. Pass the model type first and a table of observations second.
The table can be a DataFrame or another format supported by Tables.jl.

For the `Beer` model, we can calculate the light-extinction coefficient `k`
from LAI, incoming light, and absorbed light:

```julia
J_to_umol = PlantMeteo.Constants().J_to_umol
incident_ppfd = J_to_umol .* data.Ri_PAR_f
f_abs = data.aPPFD ./ incident_ppfd
k = Statistics.mean(-log1p.(-f_abs) ./ data.LAI)
```

This snippet only shows how to rearrange Beer's equation to find `k`. The implementation in
`examples/Beer.jl` validates every observation and returns `(k=k,)`; do not use
the snippet alone as an unchecked fitting method.

A fitting method returns named parameter values, for example `(k=0.6,)`.

In this Beer example, `Ri_PAR_f` measures incoming light per unit ground area
and `aPPFD` measures light absorbed by the whole canopy per unit ground area.
`LAI` is leaf area per unit ground area. Do not use a PPFD expressed per unit
leaf area in this calculation. The fit rejects empty data, non-finite or
non-positive `LAI` and incident PAR, and absorbed fractions outside `[0, 1)`.

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

model = CompositeModel(
    Beer(0.6);
    status=(LAI=2.0,),
    id=:plant,
    scale=:Plant,
    environment=meteo,
)

simulation = run!(model)
plant = final_state(simulation, One(scale=:Plant))
data = DataFrame(
    aPPFD=[plant.aPPFD],
    LAI=[plant.LAI],
    Ri_PAR_f=[meteo.Ri_PAR_f[1]],
)

PlantSimEngine.Evaluation.fit(Beer, data)
```

This example recovers the parameter used to generate the synthetic
observation. Real calibration methods can use any optimizer or uncertainty
framework and may return additional diagnostics.

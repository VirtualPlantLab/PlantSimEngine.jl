
"""
    fit()

Optimize the parameters of a model using measurements and (potentially) initialisation values. 

Modellers should implement a method to `fit` for their model, with the following design pattern:

The call to the function should take the model type as the first argument (T::Type{<:AbstractModel}), 
the data as the second argument (as a `Table.jl` compatible type, such as `DataFrame`), and the 
parameters initializations as keyword arguments (with default values when necessary).

For example, the method for fitting the `Beer` model from the example script
(see `examples/Beer.jl`) uses this mathematical identity after validating each
observation:

```julia
J_to_umol = PlantMeteo.Constants().J_to_umol
incident_ppfd = J_to_umol .* df.Ri_PAR_f
f_abs = df.aPPFD ./ incident_ppfd
k = Statistics.mean(-log1p.(-f_abs) ./ df.LAI)
```

This is only the inversion, not a complete implementation to copy. The shipped
`Beer` method also rejects empty data and invalid `LAI`, incident flux, and
absorbed fractions with row-specific errors.

Here, `Ri_PAR_f` is incident PAR in W m[ground]⁻², `aPPFD` is the PAR
absorbed by the canopy in μmol[PAR] m[ground]⁻² s⁻¹, and `LAI` is in
m[leaf]² m[ground]⁻². A mean leaf-area-basis PPFD is a different quantity and
must not be passed to this fit.

The function should return the optimized parameters as a `NamedTuple` of the form `(parameter_name=parameter_value,)`.

Here is an example usage with the `Beer` model, where we fit the `k` parameter from "measurements" of `aPPFD`, `LAI` 
and `Ri_PAR_f`. 

```julia
# Including example processes and models:
using PlantSimEngine.Examples;
using PlantSimEngine.Evaluation;

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
Evaluation.fit(Beer, data)
```

This is a synthetic round trip: it simulates canopy-absorbed `aPPFD` with
`k=0.6`, then recovers the same value from the ground-area-basis fluxes.
"""
function fit end


"""
    fit()

Optimize the parameters of a model using measurements and (potentially) initialisation values. 

Modellers should implement a method to `fit` for their model, with the following design pattern:

The call to the function should take the model type as the first argument (T::Type{<:AbstractModel}), 
the data as the second argument (as a `Table.jl` compatible type, such as `DataFrame`), and the 
parameters initializations as keyword arguments (with default values when necessary).

For example the method for fitting the `Beer` model from the example script (see `src/examples/Beer.jl`) looks like 
this:

```julia
function PlantSimEngine.Evaluation.fit(
    ::Type{Beer},
    df;
    J_to_umol=PlantMeteo.Constants().J_to_umol,
)
    k = Statistics.mean(log.(df.Ri_PAR_f ./ (df.aPPFD ./ J_to_umol)) ./ df.LAI)
    return (k=k,)
end
```

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
    id=:leaf,
    scale=:Leaf,
    environment=meteo,
)
run!(model)
leaf = only(model_objects(model; scale=:Leaf))
df = DataFrame(
    aPPFD=leaf.status.aPPFD,
    LAI=leaf.status.LAI,
    Ri_PAR_f=meteo.Ri_PAR_f[1],
)
Evaluation.fit(Beer, df)
```

Note that this is a dummy example to show that the fitting method works, as we simulate the aPPFD 
using the Beer-Lambert law with a value of `k=0.6`, and then use the simulated aPPFD to fit the `k`
parameter again, which gives the same value as the one used on the simulation.
"""
function fit end

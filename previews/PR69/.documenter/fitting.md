
# Parameter fitting {#Parameter-fitting}

## The fit method {#The-fit-method}

Models are often calibrated using data, but the calibration process is not always the same depending on the model, and the data available to the user.

`PlantSimEngine` defines a generic [`fit`](/API#PlantSimEngine.fit) function that allows modelers provide a fitting algorithm for their model, and for users to use this method to calibrate the model using data.

The function does nothing in this package, it is only defined to provide a common interface for all the models. It is up to the modeler to implement the method for their model. 

The method is implemented as a function with the following design pattern: the call to the function should take the model type as the first argument (T::Type{&lt;:AbstractModel}), the data as the second argument (as a `Table.jl` compatible type, such as `DataFrame`), and any more information as keyword arguments, _e.g._ constants or parameters initializations with default values when necessary.

## Example with Beer {#Example-with-Beer}

The example script (see `src/examples/Beer.jl`) that implements the `Beer` model provides an example of how to implement the `fit` method for a model:

```julia
function PlantSimEngine.fit(::Type{Beer}, df; J_to_umol=PlantMeteo.Constants().J_to_umol)
    k = Statistics.mean(log.(df.Ri_PAR_f ./ (df.PPFD ./ J_to_umol)) ./ df.LAI)
    return (k=k,)
end
```


The function takes a `Beer` type as the first argument, the data as a `Tables.jl` compatible type, such as a `DataFrame` as the second argument, and the `J_to_umol` constant as a keyword argument, which is used to convert between μ mol m⁻² s⁻¹ and J m⁻² s⁻¹.

`df` should contain the columns `PPFD` (μ mol m⁻² s⁻¹), `LAI` (m² m⁻²) and `Ri_PAR_f` (W m⁻²). The function then computes `k` based on these values, and returns it as a `NamedTuple` of the form `(parameter_name=parameter_value,)`.

Here&#39;s an example of how to use the `fit` method:

Importing the script first: 

```julia
using PlantSimEngine, PlantMeteo, DataFrames, Statistics
# Import the examples defined in the `Examples` sub-module:
using PlantSimEngine.Examples
```


Defining the meteo data:

```julia
meteo = Atmosphere(T=20.0, Wind=1.0, P=101.3, Rh=0.65, Ri_PAR_f=300.0)
```


```
Atmosphere(date = Dates.DateTime("2024-04-11T16:41:06.961"), duration = Dates.Second(1), T = 20.0, Wind = 1.0, P = 101.3, Rh = 0.65, Precipitations = 0.0, Cₐ = 400.0, e = 1.5255470730405223, eₛ = 2.3469954969854188, VPD = 0.8214484239448965, ρ = 1.2037851579511918, λ = 2.4537e6, γ = 0.06723680111943287, ε = 0.5848056484857892, Δ = 0.14573378083416522, clearness = Inf, Ri_SW_f = Inf, Ri_PAR_f = 300.0, Ri_NIR_f = Inf, Ri_TIR_f = Inf, Ri_custom_f = Inf)
```


Computing the `PPFD` values from the `Ri_PAR_f` values using the `Beer` model (with `k=0.6`):

```julia
m = ModelList(Beer(0.6), status=(LAI=2.0,))
run!(m, meteo)
```


Now we can define the &quot;data&quot; to fit the model using the simulated `PPFD` values:

```julia
df = DataFrame(aPPFD=m[:aPPFD][1], LAI=m.status.LAI[1], Ri_PAR_f=meteo.Ri_PAR_f[1])
```


And finally we can fit the model using the `fit` method:

```julia
fit(Beer, df)
```


```
(k = 0.6,)
```


::: tip Note

This is a dummy example to show that the fitting method works. A real application would fit the parameter values on the data directly.

:::

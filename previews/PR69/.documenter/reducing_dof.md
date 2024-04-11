
# Reducing the DoF {#Reducing-the-DoF}

## Introduction {#Introduction}

### Why reducing the degrees of freedom {#Why-reducing-the-degrees-of-freedom}

Reducing the degrees of freedom in a model, by forcing certain variables to measurements, can be useful for several reasons:
1. It can prevent overfitting by constraining the model and making it less complex.
  
1. It can help to better calibrate the other components of the model by reducing the co-variability of the variables (see [Parameter degeneracy](/reducing_dof#Parameter-degeneracy)).
  
1. It can lead to more interpretable models by identifying the most important variables and relationships.
  
1. It can improve the computational efficiency of the model by reducing the number of variables that need to be estimated.
  
1. It can also help to ensure that the model is consistent with known physical or observational constraints and improve the credibility of the model and its predictions.
  
1. It is important to note that over-constraining a model can also lead to poor fits and false conclusions, so it is essential to carefully consider which variables to constrain and to what measurements.
  

## Parameter degeneracy {#Parameter-degeneracy}

The concept of &quot;degeneracy&quot; or &quot;parameter degeneracy&quot; in a model occurs when two or more variables in a model are highly correlated, and small changes in one variable can be compensated by small changes in another variable, so that the overall predictions of the model remain unchanged. Degeneracy can make it difficult to estimate the true values of the variables and to determine the unique solutions of the model. It also makes the model sensitive to the initial conditions (_e.g._ the parameters) and the optimization algorithm used.

Degeneracy is related to the concept of &quot;co-variability&quot; or &quot;collinearity&quot;, which refers to the degree of linear relationship between two or more variables. In a degenerate model, two or more variables are highly co-variate, meaning that they are highly correlated and can produce similar predictions. By fixing one variable to a measured value, the model will have less flexibility to adjust the other variables, which can help to reduce the co-variability and improve the robustness of the model.

This is an important topic in plant/crop modelling, as the models are very often degenerate. It is most often referred to as &quot;multicollinearity&quot; in the field. In the context of model calibration, it is also known as &quot;parameter degeneracy&quot; or &quot;parameter collinearity&quot;. In the context of model reduction, it is also known as &quot;redundancy&quot; or &quot;redundant variables&quot;.

## Reducing the DoF in PlantSimEngine {#Reducing-the-DoF-in-PlantSimEngine}

### Soft-coupled models {#Soft-coupled-models}

PlantSimEngine provides a simple way to reduce the degrees of freedom in a model by constraining the values of some variables to measurements.

Let&#39;s define a model list as usual with the seven processes from `examples/dummy.jl`:

```julia
using PlantSimEngine, PlantMeteo
# Import the examples defined in the `Examples` sub-module:
using PlantSimEngine.Examples

meteo = Atmosphere(T = 20.0, Wind = 1.0, P = 101.3, Rh = 0.65)
m = ModelList(
    Process1Model(2.0),
    Process2Model(),
    Process3Model(),
    Process4Model(),
    Process5Model(),
    Process6Model(),
    Process7Model(),
    status=(var0 = 0.5,)
)

run!(m, meteo)

status(m)
```


```
TimeStepTable{Status{(:var0, :var1, :var2, ...}(1 x 10):
╭─────┬─────────┬─────────┬─────────┬─────────┬─────────┬─────────┬─────────┬───
│ Row │    var0 │    var1 │    var2 │    var5 │    var4 │    var6 │    var3 │  ⋯
│     │ Float64 │ Float64 │ Float64 │ Float64 │ Float64 │ Float64 │ Float64 │  ⋯
├─────┼─────────┼─────────┼─────────┼─────────┼─────────┼─────────┼─────────┼───
│   1 │     0.5 │    0.51 │    0.53 │ 28.4906 │  9.0812 │ 37.5718 │  2.2703 │  ⋯
╰─────┴─────────┴─────────┴─────────┴─────────┴─────────┴─────────┴─────────┴───
                                                               3 columns omitted

```


Let&#39;s say that `m` is our complete model, and that we want to reduce the degrees of freedom by constraining the value of `var9` to a measurement, which was previously computed by `Process7Model`, a soft-dependency model. It is very easy to do this in PlantSimEngine: just remove the model from the model list and give the value of the measurement in the status:

```julia
m2 = ModelList(
    Process1Model(2.0),
    Process2Model(),
    Process3Model(),
    Process4Model(),
    Process5Model(),
    Process6Model(),
    status=(var0 = 0.5, var9 = 10.0),
)

run!(m2, meteo)

status(m2)
```


```
TimeStepTable{Status{(:var0, :var1, :var2, ...}(1 x 10):
╭─────┬─────────┬─────────┬─────────┬─────────┬─────────┬─────────┬─────────┬───
│ Row │    var0 │    var1 │    var2 │    var5 │    var4 │    var6 │    var3 │  ⋯
│     │ Float64 │ Float64 │ Float64 │ Float64 │ Float64 │ Float64 │ Float64 │  ⋯
├─────┼─────────┼─────────┼─────────┼─────────┼─────────┼─────────┼─────────┼───
│   1 │     0.5 │    0.51 │    0.53 │ 28.4906 │  9.0812 │ 37.5718 │  2.2703 │  ⋯
╰─────┴─────────┴─────────┴─────────┴─────────┴─────────┴─────────┴─────────┴───
                                                               3 columns omitted

```


And that&#39;s it ! The models that depend on `var9` will now use the measured value of `var9` instead of the one computed by `Process7Model`.

### Hard-coupled models {#Hard-coupled-models}

It is a bit more complicated to reduce the degrees of freedom in a model that is hard-coupled to another model, because it calls the `run!` method of the other model.

In this case, we need to replace the old model with a new model that forces the value of the variable to the measurement. This is done by giving the measurements as inputs of the new model, and returning nothing so the value is unchanged. 

Starting from the model list with the seven processes from above, but this time let&#39;s say that we want to reduce the degrees of freedom by constraining the value of `var3` to a measurement, which was previously computed by `Process1Model`, a hard-dependency model. It is very easy to do this in PlantSimEngine: just replace the model by a new model that forces the value of `var3` to the measurement:

```julia
struct ForceProcess1Model <: AbstractProcess1Model end
PlantSimEngine.inputs_(::ForceProcess1Model) = (var3=-Inf,)
PlantSimEngine.outputs_(::ForceProcess1Model) = (var3=-Inf,)
function PlantSimEngine.run!(::ForceProcess1Model, models, status, meteo, constants=nothing, extra=nothing)
    return nothing
end
```


Now we can create a new model list with the new model for `process7`:

```julia
m3 = ModelList(
    ForceProcess1Model(),
    Process2Model(),
    Process3Model(),
    Process4Model(),
    Process5Model(),
    Process6Model(),
    Process7Model(),
    status = (var0=0.5,var3 = 10.0)
)

run!(m3, meteo)

status(m3)
```


```
TimeStepTable{Status{(:var0, :var1, :var2, ...}(1 x 10):
╭─────┬─────────┬─────────┬─────────┬─────────┬─────────┬─────────┬─────────┬───
│ Row │    var0 │    var1 │    var2 │    var5 │    var4 │    var6 │    var3 │  ⋯
│     │ Float64 │ Float64 │ Float64 │ Float64 │ Float64 │ Float64 │ Float64 │  ⋯
├─────┼─────────┼─────────┼─────────┼─────────┼─────────┼─────────┼─────────┼───
│   1 │     0.5 │    0.51 │    0.53 │   43.95 │    40.0 │   83.95 │    10.0 │  ⋯
╰─────┴─────────┴─────────┴─────────┴─────────┴─────────┴─────────┴─────────┴───
                                                               3 columns omitted

```


::: tip Note

We could also eventually provide the measured variable using the meteo data, but it is not recommended. The meteo data is meant to be used for the meteo variables only, and not for the model variables. It is better to use the status for that.

:::

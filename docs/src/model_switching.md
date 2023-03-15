# Model switching

```@setup usepkg
using PlantSimEngine, PlantMeteo
include(joinpath(pkgdir(PlantSimEngine), "examples/dummy.jl"))
meteo = Atmosphere(T = 20.0, Wind = 1.0, P = 101.3, Rh = 0.65)
m = ModelList(
    Process1Model(2.0), 
    Process2Model(),
    Process3Model(),
    Process4Model(),
    Process5Model(),
    Process6Model(),
    Process7Model(),
    status = (var0=1.0,)
)
run!(m, meteo)
struct AnotherProcess1Model <: AbstractProcess1Model
    a
    b # this is a new parameter
end
PlantSimEngine.inputs_(::AnotherProcess1Model) = (var1=-Inf, var2=-Inf, var10=-Inf,)
PlantSimEngine.outputs_(::AnotherProcess1Model) = (var3=-Inf,)
function PlantSimEngine.run!(::AnotherProcess1Model, models, status, meteo, constants=nothing, extra=nothing)
    status.var3 = models.process1.a + status.var1 * status.var2 + status.var10
end
m2 = ModelList(
    AnotherProcess1Model(2.0, 0.5), 
    Process2Model(),
    Process3Model(),
    Process4Model(),
    Process5Model(),
    Process6Model(),
    Process7Model(),
    status = (var0=1.0, var10=2.0)
)
run!(m2, meteo)
```

One of the main objective of PlantSimEngine is allowing users to switch between model implementations for a given process **without making any change to the code**. 

The package was carefully designed around this idea to make it easy and computationally efficient. This is done by using the `ModelList`, which is used to list models, and the `run!` function to run the simulation following the dependency graph and leveraging Julia's multiple dispatch to run the models.

## ModelList

The `ModelList` is a container that holds a list of models, their parameter values, and the status of the variables associated to them.

Model coupling is done by adding models to the `ModelList`. Let's create a `ModelList` with the seven models from the example script `examples/dummy.jl`:

```julia
using PlantSimEngine
include(joinpath(pkgdir(PlantSimEngine), "examples/dummy.jl"))
```

```@example usepkg
include the dummy models
m = ModelList(
    Process1Model(2.0), 
    Process2Model(),
    Process3Model(),
    Process4Model(),
    Process5Model(),
    Process6Model(),
    Process7Model(),
    status = (var0=1.0,)
)

nothing # hide
```

PlantSimEngine uses the `ModelList` to compute the dependency graph of the models. Here we have seven models, one for each process. The dependency graph is computed automatically by PlantSimEngine, and is used to run the simulation in the correct order.

We can run the simulation by calling the `run!` function with a meteorology:

```@example usepkg
meteo = Atmosphere(T = 20.0, Wind = 1.0, P = 101.3, Rh = 0.65)

run!(m, meteo)
```

And then we can access the status of the variables:

```@example usepkg
status(m)
```

Now what if we want to switch the model for process 1? We can do this by simply replacing the model in the `ModelList`, and PlantSimEngine will automatically update the dependency graph, and adapt the simulation to the new model.

First, let's create a new model for process 1. This model is a copy of the old model, but with one more input (`var10`) and one more parameter (`b`):

``` julia
struct AnotherProcess1Model <: AbstractProcess1Model
    a
    b # this is a new parameter
end
PlantSimEngine.inputs_(::AnotherProcess1Model) = (var1=-Inf, var2=-Inf, var10=-Inf)
PlantSimEngine.outputs_(::AnotherProcess1Model) = (var3=-Inf,)
function PlantSimEngine.run!(::AnotherProcess1Model, models, status, meteo, constants=nothing, extra=nothing)
    status.var3 = models.process1.a + status.var1 * status.var2 + models.process1.b * status.var10
end
```

Now we can switch the model used for process 1 by simply replacing the old model (`Process1Model`) by the new one `AnotherProcess1Model` in the `ModelList`:

```@example usepkg
m2 = ModelList(
    AnotherProcess1Model(2.0, 0.5), 
    Process2Model(),
    Process3Model(),
    Process4Model(),
    Process5Model(),
    Process6Model(),
    Process7Model(),
    status = (var0=1.0, var10=2.0)
)

nothing # hide
```

And run the simulation with the new model:

```@example usepkg
run!(m2, meteo)
```

And we can see that the status of the variables is different from the previous simulation:

```@example usepkg
status(m2)
```

!!! note
    In our example we replaced a hard-dependency model, but the same principle applies to soft-dependency models.

And that's it! We can switch between models without changing the code, and without having to recompute the dependency graph manually. This is a very powerful feature of PlantSimEngine!💪
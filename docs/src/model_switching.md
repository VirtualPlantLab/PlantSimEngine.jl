# Model switching

```@setup usepkg
using PlantSimEngine, PlantMeteo, CSV, DataFrames
include(joinpath(pkgdir(PlantSimEngine), "examples/ToyLAIModel.jl"))
include(joinpath(pkgdir(PlantSimEngine), "examples/Beer.jl"))
include(joinpath(pkgdir(PlantSimEngine), "examples/ToyAssimGrowthModel.jl"))
include(joinpath(pkgdir(PlantSimEngine), "examples/ToyRUEGrowthModel.jl"))

meteo_day = CSV.read(joinpath(pkgdir(PlantSimEngine), "examples/meteo_day.csv"), DataFrame, header=18)
 
models = ModelList(
    ToyLAIModel(),
    Beer(0.5),
    ToyRUEGrowthModel(0.2),
    status=(TT_cu=cumsum(meteo_day.TT),),
)
run!(models, meteo_day)
models2 = ModelList(
    ToyLAIModel(),
    Beer(0.5),
    ToyAssimGrowthModel(),
    status=(TT_cu=cumsum(meteo_day.TT),),
)
run!(models2, meteo_day)
```

One of the main objective of PlantSimEngine is allowing users to switch between model implementations for a given process **without making any change to the code**. 

The package was carefully designed around this idea to make it easy and computationally efficient. This is done by using the `ModelList`, which is used to list models, and the `run!` function to run the simulation following the dependency graph and leveraging Julia's multiple dispatch to run the models.

## ModelList

The `ModelList` is a container that holds a list of models, their parameter values, and the status of the variables associated to them.

Model coupling is done by adding models to the `ModelList`. Let's create a `ModelList` with several models from the example scripts in the [`examples`](https://github.com/VirtualPlantLab/PlantSimEngine.jl/blob/master/examples/) folder:

Importing the models from the scripts:

```julia
using PlantSimEngine
include(joinpath(pkgdir(PlantSimEngine), "examples/ToyLAIModel.jl"))
include(joinpath(pkgdir(PlantSimEngine), "examples/Beer.jl"))
include(joinpath(pkgdir(PlantSimEngine), "examples/ToyAssimGrowthModel.jl"))
include(joinpath(pkgdir(PlantSimEngine), "examples/ToyRUEGrowthModel.jl"))
```

Coupling the models in a `ModelList`:

```@example usepkg
models = ModelList(
    ToyLAIModel(),
    Beer(0.5),
    ToyRUEGrowthModel(0.2),
    status=(TT_cu=cumsum(meteo_day.TT),),
)

nothing # hide
```

PlantSimEngine uses the `ModelList` to compute the dependency graph of the models. Here we have seven models, one for each process. The dependency graph is computed automatically by PlantSimEngine, and is used to run the simulation in the correct order.

We can run the simulation by calling the `run!` function with a meteorology. Here we use an example meteorology:

```@example usepkg
meteo_day = CSV.read(joinpath(pkgdir(PlantSimEngine), "examples/meteo_day.csv"), DataFrame, header=18)
nothing # hide
```

!!! tip
    To reproduce this meteorology, you can check the code presented [in this section in the FAQ](@ref defining_the_meteo)

We can now run the simulation:

```@example usepkg
run!(models, meteo_day)
```

!!! note
    You'll notice a warning returned by `run!` here. If you read its content, you'll see it says that `ToyRUEGrowthModel` does not allow for parallel computations over time-steps. This is because it uses values from the previous time-steps in its computations. By default, `run!` makes the simulations in parallel, so to avoid the warning, you must explicitly tell it to use a sequential execution instead. To do so, you can use the `executor=SequentialEx()` keyword argument.

And then we can access the status of the `ModelList` using the [`status`](@ref) function:

```@example usepkg
status(models)
```

Now what if we want to switch the model that computes growth ? We can do this by simply replacing the model in the `ModelList`, and PlantSimEngine will automatically update the dependency graph, and adapt the simulation to the new model.

Let's switch `ToyRUEGrowthModel` by `ToyAssimGrowthModel`:

```@example usepkg
models2 = ModelList(
    ToyLAIModel(),
    Beer(0.5),
    ToyAssimGrowthModel(), # This was `ToyRUEGrowthModel(0.2)` before
    status=(TT_cu=cumsum(meteo_day.TT),),
)

nothing # hide
```

`ToyAssimGrowthModel` is a little bit more complex than `ToyRUEGrowthModel`, as it also computes the maintenance and growth respiration of the plant, so it has more parameters (we use the default values here).

We can run a new simulation:

```@example usepkg
run!(models2, meteo_day)
```

And we can see that the status of the variables is different from the previous simulation:

```@example usepkg
status(models2)
```

!!! note
    In our example we replaced a soft-dependency model, but the same principle applies to hard-dependency models.

And that's it! We can switch between models without changing the code, and without having to recompute the dependency graph manually. This is a very powerful feature of PlantSimEngine!💪

!!! note
    This was a very standard but easy example. Sometimes other models will require to add other models to the `ModelList`. For example `ToyAssimGrowthModel` could have required a maintenance respiration model. In this case `PlantSimEngine` will tell you that this kind of model is required for the simulation.
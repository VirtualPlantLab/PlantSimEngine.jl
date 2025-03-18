# Model switching

```@setup usepkg
using PlantSimEngine, PlantMeteo, CSV, DataFrames
# Import the examples defined in the `Examples` sub-module
using PlantSimEngine.Examples

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

One of the main objective of PlantSimEngine is allowing users to switch between model implementations for a given process **without making any change to the PlantSimEngine codebase**.

The package was designed around this idea to make easy changes easy and efficient. Switch models in the [`ModelList`](@ref), and call the [`run!`](@ref) function again. No other changes are required if no new variables are introduced.

## A first simulation as a starting point

Let's create a [`ModelList`](@ref) with several models from the example scripts in the [`examples`](https://github.com/VirtualPlantLab/PlantSimEngine.jl/blob/master/examples/) folder:

Importing the models from the scripts:

```julia
using PlantSimEngine
# Import the examples defined in the `Examples` sub-module:
using PlantSimEngine.Examples
```

Coupling the models in a [`ModelList`](@ref):

```@example usepkg
models = ModelList(
    ToyLAIModel(),
    Beer(0.5),
    ToyRUEGrowthModel(0.2),
    status=(TT_cu=cumsum(meteo_day.TT),),
)

nothing # hide
```

We can the simulation by calling the [`run!`](@ref) function with meteorology data. Here we use an example data set:

```@example usepkg
meteo_day = CSV.read(joinpath(pkgdir(PlantSimEngine), "examples/meteo_day.csv"), DataFrame, header=18)
nothing # hide
```

We can now run the simulation:

```@example usepkg
output_initial = run!(models, meteo_day)
```

## Switching one model in the simulation

Now what if we want to switch the model that computes growth ? We can do this by simply replacing the model in the [`ModelList`](@ref), and PlantSimEngine will automatically update the dependency graph, and adapt the simulation to the new model.

Let's switch ToyRUEGrowthModel with ToyAssimGrowthModel:

```@example usepkg
models2 = ModelList(
    ToyLAIModel(),
    Beer(0.5),
    ToyAssimGrowthModel(), # This was `ToyRUEGrowthModel(0.2)` before
    status=(TT_cu=cumsum(meteo_day.TT),),
)

nothing # hide
```

ToyAssimGrowthModel is a little bit more complex than `ToyRUEGrowthModel`](@ref), as it also computes the maintenance and growth respiration of the plant, so it has more parameters (we use the default values here). 

We can run a new simulation and see that the simulation's results are different from the previous simulation:

```@example usepkg
output_updated = run!(models2, meteo_day)
```

And that's it! We can switch between models without changing the code, and without having to recompute the dependency graph manually. This is a very powerful feature of PlantSimEngine!💪

!!! note
    This was a very standard but straightforward example. Sometimes other models will require to add other models to the [`ModelList`](@ref). For example ToyAssimGrowthModel could have required a maintenance respiration model. In this case `PlantSimEngine` will indicate what kind of model is required for the simulation.

!!! note
    In our example we replaced what we call a [soft-dependency coupling](@ref hard_dependency_def), but the same principle applies to [hard-dependencies](@ref hard_dependency_def). Hard and Soft dependencies are concepts related to model coupling, and are discussed in more detail in [Standard model coupling](@ref) and [Coupling more complex models](@ref).


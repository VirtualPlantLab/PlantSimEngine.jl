
# Model switching {#Model-switching}

One of the main objective of PlantSimEngine is allowing users to switch between model implementations for a given process **without making any change to the code**. 

The package was carefully designed around this idea to make it easy and computationally efficient. This is done by using the `ModelList`, which is used to list models, and the `run!` function to run the simulation following the dependency graph and leveraging Julia&#39;s multiple dispatch to run the models.

## ModelList {#ModelList}

The `ModelList` is a container that holds a list of models, their parameter values, and the status of the variables associated to them.

Model coupling is done by adding models to the `ModelList`. Let&#39;s create a `ModelList` with several models from the example scripts in the [`examples`](https://github.com/VirtualPlantLab/PlantSimEngine.jl/blob/master/examples/) folder:

Importing the models from the scripts:

```julia
using PlantSimEngine
# Import the examples defined in the `Examples` sub-module:
using PlantSimEngine.Examples
```


Coupling the models in a `ModelList`:

```julia
models = ModelList(
    ToyLAIModel(),
    Beer(0.5),
    ToyRUEGrowthModel(0.2),
    status=(TT_cu=cumsum(meteo_day.TT),),
)
```


PlantSimEngine uses the `ModelList` to compute the dependency graph of the models. Here we have seven models, one for each process. The dependency graph is computed automatically by PlantSimEngine, and is used to run the simulation in the correct order.

We can run the simulation by calling the `run!` function with a meteorology. Here we use an example meteorology:

```julia
meteo_day = CSV.read(joinpath(pkgdir(PlantSimEngine), "examples/meteo_day.csv"), DataFrame, header=18)
```


::: tip Tip

To reproduce this meteorology, you can check the code presented [in this section in the FAQ](/FAQ/translate_a_model#defining_the_meteo)

:::

We can now run the simulation:

```julia
run!(models, meteo_day)
```


```
┌ Warning: A parallel executor was provided (`executor=ThreadedEx()`) but some models cannot be run in parallel: PlantSimEngine.Examples.ToyRUEGrowthModel{Float64}(0.2). The simulation will be run sequentially. Use `executor=SequentialEx()` to remove this warning.
└ @ PlantSimEngine ~/work/PlantSimEngine.jl/PlantSimEngine.jl/src/run.jl:242
```


::: tip Note

You&#39;ll notice a warning returned by `run!` here. If you read its content, you&#39;ll see it says that `ToyRUEGrowthModel` does not allow for parallel computations over time-steps. This is because it uses values from the previous time-steps in its computations. By default, `run!` makes the simulations in parallel, so to avoid the warning, you must explicitly tell it to use a sequential execution instead. To do so, you can use the `executor=SequentialEx()` keyword argument.

:::

And then we can access the status of the `ModelList` using the [`status`](/API#PlantSimEngine.status-Tuple{Any}) function:

```julia
status(models)
```


```
TimeStepTable{Status{(:TT_cu, :LAI, :aPPFD,...}(365 x 5):
╭─────┬──────────┬────────────┬───────────┬────────────┬───────────────────╮
│ Row │    TT_cu │        LAI │     aPPFD │    biomass │ biomass_increment │
│     │  Float64 │    Float64 │   Float64 │    Float64 │           Float64 │
├─────┼──────────┼────────────┼───────────┼────────────┼───────────────────┤
│   1 │      0.0 │ 0.00554988 │ 0.0396961 │ 0.00793922 │        0.00793922 │
│   2 │      0.0 │ 0.00554988 │   0.02173 │  0.0122852 │          0.004346 │
│   3 │      0.0 │ 0.00554988 │ 0.0314899 │  0.0185832 │        0.00629798 │
│   4 │      0.0 │ 0.00554988 │ 0.0390834 │  0.0263999 │        0.00781668 │
│   5 │      0.0 │ 0.00554988 │ 0.0454514 │  0.0354902 │        0.00909028 │
│   6 │      0.0 │ 0.00554988 │ 0.0472677 │  0.0449437 │        0.00945354 │
│   7 │      0.0 │ 0.00554988 │   0.04346 │  0.0536357 │        0.00869201 │
│   8 │      0.0 │ 0.00554988 │ 0.0469832 │  0.0630324 │        0.00939665 │
│   9 │      0.0 │ 0.00554988 │ 0.0291703 │  0.0688664 │        0.00583406 │
│  10 │      0.0 │ 0.00554988 │ 0.0140052 │  0.0716675 │        0.00280105 │
│  11 │      0.0 │ 0.00554988 │ 0.0505283 │  0.0817731 │         0.0101057 │
│  12 │      0.0 │ 0.00554988 │ 0.0405277 │  0.0898787 │        0.00810554 │
│  13 │   0.5625 │ 0.00557831 │ 0.0297814 │   0.095835 │        0.00595629 │
│  14 │ 0.945833 │ 0.00559777 │ 0.0433269 │     0.1045 │        0.00866538 │
│  15 │ 0.979167 │ 0.00559946 │ 0.0470271 │   0.113906 │        0.00940542 │
│  ⋮  │    ⋮     │     ⋮      │     ⋮     │     ⋮      │         ⋮         │
╰─────┴──────────┴────────────┴───────────┴────────────┴───────────────────╯
                                                            350 rows omitted

```


Now what if we want to switch the model that computes growth ? We can do this by simply replacing the model in the `ModelList`, and PlantSimEngine will automatically update the dependency graph, and adapt the simulation to the new model.

Let&#39;s switch `ToyRUEGrowthModel` by `ToyAssimGrowthModel`:

```julia
models2 = ModelList(
    ToyLAIModel(),
    Beer(0.5),
    ToyAssimGrowthModel(), # This was `ToyRUEGrowthModel(0.2)` before
    status=(TT_cu=cumsum(meteo_day.TT),),
)
```


`ToyAssimGrowthModel` is a little bit more complex than `ToyRUEGrowthModel`, as it also computes the maintenance and growth respiration of the plant, so it has more parameters (we use the default values here).

We can run a new simulation:

```julia
run!(models2, meteo_day)
```


```
┌ Warning: A parallel executor was provided (`executor=ThreadedEx()`) but some models cannot be run in parallel: PlantSimEngine.Examples.ToyAssimGrowthModel{Float64}(0.2, 0.5, 1.2). The simulation will be run sequentially. Use `executor=SequentialEx()` to remove this warning.
└ @ PlantSimEngine ~/work/PlantSimEngine.jl/PlantSimEngine.jl/src/run.jl:242
```


And we can see that the status of the variables is different from the previous simulation:

```julia
status(models2)
```


```
TimeStepTable{Status{(:TT_cu, :LAI, :aPPFD,...}(365 x 8):
╭─────┬──────────┬────────────┬───────────┬─────────────────────┬────────────┬──
│ Row │    TT_cu │        LAI │     aPPFD │ carbon_assimilation │         Rm │ ⋯
│     │  Float64 │    Float64 │   Float64 │             Float64 │    Float64 │ ⋯
├─────┼──────────┼────────────┼───────────┼─────────────────────┼────────────┼──
│   1 │      0.0 │ 0.00554988 │ 0.0396961 │          0.00793922 │ 0.00396961 │ ⋯
│   2 │      0.0 │ 0.00554988 │   0.02173 │            0.004346 │   0.002173 │ ⋯
│   3 │      0.0 │ 0.00554988 │ 0.0314899 │          0.00629798 │ 0.00314899 │ ⋯
│   4 │      0.0 │ 0.00554988 │ 0.0390834 │          0.00781668 │ 0.00390834 │ ⋯
│   5 │      0.0 │ 0.00554988 │ 0.0454514 │          0.00909028 │ 0.00454514 │ ⋯
│   6 │      0.0 │ 0.00554988 │ 0.0472677 │          0.00945354 │ 0.00472677 │ ⋯
│   7 │      0.0 │ 0.00554988 │   0.04346 │          0.00869201 │   0.004346 │ ⋯
│   8 │      0.0 │ 0.00554988 │ 0.0469832 │          0.00939665 │ 0.00469832 │ ⋯
│   9 │      0.0 │ 0.00554988 │ 0.0291703 │          0.00583406 │ 0.00291703 │ ⋯
│  10 │      0.0 │ 0.00554988 │ 0.0140052 │          0.00280105 │ 0.00140052 │ ⋯
│  11 │      0.0 │ 0.00554988 │ 0.0505283 │           0.0101057 │ 0.00505283 │ ⋯
│  12 │      0.0 │ 0.00554988 │ 0.0405277 │          0.00810554 │ 0.00405277 │ ⋯
│  13 │   0.5625 │ 0.00557831 │ 0.0297814 │          0.00595629 │ 0.00297814 │ ⋯
│  14 │ 0.945833 │ 0.00559777 │ 0.0433269 │          0.00866538 │ 0.00433269 │ ⋯
│  15 │ 0.979167 │ 0.00559946 │ 0.0470271 │          0.00940542 │ 0.00470271 │ ⋯
│  ⋮  │    ⋮     │     ⋮      │     ⋮     │          ⋮          │     ⋮      │ ⋱
╰─────┴──────────┴────────────┴───────────┴─────────────────────┴────────────┴──
                                                  3 columns and 350 rows omitted

```


::: tip Note

In our example we replaced a soft-dependency model, but the same principle applies to hard-dependency models.

:::

And that&#39;s it! We can switch between models without changing the code, and without having to recompute the dependency graph manually. This is a very powerful feature of PlantSimEngine!💪

::: tip Note

This was a very standard but easy example. Sometimes other models will require to add other models to the `ModelList`. For example `ToyAssimGrowthModel` could have required a maintenance respiration model. In this case `PlantSimEngine` will tell you that this kind of model is required for the simulation.

:::

# Quick examples

This page is meant for people who have set up their environment and just want to copy-paste an example or two, see what the REPL returns and start tinkering. 

If you are less comfortable with Julia, or need to set up an environment first, see this page : [Getting started with Julia](@ref).
If you wish for a more detailed rundown of the examples, you can instead have a look at the [step by step][#step_by_step] section, which will go into more detail.

These examples are all for single-scale simulations. For multi-scale modelling tutorials and examples, refer to [this section][#multiscale]

You can find the implementation for all the example models, as well as other toy models [in the examples folder](https://github.com/VirtualPlantLab/PlantSimEngine.jl/tree/main/examples).

## Example with a single light interception model and a single weather timestep

```julia
using PlantSimEngine, PlantMeteo
using PlantSimEngine.Examples
meteo = Atmosphere(T = 20.0, Wind = 1.0, Rh = 0.65, Ri_PAR_f = 500.0)
leaf = ModelList(Beer(0.5), status = (LAI = 2.0,))
out = run!(leaf, meteo)
```

## Coupling the light interception model with a Leaf Area Index model

The weather data in this example contains data over 365 days, meaning the simulation will have as many timesteps.

```julia
using PlantSimEngine
using PlantMeteo, CSV

using PlantSimEngine.Examples

meteo_day = CSV.read(joinpath(pkgdir(PlantSimEngine), "examples/meteo_day.csv"), DataFrame, header=18)

models = ModelList(
    ToyLAIModel(),
    Beer(0.5),
    status=(TT_cu=cumsum(meteo_day.TT),),
)

outputs_coupled = run!(models, meteo_day)
```

## Coupling the light interception and Leaf Area Index models with a biomass increment model


```julia
using PlantSimEngine
using PlantMeteo, CSV

using PlantSimEngine.Examples

meteo_day = CSV.read(joinpath(pkgdir(PlantSimEngine), "examples/meteo_day.csv"), DataFrame, header=18)

models = ModelList(
    ToyLAIModel(),
    Beer(0.5),
    ToyRUEGrowthModel(0.2),
    status=(TT_cu=cumsum(meteo_day.TT),),
)

outputs_coupled = run!(models, meteo_day)
```

## Example using PlantBioPhysics

A companion package, PlantBioPhysics, uses PlantSimEngine, and contains other models used in ecophysiological simulations.

You can have a look at its documentation [here](https://vezy.github.io/PlantBiophysics.jl/stable/)

Several example simulations are provided there. Here's one taken from [this page](https://vezy.github.io/PlantBiophysics.jl/stable/simulation/first_simulation/) : 

```julia
using PlantBiophysics, PlantSimEngine

meteo = Atmosphere(T = 22.0, Wind = 0.8333, P = 101.325, Rh = 0.4490995)

leaf = ModelList(
        Monteith(),
        Fvcb(),
        Medlyn(0.03, 12.0),
        status = (Ra_SW_f = 13.747, sky_fraction = 1.0, aPPFD = 1500.0, d = 0.03)
    )

out = run!(leaf,meteo)
```
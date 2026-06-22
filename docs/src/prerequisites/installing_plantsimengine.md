# Installing PlantSimEngine

Install Julia from the
[official download page](https://julialang.org/downloads/), create a project
environment, and add PlantSimEngine:

```julia
using Pkg
Pkg.activate("my_simulation")
Pkg.add("PlantSimEngine")
```

Most simulations also use PlantMeteo:

```julia
Pkg.add("PlantMeteo")
```

## First Simulation

```@example install
using PlantSimEngine, PlantMeteo, Dates
using PlantSimEngine.Examples

meteo = Atmosphere(
    T=20.0,
    Wind=1.0,
    Rh=0.65,
    Ri_PAR_f=500.0,
    duration=Hour(1),
)

model = CompositeModel(
    Beer(0.5);
    status=(LAI=2.0,),
    id=:leaf,
    scale=:Leaf,
    environment=meteo,
)

run!(model)
only(model_objects(model; scale=:Leaf)).status.aPPFD
```

Example models are provided by the `PlantSimEngine.Examples` submodule. They
are useful for learning and tests but are not part of the core modeling API.

For local package development, use `Pkg.develop(path="...")`. Run the package
tests with `Pkg.test("PlantSimEngine")`.

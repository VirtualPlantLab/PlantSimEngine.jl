# Installing PlantSimEngine

!!! compat "Use the package version described by this manual"
    These development pages use the `CompositeModel` API introduced in v0.15.0.

Install Julia from the
[official download page](https://julialang.org/downloads/), create a project
environment (a folder that records the packages used for this simulation), open julia from this repository, and install the tutorial packages:

```julia
using Pkg
Pkg.activate(".")
Pkg.add(["PlantMeteo", "DataFrames", "CairoMakie", "PlantSimEngine.jl"])
```

PlantMeteo supplies weather data, DataFrames organizes the results, and
CairoMakie draws the tutorial figures. Run these commands at Julia's
interactive prompt, also called the **REPL**;
`my_simulation` is the project directory created relative to your current
working directory. In a later session, run `Pkg.activate(".")`
from the same location before using the project again.

Julia makes reproducibility seemless: whenever you add a new package, it records the package versions you're using in two files called `Project.toml` and `Manifest.toml`.

## First Simulation

This small example calculates how much light a canopy absorbs. Its leaf area
index is 2 m² of leaves per m² of ground, and incoming photosynthetically
active radiation (PAR) is 500 W m⁻² of ground. The canopy is one simulated
object; individual leaves are not represented.

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
    id=:canopy,
    scale=:Canopy,
    environment=meteo,
)

simulation = run!(model)
(absorbed_PAR_umol_m2_ground_s=final_state(simulation).aPPFD,)
```

`using PlantSimEngine.Examples` loads the example models, including `Beer`.
These models are included for learning and testing.

The result is the amount of light absorbed by the canopy, expressed in μmol
of photons per m² of ground per second. The inputs are
illustrative, not a calibrated crop scenario. Next,
[couple three models over time](../journeys/users/one_object.md), then
[collect and plot their outputs](../guides/data/outputs_plotting.md).
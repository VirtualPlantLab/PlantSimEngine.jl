# Installing PlantSimEngine

!!! compat "Use the package version described by this manual"
    These development pages use the `CompositeModel` API. Registered releases
    through 0.14.1 use the previous mapping API. Follow the commands below to
    use the development version, or use the documentation matching your
    installed release. For a pull-request preview, replace `"main"` with the
    branch or commit shown by that pull request so its examples and package
    sources match.

Install Julia from the
[official download page](https://julialang.org/downloads/), create a project
environment, and install the packages used in the tutorials:

```julia
using Pkg
Pkg.activate("my_simulation")
Pkg.add(["PlantMeteo", "DataFrames", "CairoMakie"])
Pkg.add(url="https://github.com/VirtualPlantLab/PlantSimEngine.jl", rev="main")
```

PlantMeteo supplies weather data, DataFrames organizes the results, and
CairoMakie draws the tutorial figures. Run these commands in the Julia REPL;
`my_simulation` is the project directory created relative to your current
working directory. In a later session, run `Pkg.activate("my_simulation")`
from the same location before using the project again.

For reproducible work, record the package revision and keep the generated
`Project.toml` and `Manifest.toml` with your experiment. The development branch
can change; a commit revision selects one exact version.

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

Example models are provided by the `PlantSimEngine.Examples` submodule. They
are useful for learning and tests but are not part of the core modeling API.

The result is absorbed photon flux in μmol m⁻² of ground s⁻¹. The inputs are
illustrative, not a calibrated crop scenario. Next,
[couple three models over time](../journeys/users/one_object.md), then
[collect and plot their outputs](../guides/data/outputs_plotting.md).

For local package development, use `Pkg.develop(path="...")`. Run the package
tests with `Pkg.test("PlantSimEngine")`.

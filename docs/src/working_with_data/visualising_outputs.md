```@setup usepkg
# ] add PlantSimEngine, DataFrames, CSV
using PlantSimEngine, PlantMeteo, DataFrames, CSV

# Include the model definition from the examples folder:
using PlantSimEngine.Examples

# Import the example meteorological data:
meteo_day = CSV.read(joinpath(pkgdir(PlantSimEngine), "examples/meteo_day.csv"), DataFrame, header=18)

# Define the list of models for coupling:
model = ModelList(
    ToyLAIModel(),
    Beer(0.6),
    status=(TT_cu=cumsum(meteo_day[:, :TT]),),  # Pass the cumulated degree-days as input to `ToyLAIModel`, this could also be done using another model
)

# Run the simulation:
sim_outputs = run!(model, meteo_day)

```

# Visualizing outputs
TODO example environment ?

## Output structure

PlantSimEngine's run! functions return for each timestep the state of the variables that were requested using the `tracked_outputs` kwarg (or the state of every variable if this kwarg was left unspecified). Multi-scale simulations also indicate which organ and MTG node these state variables are related to.

Here's an example indicating how to plot output data using CairoMakie, a package used for plotting.

```julia
# ] add PlantSimEngine, DataFrames, CSV
using PlantSimEngine, PlantMeteo, DataFrames, CSV

# Include the model definition from the examples folder:
using PlantSimEngine.Examples

# Import the example meteorological data:
meteo_day = CSV.read(joinpath(pkgdir(PlantSimEngine), "examples/meteo_day.csv"), DataFrame, header=18)

# Define the list of models for coupling:
model = ModelList(
    ToyLAIModel(),
    Beer(0.6),
    status=(TT_cu=cumsum(meteo_day[:, :TT]),),  # Pass the cumulated degree-days as input to `ToyLAIModel`, this could also be done using another model
)

# Run the simulation:
sim_outputs = run!(model, meteo_day)

```

The output data is displayed as :

```
TimeStepTable{Status{(:TT_cu, :LAI...}(365 x 3):
╭─────┬────────────────┬────────────┬───────────╮
│ Row │ TT_cu │        LAI │     aPPFD │
│     │        Float64 │    Float64 │   Float64 │
├─────┼────────────────┼────────────┼───────────┤
│   1 │            0.0 │ 0.00554988 │ 0.0476221 │
│   2 │            0.0 │ 0.00554988 │ 0.0260688 │
│   3 │            0.0 │ 0.00554988 │ 0.0377774 │
│   4 │            0.0 │ 0.00554988 │ 0.0468871 │
│   5 │            0.0 │ 0.00554988 │ 0.0545266 │
│  ⋮  │       ⋮        │     ⋮      │     ⋮     │
╰─────┴────────────────┴────────────┴───────────╯
                                 360 rows omitted
```

And using CairoMakie, one can plot out selected variables :

```julia
# Plot the results:
using CairoMakie

fig = Figure(resolution=(800, 600))
ax = Axis(fig[1, 1], ylabel="LAI (m² m⁻²)")
lines!(ax, model[:TT_cu], model[:LAI], color=:mediumseagreen)

ax2 = Axis(fig[2, 1], xlabel="Cumulated growing degree days since sowing (°C)", ylabel="aPPFD (mol m⁻² d⁻¹)")
lines!(ax2, model[:TT_cu], model[:aPPFD], color=:firebrick1)

fig
```

TODO
! LAI Growth and light interception ../examples/LAI_growth2.png

## TimeStepTables and DataFrames

The output data is usually stored in a `TimeStepTable` structure defined in `PlantMeteo.jl`, which is a fast DataFrame-like structure with each time step being a [`Status`](@ref). It can be also be any `Tables.jl` structure, such as a regular `DataFrame`. Weather data is also usually stored in a `TimeStepTable` but with each time step being an `Atmosphere`.

TODO example extracting specific variables

Another simple way to get the results is to transform the outputs into a `DataFrame`. Which is very easy because the `TimeStepTable` implements the Tables.jl interface:

```@example usepkg
using DataFrames
PlantSimEngine.convert_outputs(sim_outputs, DataFrame)
```

TODO other examples ?
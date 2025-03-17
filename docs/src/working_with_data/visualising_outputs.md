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
sim_out = run!(model, meteo_day)

```

# Visualizing outputs and data

## Output structure

PlantSimEngine's run! functions return for each timestep the state of the variables that were requested using the `tracked_outputs` kwarg (or the state of every variable if this kwarg was left unspecified). Multi-scale simulations also indicate which organ and MTG node these state variables are related to.

Here's an example indicating how to plot output data using CairoMakie, a package used for plotting.

```@example usepkg
# ] add PlantSimEngine, DataFrames, CSV
using PlantSimEngine, PlantMeteo, DataFrames, CSV

# Include the model definition from the examples folder:
using PlantSimEngine.Examples

# Import the example meteorological data:
meteo_day = CSV.read(joinpath(pkgdir(PlantSimEngine), "examples/meteo_day.csv"), DataFrame, header=18)

# Define the list of models for coupling:
models = ModelList(
    ToyLAIModel(),
    Beer(0.6),
    status=(TT_cu=cumsum(meteo_day[:, :TT]),),  # Pass the cumulated degree-days as input to `ToyLAIModel`, this could also be done using another model
)

# Run the simulation:
sim_outputs = run!(models, meteo_day)
```

The output data is displayed as a by default as a `TimeStepTable`. It is also possible to filter which variables are kept via the optional `tracked_outputs` keyword argument.

## Plotting outputs

Using CairoMakie, one can plot out selected variables :

!!! note
    You will need to add CairoMakie to your environment through Pkg mode first.

```@example usepkg
# Plot the results:
using CairoMakie

fig = Figure(resolution=(800, 600))
ax = Axis(fig[1, 1], ylabel="LAI (m² m⁻²)")
lines!(ax, sim_outputs[:TT_cu], sim_outputs[:LAI], color=:mediumseagreen)

ax2 = Axis(fig[2, 1], xlabel="Cumulated growing degree days since sowing (°C)", ylabel="aPPFD (mol m⁻² d⁻¹)")
lines!(ax2, sim_outputs[:TT_cu], sim_outputs[:aPPFD], color=:firebrick1)

fig
```

## TimeStepTables and DataFrames

```@setup usepkg
sim_out = run!(model, meteo_day)
```

The output data is usually stored in a `TimeStepTable` structure defined in `PlantMeteo.jl`, which is a fast DataFrame-like structure with each time step being a [`Status`](@ref). It can be also be any `Tables.jl` structure, such as a regular `DataFrame`. Weather data is also usually stored in a `TimeStepTable` but with each time step being an `Atmosphere`.

Another simple way to get the results is to transform the outputs into a `DataFrame`. Which is very easy because the `TimeStepTable` implements the Tables.jl interface:

```@example usepkg
using DataFrames
sim_outputs_df = PlantSimEngine.convert_outputs(sim_outputs, DataFrame)
sim_outputs_df[1, 2, 3, 363, 364, 365]
```

It is also possible to create DataFrames from specific variables:

```julia
df = DataFrame(aPPFD=sim_outputs[:aPPFD][1], LAI=sim_outputs.LAI[1], Ri_PAR_f=meteo.Ri_PAR_f[1])
```

Which can also be useful for [Parameter fitting ](@ref).
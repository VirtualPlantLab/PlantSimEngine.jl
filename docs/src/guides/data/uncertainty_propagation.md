# Propagate Uncertainty Through A Simulation

How much does uncertainty in a weather measurement or a model parameter affect
the simulated result? PlantSimEngine can carry uncertain numbers through the
same model equations, object status, and output streams used for ordinary
numbers. Here we simulate one day of canopy light absorption, then plot the
uncertainty in each hourly result and in the daily total.

We use [MonteCarloMeasurements.jl](https://baggepinnen.github.io/MonteCarloMeasurements.jl/stable/)
and its `±` notation for uncertain numbers. Internally, each number holds many
possible values, called particles, and arithmetic applies to each of them.
Each particle follows one possible simulation. This is an optional package;
install it in your project with `import Pkg; Pkg.add("MonteCarloMeasurements")`.

## Set up an uncertain day

The example [`Beer`](@ref) model calculates absorbed photosynthetically active
radiation (PAR) from incident radiation, the light-extinction coefficient `k`,
and leaf area index (`LAI`). We keep `LAI = 2` fixed and compare three cases:

| Case | Radiation measurement | Model parameter `k` |
|:--|:--|:--|
| Radiation only | 2% relative standard deviation | Fixed at 0.6 |
| Parameter only | Fixed | Mean 0.6, standard deviation 0.06 |
| Both sources | 2% relative standard deviation | Mean 0.6, standard deviation 0.06 |

These are illustrative assumptions, not uncertainty estimates fitted to data.
Here **2% means one standard deviation**, not a guaranteed ±2% bound.
Write an uncertain number as `mean ± standard_deviation`; the package handles
sampling from normal distributions for us. A fixed random seed makes the
figures reproducible.

```@example uncertainty_propagation
using PlantSimEngine, PlantSimEngine.Examples
using MonteCarloMeasurements, Random, Dates, DataFrames, CairoMakie

Random.seed!(42)
radiation_factor = 1.0 ± 0.02
uncertain_k = 0.6 ± 0.06

day_start = DateTime(2026, 6, 21)
interval = Hour(1)
weather = [
    (
        date=day_start + Hour(h),
        duration=interval,
        Ri_PAR_f=400.0 * max(0.0, sinpi((h - 0.5 - 6) / 12)),
    )
    for h in 1:24
]
nothing # hide
```

The factor `1.0 ± 0.02` gives the radiation a 2% relative standard deviation.
To enter `±` in Julia's REPL, type `\pm` and press Tab.

`Ri_PAR_f` is incident PAR in W m⁻² of ground. These synthetic hourly means
describe a clear day with zero radiation at night. Each `date` labels the
**end of the preceding hourly interval**; the 24 records cover a complete day.
Only the variables needed by the model are supplied in this weather table.

We will reuse the same `radiation_factor` at every hour. This represents a
sensor calibration uncertainty shared by the whole day. Likewise, each
particle keeps its own `k` throughout the simulation. The two sources are
sampled independently, and we reuse those samples across the three cases to
make the comparison easier.

!!! note "Choose the relationship between measurements"
    Independent measurement noise would require a fresh sample for each
    weather record. It would give a different uncertainty in the daily total.
    Reusing particles deliberately preserves the relationship between hours;
    a consistently high radiation estimate stays high throughout the day.

## Run the same model with uncertain inputs

The model equations already work with generic numeric types, so we do not
change `Beer`. We do need output storage that can hold particles. With an
ordinary `k`, its default output is a floating-point number; `status_transform`
changes that output to `value ± 0.0`. This prepares storage with zero spread,
without adding another source of uncertainty.

```@example uncertainty_propagation
function particle_status(variable, value)
    if variable === :aPPFD && value isa AbstractFloat
        return value ± 0.0
    end
    return value
end

function simulate_absorption(k, radiation_scale)
    uncertain_weather = [
        merge(row, (Ri_PAR_f=row.Ri_PAR_f * radiation_scale,))
        for row in weather
    ]
    model = CompositeModel(
        Beer(k);
        id=:canopy,
        scale=:Canopy,
        status=(LAI=2.0,),
        environment=uncertain_weather,
        status_transform=particle_status,
    )
    simulation = run!(model; steps=length(weather), outputs=:all)
    return sort!(
        collect_outputs(simulation, :canopy, :aPPFD; sink=DataFrame),
        :timestep,
    )
end

cases = [
    (label="Radiation only", rows=simulate_absorption(0.6, radiation_factor)),
    (label="Parameter only", rows=simulate_absorption(uncertain_k, 1.0)),
    (label="Both sources", rows=simulate_absorption(uncertain_k, radiation_factor)),
]

@assert all(case -> all(value -> value isa Particles, case.rows.value), cases)
nothing # hide
```

`status_transform` acts on object status, not on model parameters or weather.
We constructed their uncertain values explicitly before creating the model.
The saved `value` column still contains particles: uncertainty survives both
the simulation and output collection. Converting these values to ordinary
numbers here would discard the information needed for the envelopes below.

## Plot hourly and accumulated uncertainty

`aPPFD` is absorbed PAR in **µmol photons m⁻² of ground s⁻¹**. To get the
accumulated amount in **mol photons m⁻² of ground**, multiply each hourly mean
by 3,600 seconds, convert µmol to mol, and sum. We perform this calculation
on the particle values before summarizing them. Adding upper and lower bounds
separately would lose information about how values are related over time.

```@example uncertainty_propagation
seconds_per_interval = Dates.value(Second(interval))
hours_per_interval = seconds_per_interval / 3600

function envelope(values)
    (
        mean=pmean.(values),
        lower=[pquantile(value, 0.025) for value in values],
        upper=[pquantile(value, 0.975) for value in values],
    )
end

results = map(cases) do case
    rows = case.rows
    end_hours = Dates.value.(rows.datetime .- day_start) ./ 3_600_000
    cumulative = cumsum(rows.value .* (seconds_per_interval * 1e-6))
    (
        label=case.label,
        midpoint_hours=end_hours .- hours_per_interval / 2,
        end_hours=vcat(0.0, end_hours),
        hourly=envelope(rows.value),
        cumulative=envelope(vcat(zero(first(cumulative)), cumulative)),
        daily_total=last(cumulative),
    )
end

figure = Figure(size=(1080, 650), fontsize=16)
colors = (:steelblue, :darkorange, :seagreen)
hourly_axes = Axis[]
cumulative_axes = Axis[]

for (column, result) in enumerate(results)
    color = colors[column]
    hourly_axis = Axis(figure[1, column];
        title=result.label,
        ylabel=column == 1 ? "Absorbed PAR\n(µmol photons m⁻² s⁻¹)" : "",
        xticks=0:6:24,
    )
    cumulative_axis = Axis(figure[2, column];
        xlabel="Hour since midnight",
        ylabel=column == 1 ? "Accumulated PAR\n(mol photons m⁻²)" : "",
        xticks=0:6:24,
    )
    for (axis, time, bounds) in (
        (hourly_axis, result.midpoint_hours, result.hourly),
        (cumulative_axis, result.end_hours, result.cumulative),
    )
        band!(axis, time, bounds.lower, bounds.upper;
            color=(color, 0.25))
        lines!(axis, time, bounds.mean; color, linewidth=2)
        xlims!(axis, 0, 24)
    end
    hidexdecorations!(hourly_axis; grid=false)
    if column > 1
        hideydecorations!(hourly_axis; grid=false)
        hideydecorations!(cumulative_axis; grid=false)
    end
    push!(hourly_axes, hourly_axis)
    push!(cumulative_axes, cumulative_axis)
end
colgap!(figure.layout, 35)
linkyaxes!(hourly_axes...)
linkyaxes!(cumulative_axes...)
Label(figure[3, 1:3],
    "Lines: mean   ·   Shading: central 95% of simulated values\nAll quantities are per unit ground area",
    fontsize=14)
figure
```

The top row shows hourly absorption at the middle of each interval. The bottom
row shows the accumulated amount at its end, with an initial zero. The time
coordinates come from saved dates and the known interval duration.

Radiation uncertainty gives a narrow envelope that widens in absolute terms
as radiation increases. The parameter uncertainty is larger with our chosen
values. Combining the two produces the widest envelope. At night, absorption
and its uncertainty are zero in this example, but uncertainty in the accumulated
daytime absorption remains.

The shading is the interval between the 2.5th and 97.5th percentiles at each
time. It contains the central 95% of simulated values under the chosen input
assumptions. It is not a confidence interval for the mean, nor a guarantee
that 95% of complete trajectories stay inside the band at every hour.

The corresponding daily totals are:

```@example uncertainty_propagation
DataFrame(
    source=[result.label for result in results],
    mean_mol_m2=[round(pmean(result.daily_total); digits=2) for result in results],
    lower_95_mol_m2=[round(pquantile(result.daily_total, 0.025); digits=2) for result in results],
    upper_95_mol_m2=[round(pquantile(result.daily_total, 0.975); digits=2) for result in results],
)
```

## Distinguish absolute and relative uncertainty

A constant **relative** uncertainty of 2% means the radiation standard deviation
is `0.02 * radiation`: it grows with the signal and is zero when the signal is
zero. A constant **absolute** uncertainty, for example 5 W m⁻², behaves
differently: its relative importance increases as radiation approaches zero.
At exactly zero radiation a relative percentage is undefined.

The following comparison shows these two possible input assumptions. The
simulation above uses only the 2% relative case.

```@example uncertainty_propagation
nominal_radiation = getproperty.(weather, :Ri_PAR_f)
midpoint_hours = first(results).midpoint_hours
absolute_sd = fill(5.0, length(weather))
relative_sd = 0.02 .* nominal_radiation
positive = nominal_radiation .> 0

comparison = Figure(size=(920, 360), fontsize=16)
absolute_axis = Axis(comparison[1, 1];
    title="Absolute uncertainty", xlabel="Hour since midnight",
    ylabel="Radiation standard deviation\n(W m⁻²)", xticks=0:6:24)
relative_axis = Axis(comparison[1, 2];
    title="Relative uncertainty · daylight only", xlabel="Hour since midnight",
    ylabel="Standard deviation / radiation\n(%)", xticks=0:6:24)

for (sd, label, color) in (
    (relative_sd, "2% relative", :steelblue),
    (absolute_sd, "5 W m⁻² absolute", :darkorange),
)
    lines!(absolute_axis, midpoint_hours, sd; color, label, linewidth=2)
    lines!(relative_axis, midpoint_hours[positive],
        100 .* sd[positive] ./ nominal_radiation[positive]; color, linewidth=2)
end
xlims!(absolute_axis, 0, 24)
xlims!(relative_axis, 0, 24)
axislegend(absolute_axis; position=:lt, framevisible=false)
comparison
```

For a real sensor, choose an uncertainty model that matches its calibration
and measurement process. An additive normal error with constant spread can
produce negative radiation near zero, so it is not automatically a suitable
description of physical radiation at night.

## Apply this to another model

The same approach works for uncertain temperatures, initial states, or other
model parameters when the equations and output storage support particle
arithmetic. Keep model parameters and intermediate calculations generic;
avoid forcing uncertain values to `Float64`. A threshold or branch involving
uncertain values needs particular care: decide whether each possible state
should follow its own branch, and check the uncertainty library's support for
that operation.

Choose distributions and correlations from measurements or justified
assumptions, and check that conclusions are stable when you increase the
number of particles. This example propagates only the two declared sources;
it does not include uncertainty in `LAI`, the model equations, or the synthetic
weather profile itself.

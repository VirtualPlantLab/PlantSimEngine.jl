# Give Models Different Cadences

## Run models at different intervals

Canopy development might need an update once a day, while light interception
needs one every hour. A model's **cadence** is how often it runs. This page
shows how an hourly light model uses a daily LAI value, then how to calculate
daily water uptake from hourly rates.

The simulation's **base step** is its smallest time interval. Each model's
cadence must be a whole number of base steps: hourly and 90-minute models can
share a 30-minute base step. PlantSimEngine rejects `every=Minute(90)` with
an hourly base step. You can use fixed durations, including fractions of a
second. Calendar months and timesteps that change during a run are not
supported as model cadences.

## Hold a daily state for an hourly model

Reuse the models that calculate thermal time, LAI, and absorbed light. The
weather advances hourly. Thermal time and LAI update daily, while light is
calculated every hour. `HoldLast` tells the light model to keep using the most
recent LAI value until a new one is calculated.

```@example journey_cadences
using PlantSimEngine, Dates, DataFrames
using PlantSimEngine.Examples

hourly_forcing = [
    (T=20.0, Ri_PAR_f=300.0, duration=Hour(1))
    for _ in 1:25
]

model = CompositeModel(
    Object(:canopy; scale=:Canopy, kind=:canopy, status=Status(TT_cu=600.0));
    applications=(
        ModelSpec(
            ToyDegreeDaysCumulModel();
            name=:degree_days,
            on=One(scale=:Canopy),
            every=Day(1),
        ),
        ModelSpec(
            ToyLAIModel();
            name=:lai,
            on=One(scale=:Canopy),
            every=Day(1),
        ),
        ModelSpec(
            Beer(0.6);
            name=:light,
            on=One(scale=:Canopy),
            inputs=(
                :LAI => One(
                    within=Self(),
                    application=:lai,
                    var=:LAI,
                    policy=HoldLast(),
                    window=Day(1),
                ),
            ),
            every=Hour(1),
        ),
    ),
    environment=hourly_forcing,
)

simulation = run!(model; steps=25, outputs=:all)
```

First inspect the outputs at the beginning of the run and around the daily
update. LAI is in m² of leaves per m² of ground; absorbed PAR is in μmol m⁻²
of ground s⁻¹. The initial 600 °C d is an illustrative development stage,
chosen so the LAI changes are visible.

```@example journey_cadences
rows = collect_outputs(simulation; sink=DataFrame)
light_samples = rows[(rows.variable .== :aPPFD) .& in.(rows.timestep, Ref((1, 2, 24, 25))),
                     [:timestep, :value]]
light_samples
```

The daily models run at steps 1 and 25. They start at the beginning of the
simulation, so the first update does not wait for a whole day of weather.
The hourly light model uses the first LAI value until the next daily update.
If your equation needs a full preceding day, decide what it should do at the
start, before that history is available.

Check how often each model runs, in seconds (`dt_seconds`) and in base steps
(`dt_steps`):

```@example journey_cadences
select(
    DataFrame(Diagnostics.explain_schedule(model)),
    :application_id,
    :dt_seconds,
    :dt_steps,
)
```

You can also check which rule each input uses to read earlier values. The LAI
input uses `HoldLast` because we chose it in `inputs` above. Sharing a canopy
object does not choose that rule for us:

```@example journey_cadences
select(
    DataFrame(Diagnostics.explain_bindings(model)),
    :application_id,
    :input,
    :policy,
    :window,
    :carrier_kind,
)
```

There are two results for each daily model, at steps 1 and 25. The hourly
model has a result at every step. The `nsamples` column counts them:

```@example journey_cadences
select(
    DataFrame(Diagnostics.explain_outputs(simulation)),
    :application_id,
    :variable,
    :nsamples,
)
```

`HoldLast` fits this example because LAI describes the canopy at a given time.
The daily development model assumes that LAI stays unchanged between updates.

## Integrate a rate into an amount

To turn a water-uptake rate into an amount, multiply each rate by the time it
represents, then add the amounts. `Integrate(reducer)` lets you supply that
calculation as a function, called a **reducer**. Be careful: `Integrate()`
without this function only adds the values; it does not multiply by time.

The function below uses durations in seconds. For a rate in mg per second,
24 hourly values give a daily amount in mg. The plant then adds the amounts
from its two leaves. The constant rates are teaching values, not predictions
of water demand.

Load the [teaching models](../../guides/time/teaching_models.jl). One copies a
leaf's supplied water-uptake rate; the other sums amounts from leaves. Their
source is shown in [Hourly, Daily, And Weekly Models](../../guides/time/hourly_daily_weekly.md).

```@example journey_cadences
include(joinpath(pkgdir(PlantSimEngine), "docs", "src", "guides", "time", "teaching_models.jl"))
using .TeachingTimeModels
```

```@example journey_cadences
flux_model = CompositeModel(
    Object(:plant; scale=:Plant),
    Object(
        :leaf_1;
        scale=:Leaf,
        parent=:plant,
        status=Status(rate_mg_s=1.0),
    ),
    Object(
        :leaf_2;
        scale=:Leaf,
        parent=:plant,
        status=Status(rate_mg_s=2.0),
    );
    applications=(
        ModelSpec(
            HourlyWaterRate();
            name=:hourly_flux,
            on=Many(scale=:Leaf),
            every=Hour(1),
        ),
        ModelSpec(
            SumWaterAmounts();
            name=:daily_amount,
            on=One(scale=:Plant),
            inputs=(
                :amounts_mg => Many(
                    scale=:Leaf,
                    within=Subtree(),
                    application=:hourly_flux,
                    var=:water_rate_mg_s,
                    policy=Integrate((values, durations_seconds) -> sum(values .* durations_seconds)),
                    window=Day(1),
                ),
            ),
            every=Day(1),
        ),
    ),
    environment=[(duration=Hour(1),) for _ in 1:25],
)

flux_simulation = run!(flux_model; steps=25, outputs=:all)
amount = final_state(flux_simulation, One(scale=:Plant)).water_amount_mg
@assert amount == 259200.0
amount
```

The complete-day result is `(1 + 2) × 24 × 3600 = 259200 mg` of water.
The first execution has only one hour of available history, so it produces
10800 mg; step 25 has a complete 24-hour rolling window:

```@example journey_cadences
water_rows = collect_outputs(flux_simulation; sink=DataFrame)
daily_rows = water_rows[water_rows.application_id .== :daily_amount, [:timestep, :value]]
@assert daily_rows.value == [10800.0, 259200.0]
daily_rows
```

Each window looks back over a fixed duration; it does not automatically start
at midnight. The
[weekly example](../../guides/time/hourly_daily_weekly.md) extends this same
calculation to seven days and checks the first result separately. Use
`Aggregate(reducer)` to calculate a mean, minimum, maximum, or another
statistic from the values in a window.

!!! note "When models declare units and physical meaning"

    A `VariableContract` describes a variable's units and physical meaning.
    The teaching models above do not declare these contracts. If your models
    do declare them, the two sides of a connection must match. `Integrate()`
    changes the values but does not change their declared contract, so it
    cannot directly connect a rate contract to an amount contract.

    Instead, write a small conversion model. Its input declares the rate
    contract, and its output declares the amount contract expected by the
    next model. If the rate changes, calculate each amount when the rate
    updates, or use a rate correctly averaged over the interval. Multiplying
    one held value by a long duration is only correct when the rate stays
    constant over that interval. See [Coupling models](@ref).

Neither example needs `PreviousTimeStep`: no two models wait for each other's
result in the same step. Use that option only when an equation should read
the preceding step. See [Diagnosing Dependency Cycles](@ref) for an example.

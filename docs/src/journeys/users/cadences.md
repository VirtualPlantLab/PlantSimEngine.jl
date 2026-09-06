# Give Models Different Cadences

## New concept: application clocks and temporal input policies

Let canopy development update daily while light interception responds every
hour. Then convert hourly water-uptake rates to daily amounts. These teaching
examples show how to choose what a slower or faster model receives from its
source.

Choose a base step that divides every application cadence: hourly and
90-minute applications can share a 30-minute base step. A duration such as
`every=Minute(90)` on an hourly base step is rejected. Fixed durations include
subsecond periods; calendar months and adaptive timesteps are not application
cadences.

## Hold a daily state for an hourly model

Reuse the thermal-time, LAI, and light chain. The environment advances hourly;
thermal time and LAI run daily; light interception runs hourly. `HoldLast`
makes each hourly light execution read the latest published daily LAI.

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

The daily models execute at steps 1 and 25, rather than waiting until the end
of the first day. The first LAI value is held for hourly light calculations
until the next daily update. A model that needs a complete preceding day
must handle its initial history explicitly.

The schedule reports physical cadence in seconds and in base steps:

```@example journey_cadences
select(
    DataFrame(Diagnostics.explain_schedule(model)),
    :application_id,
    :dt_seconds,
    :dt_steps,
)
```

The temporal binding is explicit even though the producer and consumer share
an object:

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

The daily applications publish at steps 1 and 25; the hourly application
publishes on all 25 steps:

```@example journey_cadences
select(
    DataFrame(Diagnostics.explain_outputs(simulation)),
    :application_id,
    :variable,
    :nsamples,
)
```

`HoldLast` is appropriate because LAI is a state: between daily updates, its
latest value remains meaningful.

## Integrate a rate into an amount

`Integrate(reducer)` can integrate rates using sample durations. The default
`Integrate()` only sums values; it does not multiply by elapsed time. The
explicit reducer below uses durations in seconds. If a leaf publishes a constant
water-uptake rate in mg per second, integrating 24 hourly samples produces a
daily amount in mg. The plant adds the amounts from two leaves. The constant
rates are teaching values, not predictions of water demand.

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

These windows use fixed durations, not calendar-aligned civil days. The
[weekly example](../../guides/time/hourly_daily_weekly.md) extends this same
calculation to seven days and checks its initial history. Use
`Aggregate(reducer)` instead when the desired quantity is a mean, minimum,
maximum, or another reduction of observations rather than a time integral.

!!! note "Temporal policies and scientific contracts"

    This numerical example leaves variable contracts undeclared. In this
    release, temporal policies do not transform `VariableContract` metadata:
    connected ports must still declare identical contracts. A rate contract
    and a total contract therefore cannot be connected directly through
    `Integrate()`.

    For contracted models, put the rate-to-amount calculation in a named
    adapter. Its incoming binding uses the producer's rate contract and its
    output declares the amount contract consumed downstream. For a varying
    rate, accumulate at the producer cadence or use a correctly averaged
    rate; multiplying one held sample by a long duration is valid only when
    the rate is constant over that interval. Keep contracts on both sides;
    see [Coupling models](@ref).

There is no same-step feedback cycle in either example, so
`PreviousTimeStep` is not needed. It should be introduced only when a real
scientific dependency intentionally reads the preceding step to break such a
cycle.

## Page recap

- **You added:** daily and hourly application clocks, `HoldLast` for a state,
  and then `Integrate` for a rate.
- **PlantSimEngine inferred:** the base-step ratios, publication schedule, and
  bounded temporal storage needed by the consumers.
- **You keep explicit:** each application cadence, the physical meaning of its
  temporal policy, and the integration window.
- **New API names:** `every`, `HoldLast`, `Integrate`, `Aggregate`,
  `window`, `Diagnostics.explain_schedule`, and
  `Diagnostics.explain_outputs`.

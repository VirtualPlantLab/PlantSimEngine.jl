# Give Models Different Cadences

## New concept: application clocks and temporal input policies

Running a whole composite over many timesteps was introduced on the first
journey. This page changes one thing: applications no longer all run at the
environment base step.

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
    Object(:plant; scale=:Plant, kind=:plant);
    applications=(
        ModelSpec(
            ToyDegreeDaysCumulModel();
            name=:degree_days,
            on=One(scale=:Plant),
            every=Day(1),
        ),
        ModelSpec(
            ToyLAIModel();
            name=:lai,
            on=One(scale=:Plant),
            every=Day(1),
        ),
        ModelSpec(
            Beer(0.6);
            name=:light,
            on=One(scale=:Plant),
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

`Integrate` has a different physical meaning. If a leaf publishes a constant
rate in units per second, integrating 24 hourly samples produces a daily
amount. The consumer below sums the independently integrated amounts from two
leaves.

```@example journey_cadences
PlantSimEngine.@process "cadence_hourly_flux" verbose = false
PlantSimEngine.@process "cadence_daily_amount" verbose = false

struct CadenceHourlyFlux <: AbstractCadence_Hourly_FluxModel end
struct CadenceDailyAmount <: AbstractCadence_Daily_AmountModel end

PlantSimEngine.inputs_(::CadenceHourlyFlux) = (rate=Required(Real),)
PlantSimEngine.outputs_(::CadenceHourlyFlux) = (flux=0.0,)
PlantSimEngine.run!(
    ::CadenceHourlyFlux,
    status,
    environment,
    constants,
    context,
) = (status.flux = status.rate)

PlantSimEngine.inputs_(::CadenceDailyAmount) = (
    leaf_amounts=Required(AbstractVector{<:Real}),
)
PlantSimEngine.outputs_(::CadenceDailyAmount) = (amount=0.0,)
PlantSimEngine.run!(
    ::CadenceDailyAmount,
    status,
    environment,
    constants,
    context,
) = (status.amount = sum(status.leaf_amounts))
```

```@example journey_cadences
flux_model = CompositeModel(
    Object(:plant; scale=:Plant),
    Object(
        :leaf_1;
        scale=:Leaf,
        parent=:plant,
        status=Status(rate=1.0),
    ),
    Object(
        :leaf_2;
        scale=:Leaf,
        parent=:plant,
        status=Status(rate=2.0),
    );
    applications=(
        ModelSpec(
            CadenceHourlyFlux();
            name=:hourly_flux,
            on=Many(scale=:Leaf),
            every=Hour(1),
        ),
        ModelSpec(
            CadenceDailyAmount();
            name=:daily_amount,
            on=One(scale=:Plant),
            inputs=(
                :leaf_amounts => Many(
                    scale=:Leaf,
                    within=Subtree(),
                    application=:hourly_flux,
                    var=:flux,
                    policy=Integrate(),
                    window=Day(1),
                ),
            ),
            every=Day(1),
        ),
    ),
    environment=[(duration=Hour(1),) for _ in 1:25],
)

flux_simulation = run!(flux_model; steps=25)
final_state(flux_simulation, One(scale=:Plant)).amount
```

The result is `(1 + 2) × 24 × 3600 = 259200` rate-seconds. Use
`Aggregate(reducer)` instead when the desired quantity is a mean, minimum,
maximum, or another reduction of observations rather than a time integral.

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

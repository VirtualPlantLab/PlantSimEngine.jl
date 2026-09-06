# Hourly, Daily, And Weekly Models

An hourly leaf application publishes rates. A daily plant application
integrates them over a day, and a weekly application consumes the daily
amounts. Each application remains a normal `ModelSpec`; only its `every`
value and input policy differ.

Runtime dependency streams are retained because consumers need them. Output
resampling is independent: create named `OutputRequest`s for hourly, daily,
and weekly analysis, then compare `Diagnostics.explain_schedule` sample counts with rows
from `collect_outputs`.

The following reduced example checks the important physical contract: two
leaf rates are integrated independently for 24 hourly samples and then summed
on their plant. Rates are per second, so the expected amount is
`(1 + 2) × 24 × 3600 = 259200`. The default `Integrate()` sums samples without
duration weighting; the explicit reducer below supplies the physical integral.

```@example hourly-daily
using Dates
using PlantSimEngine

PlantSimEngine.@process "docs_hourly_flux" verbose = false
PlantSimEngine.@process "docs_daily_total" verbose = false
struct DocsHourlyFlux <: AbstractDocs_Hourly_FluxModel end
struct DocsDailyTotal <: AbstractDocs_Daily_TotalModel end
PlantSimEngine.inputs_(::DocsHourlyFlux) = (rate=Required(Float64),)
PlantSimEngine.outputs_(::DocsHourlyFlux) = (flux=0.0,)
PlantSimEngine.run!(::DocsHourlyFlux, status, environment, constants, context) =
    (status.flux = status.rate)
PlantSimEngine.inputs_(::DocsDailyTotal) = (fluxes=Required(Vector{Float64}),)
PlantSimEngine.outputs_(::DocsDailyTotal) = (total=0.0,)
PlantSimEngine.run!(::DocsDailyTotal, status, environment, constants, context) =
    (status.total = sum(status.fluxes))

model = CompositeModel(
    Object(:plant; scale=:Plant),
    Object(:leaf_1; scale=:Leaf, parent=:plant, status=Status(rate=1.0)),
    Object(:leaf_2; scale=:Leaf, parent=:plant, status=Status(rate=2.0));
    applications=(
        ModelSpec(DocsHourlyFlux(); name=:hourly, on=Many(scale=:Leaf), every=Hour(1)),
        ModelSpec(
            DocsDailyTotal();
            name=:daily,
            on=One(scale=:Plant),
            inputs=(
                :fluxes => Many(
                scale=:Leaf, within=Subtree(), application=:hourly, var=:flux,
                policy=Integrate((values, durations_seconds) -> sum(values .* durations_seconds)), window=Day(1),
                ),
            ),
            every=Day(1),
        ),
    ),
    environment=[(duration=Hour(1),) for _ in 1:25],
)
simulation = run!(model; steps=25)
@assert only(object.status.total for object in model_objects(model)
             if object.id == ObjectId(:plant)) == 259200.0
```

A weekly consumer uses the same pattern with `every=Week(1)` and a
seven-day window over the daily application. Sum daily amounts with
`Integrate()`; integrate rates per second with the duration-aware reducer
shown above. Choose `Aggregate(reducer)` for states or observations whose physical meaning
is a mean, minimum, maximum, or custom statistic.

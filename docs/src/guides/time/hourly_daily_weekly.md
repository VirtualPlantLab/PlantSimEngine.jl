# Hourly, Daily, And Weekly Models

Use one hourly leaf application, a daily plant application with
`Many(scale=:Leaf, within=Subtree(), policy=Integrate(), window=Day(1))`, and a
weekly application consuming the daily stream. Each application remains a
normal `ModelSpec`; only its `TimeStep` and input policy differ.

Runtime dependency streams are retained because consumers need them. Output
resampling is independent: create named `OutputRequest`s for hourly, daily,
and weekly analysis, then compare `explain_schedule` sample counts with rows
from `collect_outputs`.

The following reduced example checks the important physical contract: two
leaf rates are integrated independently for 24 hourly samples and then summed
on their plant.

```@example hourly-daily
using Dates
using PlantSimEngine

PlantSimEngine.@process "docs_hourly_flux" verbose = false
PlantSimEngine.@process "docs_daily_total" verbose = false
struct DocsHourlyFlux <: AbstractDocs_Hourly_FluxModel end
struct DocsDailyTotal <: AbstractDocs_Daily_TotalModel end
PlantSimEngine.inputs_(::DocsHourlyFlux) = (rate=0.0,)
PlantSimEngine.outputs_(::DocsHourlyFlux) = (flux=0.0,)
PlantSimEngine.run!(::DocsHourlyFlux, status, meteo, constants, extra) =
    (status.flux = status.rate)
PlantSimEngine.inputs_(::DocsDailyTotal) = (fluxes=[0.0],)
PlantSimEngine.outputs_(::DocsDailyTotal) = (total=0.0,)
PlantSimEngine.run!(::DocsDailyTotal, status, meteo, constants, extra) =
    (status.total = sum(status.fluxes))

model = CompositeModel(
    Object(:plant; scale=:Plant),
    Object(:leaf_1; scale=:Leaf, parent=:plant, status=Status(rate=1.0)),
    Object(:leaf_2; scale=:Leaf, parent=:plant, status=Status(rate=2.0));
    applications=(
        ModelSpec(DocsHourlyFlux(); name=:hourly) |>
            AppliesTo(Many(scale=:Leaf)) |> TimeStep(Hour(1)),
        ModelSpec(DocsDailyTotal(); name=:daily) |>
            AppliesTo(One(scale=:Plant)) |>
            Inputs(:fluxes => Many(
                scale=:Leaf, within=Subtree(), application=:hourly, var=:flux,
                policy=Integrate(), window=Day(1),
            )) |> TimeStep(Day(1)),
    ),
    environment=[(duration=Hour(1),) for _ in 1:25],
)
simulation = run!(model; steps=25)
@assert only(object.status.total for object in model_objects(model)
             if object.id == ObjectId(:plant)) == 72.0
```

A weekly consumer uses the same pattern with `TimeStep(Week(1))` and a
seven-day window over the daily application. Keep `Integrate` for rates;
choose `Aggregate(reducer)` for states or observations whose physical meaning
is a mean, minimum, maximum, or custom statistic.

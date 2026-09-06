# Adding Roots And Water

This example adds the water taken up by two roots to one plant water stock.
It shows how to count each amount once when roots update hourly and the plant
updates daily. The uptake rates are constant teaching values, not predictions
from a root-uptake equation. We assume that the water supply can provide
these **already accepted** rates. The example does not calculate soil
competition, transpiration, or a complete plant water balance.

## Integrate each accepted interval once

Rates are in g water s⁻¹ per root. The plant adds a day's uptake in g water
once per day. Both `on=One(scale=:Plant)` and `every=Day(1)` are explicit:
updating this stock hourly with a rolling one-day total would count overlapping
intervals repeatedly.

```@example root-water
using Dates, PlantSimEngine

PlantSimEngine.@process "docs_root_uptake" verbose=false
PlantSimEngine.@process "docs_plant_water" verbose=false
struct DocsRootUptake <: AbstractDocs_Root_UptakeModel end
struct DocsPlantWater <: AbstractDocs_Plant_WaterModel end

PlantSimEngine.inputs_(::DocsRootUptake) = (accepted_rate=Required(Real),)
PlantSimEngine.outputs_(::DocsRootUptake) = (uptake=0.0,)
function PlantSimEngine.run!(::DocsRootUptake, status, environment, constants, context)
    status.uptake = status.accepted_rate
    return nothing
end

PlantSimEngine.inputs_(::DocsPlantWater) = (root_uptake=Required(AbstractVector{<:Real}),)
PlantSimEngine.outputs_(::DocsPlantWater) = (stored_water=0.0,)
function PlantSimEngine.run!(::DocsPlantWater, status, environment, constants, context)
    status.stored_water += sum(status.root_uptake)
    return nothing
end

model = CompositeModel(
    Object(:plant; scale=:Plant),
    Object(:root_1; scale=:Root, parent=:plant, status=Status(accepted_rate=1e-4)),
    Object(:root_2; scale=:Root, parent=:plant, status=Status(accepted_rate=2e-4));
    applications=(
        ModelSpec(DocsRootUptake(); name=:uptake, on=Many(scale=:Root), every=Hour(1)),
        ModelSpec(
            DocsPlantWater(); name=:water, on=One(scale=:Plant), every=Day(1),
            inputs=(root_uptake=Many(
                scale=:Root, within=Subtree(), application=:uptake, var=:uptake,
                policy=Integrate((values, seconds) -> sum(values .* seconds)),
                window=Day(1),
            ),),
        ),
    ),
    environment=(duration=Hour(1),),
)
simulation = run!(model; steps=49, outputs=:all)
water_history = [
    (base_step=row.time, stored_water_g=row.value)
    for row in collect_outputs(simulation; sink=nothing)
    if row.object_id == :plant && row.variable == :stored_water
]
@assert isapprox(final_state(simulation, :plant).stored_water, 49 * (1e-4 + 2e-4) * 3600)
water_history
```

The first daily calculation has only one hourly value available, so it adds
`1.08` g. Each following daily calculation adds 24 new hourly amounts, or
`25.92` g. The stock is therefore `1.08`, `27.0`, and `52.92` g at base steps
1, 25, and 49. All 49 supplied hourly amounts are counted once. A model set
to run daily still runs at the start, before a full day of values is available.

These totals describe uptake added to storage, not tissue hydration or growth.

## Share a limited soil water supply

When several plants share a limited soil water supply, use one model to
manage that stock. This model must collect all root demands, decide how much
water each receives, subtract the total withdrawal once, and return the
accepted rates or amounts to the plants. Simply letting each root read the
same soil stock does not prevent them from taking too much water together.
`Updates` can specify the order in which models change a value, but your
equations must decide how to share the water.

Supply rainfall through the environment and state its units before converting
it to an amount of soil water. Add each loss and exchange when extending
the plant balance. When growth adds a root, provide its initial values and
add it with `register_object!` or, for an MTG, `add_organ!`. The plant's `Many`
selection then includes that root after the creating application finishes.
See [Growing A Plant CompositeModel](@ref).

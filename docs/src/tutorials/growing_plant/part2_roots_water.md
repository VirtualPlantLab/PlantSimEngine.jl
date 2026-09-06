# Adding Roots And Water

This example gathers two roots' **already accepted** uptake rates into one
plant water stock. It teaches the time and ownership boundary; the constant
rates are illustrative, not a root-uptake equation. It assumes an external
water supply has granted those rates and does not simulate soil competition,
transpiration, or a complete plant water balance.

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

The first daily call has only one hourly sample available: its partial window
adds `1.08` g. Each following daily call adds 24 new hourly intervals, or
`25.92` g. The stock is therefore `1.08`, `27.0`, and `52.92` g at base steps
1, 25, and 49. All 49 supplied hourly amounts are counted once. A daily cadence
does not by itself suppress this partial startup window.

These totals describe uptake added to storage, not tissue hydration or growth.

## Extend the boundary to a shared soil

When several plants share finite soil water, give the soil stock one owner.
A collective soil/root controller must gather all demands, limit their sum to
the available water, subtract the accepted withdrawals once, and return the
accepted rates or amounts to each plant. Several roots independently reading
one soil stock do not provide that arbitration. `Updates` can order writers,
but it does not implement a resource-allocation rule.

Keep rainfall as environmental forcing and state its units before converting
it to a soil-water amount. Add losses and exchanges explicitly when extending
the plant balance. When growth adds a root, initialize its state and register
it through the lifecycle API; the plant-local `Many` binding then refreshes
after the creating application. See [Growing A Plant CompositeModel](@ref).

# Instantiate Several Plants

Two plants can use different equations for the same process in one
simulation. Here both plants receive the same amount of carbon, but use
different rules to divide it between leaves, wood, and reserves. This lets
you compare the rules while keeping the inputs the same.

We represent each whole plant as one object. For an example with individual
leaves, see [one multiscale plant](one_plant.md).

## Choose two allocation rules

Both models describe **carbon allocation**: deciding where available carbon
goes. They read the same inputs and produce the same outputs, so either can
fill the `:allocation` application in our plant template. Their equations
differ:

- `FixedFractionAllocation(0.5, 0.3)` assigns up to 50% of the available
  carbon to leaves and up to 30% to wood. Neither receives more than its
  demand. Carbon left over goes into reserves.
- `DemandAllocation()` divides carbon in proportion to leaf and wood demand.
  When there is enough carbon, both demands are met. Any excess goes into
  reserves.

You can see the difference in the equations. Let `C` be available carbon,
`L` leaf demand, and `W` wood demand. `min(a, b)` means the smaller of the
two amounts:

| Carbon sent to | Fixed fractions | Proportional to demand |
|---|---|---|
| Leaves | `min(0.5 * C, L)` | `min(C, L + W) * L / (L + W)` |
| Wood | `min(0.3 * C, W)` | `min(C, L + W) * W / (L + W)` |
| Reserves | What remains after leaf and wood allocation | What remains after leaf and wood allocation |

If both demands are zero, both models put all available carbon into reserves.

All amounts are grams of elemental carbon (g C) per plant. The example does
not convert carbon into dry biomass or subtract respiration losses, and
neither rule withdraws carbon from reserves.
The carbon offer is the amount available after any respiration costs. Offers
and demands must be finite and nonnegative.

Load the models from the example source included with PlantSimEngine:

```@example journey_several_plants
using PlantSimEngine, Dates, DataFrames

include(joinpath(pkgdir(PlantSimEngine), "examples", "two_plant_allocation.jl"))
using .TwoPlantAllocationExample
```

## Make a template and two plants

A `CompositeModelTemplate` stores models and their configuration for reuse.
Our template uses the fixed-fraction rule by default. The application name
`:allocation` identifies the calculation we will replace on the second plant.

```@example journey_several_plants
plant_template = CompositeModelTemplate((
    ModelSpec(
        FixedFractionAllocation(0.5, 0.3);
        name=:allocation,
        on=One(scale=:Plant),
    ),
))
nothing # hide
```

Each `ObjectInstance` supplies a plant and its initial values. Here `root`
means the object at the top of the plant's structure, not a botanical root.
Both plants have 10 g C available today, a leaf demand of 8 g C, and a wood
demand of 2 g C.

Plant A keeps the template's model. Plant B uses `overrides` to replace that
model with `DemandAllocation()`:

```@example journey_several_plants
plant_a = ObjectInstance(
    :plant_a,
    plant_template;
    root=Object(
        :plant_a;
        scale=:Plant,
        kind=:plant,
        status=Status(carbon_offer=10.0, leaf_demand=8.0, wood_demand=2.0),
    ),
)

plant_b = ObjectInstance(
    :plant_b,
    plant_template;
    root=Object(
        :plant_b;
        scale=:Plant,
        kind=:plant,
        status=Status(carbon_offer=10.0, leaf_demand=8.0, wood_demand=2.0),
    ),
    overrides=(allocation=DemandAllocation(),),
)
nothing # hide
```

The process is the same on both plants: `:carbon_allocation`. The model used
for that process is different. Each plant keeps its own inputs and carbon
pools; replacing Plant B's model does not change Plant A's model.

## Run both plants together

Put both plants in one `CompositeModel`. One step lasts one day here:

```@example journey_several_plants
model = CompositeModel(plant_a, plant_b; environment=(duration=Day(1),))
simulation = run!(model; steps=1, outputs=:all)
results = collect_outputs(simulation; sink=DataFrame)

allocation_rows = filter(
    :variable => v -> v in (:leaf_growth, :wood_growth, :reserve_change),
    results,
)
comparison = unstack(allocation_rows, :object_id, :variable, :value)
select(comparison, :object_id, :leaf_growth, :wood_growth, :reserve_change)
```

`collect_outputs` returns a table with one row per variable. We select the
three daily allocations, then use `unstack` to give each variable its own
column. Each row of the displayed table now describes one plant.

Plant A sends **5 g C to leaves, 2 to wood, and 3 to reserves**. Its wood
fraction would give 3 g C, but wood only demands 2. The unused carbon stays
in reserves rather than being reassigned to leaves.

Plant B sends **8 g C to leaves, 2 to wood, and 0 to reserves**. The available
10 g C is enough to meet both demands. In both cases, the three amounts add
up to the 10 g C supplied.

The models also keep cumulative `leaf_carbon`, `wood_carbon`, and
`reserve_carbon` values. These pools start at zero here, so after one day
they equal the amounts just allocated. They record allocated carbon, not
predicted organ biomass.

```@example journey_several_plants
fixed = final_state(simulation, :plant_a) # hide
demand = final_state(simulation, :plant_b) # hide
@assert (fixed.leaf_growth, fixed.wood_growth, fixed.reserve_change) == (5.0, 2.0, 3.0) # hide
@assert (demand.leaf_growth, demand.wood_growth, demand.reserve_change) == (8.0, 2.0, 0.0) # hide
@assert fixed.leaf_carbon + fixed.wood_carbon + fixed.reserve_carbon == 10.0 # hide
@assert demand.leaf_carbon + demand.wood_carbon + demand.reserve_carbon == 10.0 # hide
nothing # hide
```

To compare other conditions, change `carbon_offer`, `leaf_demand`, or
`wood_demand` when constructing the plants. These supplied values stay fixed
in this example: each new day supplies another 10 g C to each plant and
renews the demands. The carbon pools accumulate over those days. A longer
simulation could obtain changing daily values from
photosynthesis and organ-demand models. See
[Collect and plot results](../../guides/data/outputs_plotting.md) for comparing
the resulting time series.

# Modify Plant Structure

Start with one plant, one branch, and two leaves. Each leaf computes carbon
demand. We assume enough carbon is available to meet that demand and pass the
full amount to `ToyCBiomassModel`, which calculates growth and respiration.
We will add a leaf, move it to the branch, and remove another leaf. After
each change, we can check that the carbon balance still holds.

```@example journey_structure
using PlantSimEngine, DataFrames
using PlantSimEngine.Examples

model = CompositeModel(
    Object(:plant; scale=:Plant, kind=:plant),
    Object(:branch; scale=:Axis, kind=:axis, parent=:plant),
    Object(
        :leaf_1;
        scale=:Leaf,
        kind=:leaf,
        parent=:plant,
        status=Status(TT=10.0),
    ),
    Object(
        :leaf_2;
        scale=:Leaf,
        kind=:leaf,
        parent=:plant,
        status=Status(TT=15.0),
    );
    applications=(
        ModelSpec(
            ToyCDemandModel(
                optimal_biomass=12.0,
                development_duration=120.0,
            );
            name=:carbon_demand,
            on=Many(scale=:Leaf),
        ),
        ModelSpec(
            ToyCBiomassModel(1.2);
            name=:biomass,
            on=Many(scale=:Leaf),
            inputs=(
                :carbon_allocation => One(
                    within=Self(),
                    application=:carbon_demand,
                    var=:carbon_demand,
                ),
            ),
        ),
    ),
)

simulation = run!(model; outputs=:all)
initial_targets = only(
    row for row in Diagnostics.explain_applications(simulation)
    if row.application_id == :biomass
).target_ids
```

## Add one leaf

Use `register_object!` to add a leaf with its initial thermal time. The
simulation then needs to update which leaves its models run on. Here we add
the leaf between steps, so PlantSimEngine makes that update before running
the next step with `continue!`:

```@example journey_structure
register_object!(
    model,
    Object(
        :leaf_3;
        scale=:Leaf,
        kind=:leaf,
        status=Status(TT=20.0),
    );
    parent=:plant,
)

targets_before_refresh = only(
    row for row in Diagnostics.explain_applications(simulation)
    if row.application_id == :biomass
).target_ids

continue!(simulation)

targets_after_refresh = only(
    row for row in Diagnostics.explain_applications(simulation)
    if row.application_id == :biomass
).target_ids

(
    initial_targets=initial_targets,
    before_refresh=targets_before_refresh,
    after_refresh=targets_after_refresh,
    leaf_3_parent=only(
        object.parent.value
        for object in model_objects(model)
        if object.id == ObjectId(:leaf_3)
    ),
)
```

You can also create organs inside a model's `run!` function, for example in
a growth model. In that case, PlantSimEngine updates the simulation after
that model finishes. The new organ can take part in calculations scheduled
later in the same timestep. Calculations that already ran are not repeated
automatically: to run one of them on the new organ, the growth model must
declare an `Initializer` and call `run_initializer!`. See
[Manual Calls Across Objects](../../guides/multiscale/manual_calls.md).

## Reparent, then remove

First change the new leaf's parent from the plant to the branch, then advance
the simulation:

```@example journey_structure
reparent_object!(model, :leaf_3, :branch)
continue!(simulation)

leaf_3_parent = only(
    object.parent.value
    for object in model_objects(model)
    if object.id == ObjectId(:leaf_3)
)
```

Then remove `:leaf_2` and advance once more:

```@example journey_structure
removed = remove_object!(model, :leaf_2)
continue!(simulation)

(
    removed=removed.id.value,
    current_leaves=sort!([
        object.id.value
        for object in model_objects(model; scale=:Leaf)
    ]),
    leaf_3_parent=leaf_3_parent,
    current_targets=only(
        row for row in Diagnostics.explain_applications(simulation)
        if row.application_id == :biomass
    ).target_ids,
)
```

## Check conservation and history

In this example, each leaf receives all the carbon it demands. For every
saved timestep, check that this carbon equals the increase in biomass plus
the carbon used in growth respiration:

```@example journey_structure
rows = collect_outputs(simulation; sink=nothing)

demand = Dict(
    (row.timestep, row.object_id) => row.value
    for row in rows
    if row.application_id == :carbon_demand &&
       row.variable == :carbon_demand
)
increment = Dict(
    (row.timestep, row.object_id) => row.value
    for row in rows
    if row.application_id == :biomass &&
       row.variable == :carbon_biomass_increment
)
respiration = Dict(
    (row.timestep, row.object_id) => row.value
    for row in rows
    if row.application_id == :biomass &&
       row.variable == :growth_respiration
)

all(
    demand[key] ≈ increment[key] + respiration[key]
    for key in keys(demand)
)
```

You can still read a removed leaf's earlier results:

```@example journey_structure
history_counts = Dict(
    id => length(collect_outputs(
        simulation,
        id,
        :carbon_biomass;
        sink=nothing,
    ))
    for id in (:leaf_1, :leaf_2, :leaf_3)
)
```

`:leaf_2` keeps the three samples saved before removal. Results for `:leaf_3`
begin at step 2, after it was added, and also contain three samples.

`ToyCAllocationModel` is useful when supply is limiting and a plant controller
must divide carbon among organs. Here we assume there is enough carbon to
meet every demand, so you can focus on when organs are added or removed and
how to check their results.

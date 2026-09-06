# Modify Plant Structure

## New concept: lifecycle changes refresh compiled targets

Start with one plant, one branch, and two leaves. Each leaf computes carbon
demand, then treats that fully met demand as accepted carbon allocation for
`ToyCBiomassModel`. This small chain gives us a conserved quantity to check
while topology changes.

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

Registering an object mutates the live model and marks affected compiled state
dirty. Because this call happens between simulation steps, the new leaf is
compiled before the next step:

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

When a lifecycle operation occurs *inside* a model kernel, PlantSimEngine
refreshes after that application. A newly registered object may therefore run
applications that remain later in the same timestep. It runs an application
that already completed only through an explicit `Initializer` binding and
`run_initializer!` call from its creator.

## Reparent, then remove

Creation now works, so make two further changes in order. First move the new
leaf under the branch and advance:

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

For every retained leaf sample, accepted carbon allocation equals demand. The
biomass model partitions it into biomass increment plus growth respiration:

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

Removed-object history remains queryable even though the object is no longer
in the registry:

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

`:leaf_2` keeps the three samples published before removal; `:leaf_3` begins at
step 2, after registration, and also has three samples.

`ToyCAllocationModel` is useful when supply is limiting and a plant controller
must divide carbon among many organ demands. This journey deliberately assumes
all demand is accepted so lifecycle timing and conservation stay visible
without introducing a controller or hard calls.

## Page recap

- **You added:** one leaf, then one reparenting operation, then one removal.
- **PlantSimEngine inferred:** the affected application targets, status views,
  reference binding, execution batch extension, and retained stream keys.
- **You keep explicit:** initialized status for a new object, its parent,
  conservation assumptions, and when removal or reparenting occurs.
- **New API names:** `register_object!`, `reparent_object!`, `remove_object!`,
  and `Diagnostics.explain_applications(simulation)`.

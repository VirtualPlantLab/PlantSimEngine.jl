# Instantiate Several Plants

## New concept: templates, instances, and overrides

The previous journey configured one plant explicitly. Its three applications
can become a `CompositeModelTemplate`, then be mounted on several independent
object topologies without duplicating that model configuration.

```@example journey_several_plants
using PlantSimEngine, DataFrames
using PlantSimEngine.Examples

plant_template = CompositeModelTemplate((
    ModelSpec(
        ToyLeafSurfaceModel(0.02);
        name=:leaf_surface,
        on=Many(scale=:Leaf),
    ),
    ModelSpec(
        ToyPlantLeafSurfaceModel();
        name=:plant_surface,
        on=One(scale=:Plant),
        inputs=(
            :leaf_surfaces => Many(
                scale=:Leaf,
                within=Subtree(),
                application=:leaf_surface,
                var=:surface,
            ),
        ),
    ),
    ModelSpec(
        ToyLightPartitioningModel();
        name=:leaf_light,
        on=Many(scale=:Leaf),
        inputs=(
            :aPPFD_larger_scale => One(
                scale=:Plant,
                within=SelfPlant(),
                var=:aPPFD,
            ),
            :total_surface => One(
                scale=:Plant,
                within=SelfPlant(),
                application=:plant_surface,
                var=:surface,
            ),
        ),
    ),
))
```

An `ObjectInstance` supplies the concrete root and organs. These two instances
reuse the same template while keeping different initial plant radiation and
leaf biomasses:

```@example journey_several_plants
plant_a = ObjectInstance(
    :plant_a,
    plant_template;
    root=Object(
        :plant_a_root;
        scale=:Plant,
        kind=:plant,
        status=Status(aPPFD=120.0),
    ),
    objects=(
        Object(
            :plant_a_leaf_1;
            scale=:Leaf,
            kind=:leaf,
            parent=:plant_a_root,
            status=Status(carbon_biomass=50.0),
        ),
        Object(
            :plant_a_leaf_2;
            scale=:Leaf,
            kind=:leaf,
            parent=:plant_a_root,
            status=Status(carbon_biomass=100.0),
        ),
    ),
)

plant_b = ObjectInstance(
    :plant_b,
    plant_template;
    root=Object(
        :plant_b_root;
        scale=:Plant,
        kind=:plant,
        status=Status(aPPFD=200.0),
    ),
    objects=(
        Object(
            :plant_b_leaf_1;
            scale=:Leaf,
            kind=:leaf,
            parent=:plant_b_root,
            status=Status(carbon_biomass=50.0),
        ),
        Object(
            :plant_b_leaf_2;
            scale=:Leaf,
            kind=:leaf,
            parent=:plant_b_root,
            status=Status(carbon_biomass=50.0),
        ),
    ),
)

model = CompositeModel(plant_a, plant_b)
simulation = run!(model; outputs=:all)
plant_states = final_state(simulation, Many(scale=:Plant))
Dict(id => (surface=state.surface, aPPFD=state.aPPFD) for (id, state) in plant_states)
```

Plant A aggregates surfaces `1 + 2 = 3`; plant B aggregates `1 + 1 = 2`.
Those totals prove that `Subtree()` did not mix leaves between instances.
Likewise, each pair of leaf-level light outputs sums to its own plant's
supplied light:

```@example journey_several_plants
leaf_states = final_state(simulation, Many(scale=:Leaf))
(
    plant_a_light=sum(
        leaf_states[id].aPPFD
        for id in (:plant_a_leaf_1, :plant_a_leaf_2)
    ),
    plant_b_light=sum(
        leaf_states[id].aPPFD
        for id in (:plant_b_leaf_1, :plant_b_leaf_2)
    ),
)
```

The instance diagnostic shows the mounted object and application ids. Template
application names are prefixed automatically, so the two mounted graphs remain
unambiguous:

```@example journey_several_plants
select(
    DataFrame(Diagnostics.explain_instances(model)),
    :name,
    :root_id,
    :object_ids,
    :application_ids,
)
```

## Override one instance

Only after the two unchanged instances work, override one application for a
new instance. This plant uses a larger specific leaf area while retaining the
same logical `:leaf_surface` application and all other template wiring:

```@example journey_several_plants
plant_c = ObjectInstance(
    :plant_c,
    plant_template;
    root=Object(
        :plant_c_root;
        scale=:Plant,
        kind=:plant,
        status=Status(aPPFD=120.0),
    ),
    objects=(
        Object(
            :plant_c_leaf_1;
            scale=:Leaf,
            kind=:leaf,
            parent=:plant_c_root,
            status=Status(carbon_biomass=50.0),
        ),
        Object(
            :plant_c_leaf_2;
            scale=:Leaf,
            kind=:leaf,
            parent=:plant_c_root,
            status=Status(carbon_biomass=100.0),
        ),
    ),
    overrides=(leaf_surface=ToyLeafSurfaceModel(0.04),),
)

override_simulation = run!(CompositeModel(plant_c))
override_state = final_state(override_simulation, One(scale=:Plant))
override_state.surface
```

There is no `SceneScope()` in this example because nothing is deliberately
shared between plants. Introduce scene-wide scope only when adding a real
shared source, such as a soil object or scene-level forcing controller.

## Page recap

- **You added:** one reusable `CompositeModelTemplate`, two independent
  `ObjectInstance`s, and then one application override.
- **PlantSimEngine inferred:** instance-local selector scopes, prefixed mounted
  application ids, and the same compiled coupling graph for each plant.
- **You keep explicit:** each instance's objects and initial values, plus the
  exact application replaced by an override.
- **New API names:** `CompositeModelTemplate`, `ObjectInstance`, `overrides`,
  and `Diagnostics.explain_instances`.

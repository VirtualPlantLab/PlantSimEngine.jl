# Instantiate Several Plants

Apply the configuration from [one multiscale plant](one_plant.md) to two plants,
then change the specific leaf area of a third. A `CompositeModelTemplate`
stores the models and their connections so you can reuse them. Each
`ObjectInstance` supplies a plant, its leaves, and their initial values.

As in that teaching example, light values are contributions per m² of a
plant's reference ground area per second, in μmol of absorbed PAR. A plant's
leaf contributions share that basis and can be added within the plant.
They are not fluxes per unit leaf area. Combining plants with different
reference areas would require an explicit area conversion first.

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
nothing # hide
```

Create two plants from the template. Here `root` is the object representing
the whole plant, at the top of its structure; it does not mean a botanical
root. The plants have different absorbed light and initial leaf biomasses:

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

Plant A has `1 + 2 = 3 m²` of leaves; plant B has `1 + 1 = 2 m²`.
Each plant uses only its own leaves when calculating the total, because the
selector uses `Subtree()`. Likewise, each pair of leaf light contributions
adds up to the light supplied to its own plant, expressed per m² of that
plant's reference ground area:

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

The table below lists the objects and model applications for each plant.
PlantSimEngine adds the plant instance name to each application name, which
lets you distinguish the two plants' calculations:

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

Now create a third plant with a larger specific leaf area. Set `overrides`
to replace the model used for `:leaf_surface` on this plant. The other models
and their connections stay as defined in the template:

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

The third plant has 6 m² of leaves: twice the area at the original specific
leaf area, for the same supplied carbon biomass. This is a parameter comparison
within the teaching model, not a calibrated species comparison.

The plants do not share any inputs in this example. If they need to read a
shared soil object, for example, use `within=SceneScope()` in that input's
selector. This allows it to look beyond the current plant.

# Build One Multiscale Plant

Share an absorbed-light supply between two leaves, then compute how their
areas contribute to the plant total. This teaching example represents the
plant and its two leaves as three objects. Each leaf names the plant as its
`parent`, which records that the leaf belongs to that plant. The leaf areas
and radiation values are illustrative.

The structure is:

> `:plant`<br>
> ├─ `:leaf_1`<br>
> └─ `:leaf_2`

To choose objects for a calculation, use a **selector** such as
`Many(scale=:Leaf)`. The `within` option limits where to look. For a model
running on `:plant`, `Subtree()` includes that plant and everything below it,
so `Many(scale=:Leaf, within=Subtree())` selects its two leaves. For a model
running on a leaf, `Self()` means that leaf, and `SelfPlant()` means its plant.

## First pass: share light between leaves

Start by supplying the leaf areas and their total in `Status`, where each
object stores its values. Each leaf model will read the plant's absorbed
light and total leaf area to calculate its own share.

We use one **common reference ground area** for the whole plant. Its supplied
`aPPFD` is 120 μmol m⁻² of reference ground s⁻¹. Each leaf receives a share in
proportion to its area: `120 × 1/3 = 40` and `120 × 2/3 = 80`, on that same
ground-area basis. These contributions can be added to recover 120. They are
not photon flux densities per unit leaf area. This deliberately simple share
does not calculate shading or 3D light interception.

```@example journey_one_plant
using PlantSimEngine, DataFrames
using PlantSimEngine.Examples

objects = (
    Object(
        :plant;
        scale=:Plant,
        kind=:plant,
        status=Status(aPPFD=120.0, surface=3.0),
    ),
    Object(
        :leaf_1;
        scale=:Leaf,
        kind=:leaf,
        parent=:plant,
        status=Status(surface=1.0),
    ),
    Object(
        :leaf_2;
        scale=:Leaf,
        kind=:leaf,
        parent=:plant,
        status=Status(surface=2.0),
    ),
)

scalar_model = CompositeModel(
    objects...;
    applications=(
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
                    var=:surface,
                ),
            ),
        ),
    ),
)

scalar_simulation = run!(scalar_model; outputs=:all)
scalar_states = final_state(scalar_simulation, Many(scale=:Leaf))
Dict(id => state.aPPFD for (id, state) in scalar_states)
```

The areas stored in `surface` are in m² of leaves. A leaf photosynthesis model
may instead need light per m² of leaf. To make that conversion, multiply a
leaf's contribution by the plant's reference ground area, then divide by
that leaf's area. Write this conversion as a model so the units are clear
when connecting the two calculations; see [Coupling models](../../guides/coupling.md).

Each leaf model reads `surface` from that leaf and uses `SelfPlant()` to find
the plant's `aPPFD` and total `surface`. In the table below, `consumer_id`
identifies the object reading a value, and `source_ids` identifies where the
value comes from. `carrier_kind` describes how PlantSimEngine shares it;
`ref` means the model reads the source's current value directly.

```@example journey_one_plant
select(
    DataFrame(Diagnostics.explain_bindings(scalar_model)),
    :consumer_id,
    :input,
    :source_ids,
    :carrier_kind,
)
```

## Second pass: calculate leaf areas and their total

Now replace the supplied surfaces with two existing models:

- `ToyLeafSurfaceModel` computes each leaf surface from its carbon biomass;
- `ToyPlantLeafSurfaceModel` sums those leaf surfaces on the plant.

Here the leaf carbon biomasses are 50 and 100 g C, and the specific leaf area
is 0.02 m² g C⁻¹. Their calculated areas are therefore 1 and 2 m², preserving
the light shares from the first pass.

The plant model now needs a collection of values: one area from each leaf.
The `Many(...)` selector for `:leaf_surfaces` provides that collection, which
`ToyPlantLeafSurfaceModel` adds together.

```@example journey_one_plant
computed_objects = (
    Object(
        :plant;
        scale=:Plant,
        kind=:plant,
        status=Status(aPPFD=120.0),
    ),
    Object(
        :leaf_1;
        scale=:Leaf,
        kind=:leaf,
        parent=:plant,
        status=Status(carbon_biomass=50.0),
    ),
    Object(
        :leaf_2;
        scale=:Leaf,
        kind=:leaf,
        parent=:plant,
        status=Status(carbon_biomass=100.0),
    ),
)

computed_model = CompositeModel(
    computed_objects...;
    applications=(
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
    ),
)

computed_simulation = run!(computed_model; outputs=:all)
plant_state = final_state(computed_simulation, One(scale=:Plant))
leaf_states = final_state(computed_simulation, Many(scale=:Leaf))
(
    plant_surface=plant_state.surface,
    leaf_surfaces=Dict(id => state.surface for (id, state) in leaf_states),
    leaf_light=Dict(id => state.aPPFD for (id, state) in leaf_states),
)
```

The resulting plant surface should be 3 m² and the light contributions should
still be 40 and 80 μmol m⁻² of reference ground s⁻¹. You can now
[reuse this configuration on several plants](several_plants.md).

The optional table below lets you check the connections. For
`:leaf_surfaces`, the plant should read from both leaves. Its `RefVector`
holds references to their current areas, so the plant sees the new values
after the leaf models update them. Inputs with just one source use `ref`.

```@example journey_one_plant
select(
    DataFrame(Diagnostics.explain_bindings(computed_model)),
    :application_id,
    :consumer_id,
    :input,
    :source_ids,
    :carrier_kind,
)
```

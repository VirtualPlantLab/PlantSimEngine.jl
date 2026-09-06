# Build One Multiscale Plant

## New concept: topology and cross-object values

Share an absorbed-light supply between two leaves, then compute how their
surfaces contribute to the plant total. This teaching example adds a
parent/child structure: one plant object owns two leaf objects. The leaf
surfaces and radiation values are illustrative.

The scope picture for this page is:

> `:plant` — `Subtree()` from here contains `:plant`, `:leaf_1`, and `:leaf_2`<br>
> ├─ `:leaf_1` — `Self()` is `:leaf_1`; `SelfPlant()` resolves to `:plant`<br>
> └─ `:leaf_2` — `Self()` is `:leaf_2`; `SelfPlant()` resolves to `:plant`

Selectors still filter that scope. For example,
`Many(scale=:Leaf, within=Subtree())` selects the two leaves when evaluated for
the plant application.

## First pass: one scalar value from plant to leaves

Start with leaf surfaces and total plant surface supplied as status. The only
new value connection sends the plant-level absorbed light to each leaf.

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

The surfaces are in m² of leaves. To obtain a mean leaf-area photon flux from
one contribution, multiply it by the plant's reference ground area and divide
by that leaf's area. Such a change of basis belongs in an explicit model when
coupling to a leaf photosynthesis model; see [Coupling models](../../guides/coupling.md).

The leaf model reads its own `surface` directly from each leaf status.
`SelfPlant()` makes the other two scalar sources plant-local:

```@example journey_one_plant
select(
    DataFrame(Diagnostics.explain_bindings(scalar_model)),
    :consumer_id,
    :input,
    :source_ids,
    :carrier_kind,
)
```

## Second pass: compute and aggregate leaf surfaces

Now replace the supplied surfaces with two existing models:

- `ToyLeafSurfaceModel` computes each leaf surface from its carbon biomass;
- `ToyPlantLeafSurfaceModel` sums those leaf surfaces on the plant.

Here the leaf carbon biomasses are 50 and 100 g C, and the specific leaf area
is 0.02 m² g C⁻¹. Their calculated areas are therefore 1 and 2 m², preserving
the light shares from the first pass.

This is the first vector-like cross-object input. It comes after the scalar
connection above, and differs only in the new `:leaf_surfaces` binding.

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

The following optional diagnostic shows that the plant reads its own leaves.
Its `RefVector` is a collection of live values; individual scalar inputs use
single references:

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

## Page recap

- **You added:** parent/child topology, plant-to-leaf scalar connections, and
  one plant-local vector aggregation.
- **PlantSimEngine inferred:** same-leaf `surface` coupling, application order,
  and live scalar/vector reference carriers.
- **You keep explicit:** object parentage, the scope of cross-object searches,
  and the source application when selecting a produced value.
- **New API names:** `parent`, `Self`, `SelfPlant`, `Subtree`, and the
  `application` and `var` selector fields.

# Import A Plant From An MTG

A MultiScaleTreeGraph (MTG) stores a plant's organs and their relationships.
Use it when you already have a measured or generated architecture. The models
and value connections are the same as in [One multiscale plant](../../journeys/users/one_plant.md);
the MTG supplies the objects and their parent links.

Install `MultiScaleTreeGraph` in your project to run this example. We create a
small MTG here so no external data file is needed:

```@example import_mtg
using PlantSimEngine, MultiScaleTreeGraph, DataFrames
using PlantSimEngine.Examples

root = Node(NodeMTG("/", :Plant, 1, 0))
leaf_1 = Node(root, NodeMTG("/", :Leaf, 1, 1))
leaf_2 = Node(root, NodeMTG("/", :Leaf, 2, 1))
leaf_1[:carbon_biomass] = 50.0
leaf_2[:carbon_biomass] = 100.0
nothing # hide
```

The `/` links describe leaves as components at a finer scale than the plant;
this reduced architecture omits stems and petioles. For an existing MTG file, replace these lines with
`root = read_mtg("my_plant.mtg")`. Inspect its symbols first: this example uses
`:Plant` and `:Leaf`, but your file may use different names.

## Choose which attributes become simulation state

Node IDs and parent links are imported automatically. By default, `scale`
comes from the MTG symbol. Numerical attributes are **not** automatically
copied into model status: supply the values your models need explicitly.

```@example import_mtg
initial_status(node) = MultiScaleTreeGraph.symbol(node) == :Leaf ?
    Status(carbon_biomass=node[:carbon_biomass]) : Status()

model = CompositeModel(
    root;
    status=initial_status,
    applications=(
        ModelSpec(ToyLeafSurfaceModel(0.02);
            name=:leaf_surface, on=Many(scale=:Leaf)),
        ModelSpec(ToyPlantLeafSurfaceModel();
            name=:plant_surface, on=One(scale=:Plant),
            inputs=(leaf_surfaces=Many(
                scale=:Leaf, within=Subtree(),
                application=:leaf_surface, var=:surface,
            ),)),
    ),
)

DataFrames.select(DataFrame(Diagnostics.explain_objects(model)), :id, :scale, :parent)
```

The teaching leaf model uses carbon biomass in g C and a specific leaf area
of 0.02 m² per g C. It gives leaf areas of 1 and 2 m², whose sum is 3 m²:

```@example import_mtg
simulation = run!(model; outputs=:all)
plant_area = final_state(simulation, One(scale=:Plant)).surface
@assert plant_area ≈ 3.0 # hide
plant_area
```

## Keep the link to the MTG when the plant grows

`CompositeModel(root; ...)` retains the MTG adapter. It can resolve a source
node to an object with `object_id(model, leaf_1)`, and `add_organ!` reuses the
chosen status import rule when new organs appear. Required attributes must be
available when that rule runs, or the rule must deliberately initialize them.
See [Growth within a time step](../../tutorials/growing_plant/part1_growth.md).

Use `objects_from_mtg(root; status=initial_status)` when you only want a
one-time list of `Object`s to assemble yourself. This projection does not keep
the MTG identity index needed for later node lookup or organ creation.

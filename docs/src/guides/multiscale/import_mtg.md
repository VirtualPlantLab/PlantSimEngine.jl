# Import A Plant From An MTG

A MultiScaleTreeGraph (MTG) stores a plant's organs and their relationships.
Use it when you already have a measured or generated architecture. The models
and value connections are the same as in [One multiscale plant](../../journeys/users/one_plant.md);
the MTG supplies the objects and records which organ each one belongs to.

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

PlantSimEngine imports each node's ID and parent automatically. By default,
it uses the MTG symbol, such as `:Leaf`, as the object's `scale` label.
It does **not** automatically copy numerical attributes into `Status`,
where models read and store their values. The function below chooses the
initial values to import: each leaf's carbon biomass in this example.

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

`CompositeModel(root; ...)` keeps the relationship between MTG nodes and
simulation objects. Use `object_id(model, leaf_1)` to find the object for a
node. When you create an organ with `add_organ!`, PlantSimEngine reuses your
`initial_status` function to set its initial values. The new node must have
the attributes this function reads, or the function must supply suitable
initial values itself.
See [Growth within a time step](../../tutorials/growing_plant/part1_growth.md).

Use `objects_from_mtg(root; status=initial_status)` when you only want a
list of `Object`s to assemble yourself. It does not keep the node-to-object
lookup needed to find nodes or create new organs through the MTG later.

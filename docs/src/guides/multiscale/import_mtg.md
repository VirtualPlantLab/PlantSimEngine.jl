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
where models read and store their values. Supply a function that returns a
`Status` for each node to choose which attributes to import. It can read the
node's attributes, provide missing initial values, or return an empty
`Status()`. This function runs when you create the `CompositeModel`.

In the example below, it initializes carbon biomass only for leaves. The
plant-scale model reads the leaf areas calculated from that biomass, so it
does not need its own carbon biomass value.

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

`add_organ!` creates the new node and returns its model status. Give the
leaf its starting biomass through `initial_status`. Use `attributes` for
tree data such as a field tag or geometry.

```@example import_mtg
young = add_organ!(root, model, "/", :Leaf, 1; index=3,
    initial_status=(carbon_biomass=25.0,), attributes=(tag="leaf 3",))
continue!(simulation; steps=1)
node = source_node(model, young)
@assert node[:tag] == "leaf 3" # hide
@assert young.surface ≈ 0.5 # hide
(area=young.surface, tag=node[:tag])
```

The original import callback runs when you construct the model. During
growth, each new leaf uses the field types and numerical conversions
prepared for its models. `source_node(model, young)` returns the live MTG
node, and `object_id(model, node)` gives its simulation identifier.
Use a key such as `tag` for field notes. The default MTG adapter uses
`kind` and `species` to select model objects, and `name` for display.
To grow an MTG in a native application, use a version of MultiScaleTreeGraph
that provides `prepare_node_edits`. PSE infers the types of the default
`kind`, `species` and `name` labels from the tree. Declare a column before
preparation if future organs will inherit its default, for example
`add_column!(root, :Leaf, :kind, Symbol; default=:expanding)`. An application
can also supply the label at birth with `attributes=(kind=:expanding,)`
when the prepared tree supports that column type. On a tree with only numeric
columns, declare the symbol column first. To set only the simulation object's
label, pass `kind=:expanding` directly to `add_organ!`.

### Give future organs their own fields

Suppose the initial plant has no flowers. When a flower appears, the growth
model supplies its sex. Declare this field on the callable that imports the
initial statuses so PSE can prepare its storage before the first flower exists.

```@example future_flower
using PlantSimEngine, MultiScaleTreeGraph

struct PalmInitialStatus end
(::PalmInitialStatus)(node) = nothing
PlantSimEngine.birth_status_types(::PalmInitialStatus, objects) =
    (Flower=(sex=Symbol,),)

palm = Node(1, NodeMTG(:/, :Plant, 1, 0), NamedTuple())
plant = CompositeModel(palm; status=PalmInitialStatus())
flower = add_organ!(palm, plant, :+, :Flower, 1; initial_status=(sex=:female,))
flower.sex
```

Use a finite union such as `Union{Int,Float64}` when new organs can supply
either representation. If the organ names depend on plant parameters,
read those parameters from the initialized plants in `objects` and return a
dictionary keyed by their organ symbols. Each object exposes its `scale` and
`status`. PSE reuses the declaration as the plant grows.

A `from_status` input declared with `Required(Real)` can read a numeric cell.
If a new organ falls in its selection, a text cell is rejected before that
organ joins the tree. The same text field can belong to an organ outside that
selection. A `Default` value supplies the input's starting value.

See [Growth within a time step](../../tutorials/growing_plant/part1_growth.md).

Use `objects_from_mtg(root; status=initial_status)` when you only want a
list of `Object`s to assemble yourself. It does not keep the node-to-object
lookup needed to find nodes or create new organs through the MTG later.

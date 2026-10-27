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
where models read and store their values. To do that, you can supply a function that returns a `Status` for each node. The function can read any attributes you have stored in the MTG, and it can supply default values for missing attributes. The function is called for each node when you create the `CompositeModel` or when you add a new organ with `add_organ!`. The function can return an empty `Status()` if you do not want to import any attributes for a node.
In our example below, this function initializes carbon biomass only for leaves. The plant-scale model reads the leaf areas calculated from that biomass, so it does not need its own carbon biomass value.

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

## Share selected variables with the source graph

When another process updates the MTG during a simulation, copying an attribute
into a private `Ref` does not provide a live view of that source. An explicit
`status_factory` can choose the variables of each new organ and keep their
references attached to the source storage. The numerical values below only
illustrate reference semantics; they are not a growth model.

```@example shared_mtg_status
using PlantSimEngine, MultiScaleTreeGraph

plant = Node(NodeMTG(:/, :Plant, 1, 0))

function live_organ_status(node, adapted_status, initial_status)
    return Status((
        node=Ref(node),
        Length=attribute_ref(node, :Length, Float64),
    ))
end

live_model = CompositeModel(plant; status_factory=live_organ_status)
leaf_status = add_organ!(plant, live_model, :+, :Leaf, 1;
    attributes=(Length=1.0, description="source metadata"),
    use_status_adapter=false)
leaf = source_node(live_model, leaf_status)
leaf_status.Length = 2.0
@assert leaf[:Length] == 2.0 # hide
leaf[:Length] = 3.0
@assert leaf_status.Length == 3.0 # hide
@assert !hasproperty(leaf_status, :description) # hide
leaf_status.Length
```

The factory is retained by the model and applies to **new organs**. Initial MTG
import still uses the `status=` accessor. It is called after that accessor during
organ creation, as `(node, adapted_status, initial_status)`, and must return a
fresh `Status` containing the exact new node in its `node` field. Explicit
`initial_status` variables must be present with their original values and types;
selected adapter values retain their precedence unless explicitly overridden.
The factory can omit scientific source attributes that no process needs.

`Status` accepts custom `Ref{T}` cells, and homogeneous `Many` connections retain
their concrete cell type in a `RefVector`. One-source inputs also keep the live
cell. Ordinary status conversion policies remain active: if a policy changes a
value or its type, registration can replace that cell with private storage.

!!! note "Ownership and lifetime"
    Source-backed references are explicit shared state. Create separate source
    stores for independent simulations. Do not place the returned `Status` in
    MTG attributes or return a status already owned by another object. Factories
    must not modify existing model state: rejecting a new organ removes its new
    node, but cannot undo arbitrary callback side effects. MTG attribute references
    reject removed nodes or variables, and a reference does not keep a deleted
    organ active in the model.

Sharing scalar cells does not invalidate geometry caches or environmental
bindings. For example, a model can change `Length` in the MTG while a PlantGeom
mesh still represents the previous length. Rebuild or update the geometry, then
follow the existing `update_geometry!` or `mark_environment_binding_dirty!`
contract for affected objects before using geometry-dependent inputs.

## Use a client-owned MTG node backend

MTG adaptation accepts `AbstractMTGNode` implementations. A backend supplies its
identity, encoding, attributes, parent/children and traversal operations through
the MTG interface. During `add_organ!`, PlantSimEngine calls
`MultiScaleTreeGraph.add_node!(parent, id, encoding, attributes)` instead of
constructing a concrete `Node`. The backend also provides node lookup, fresh-ID
selection and deletion so rejection can remove a partially created node.

This permits lightweight node handles on a compact store while retaining PSE
object identities, selectors and lifecycle refresh. The adapter does not infer
independent simulation ownership or a complete MTG export from a handle.

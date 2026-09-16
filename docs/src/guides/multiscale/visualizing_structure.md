# Visualize Plant Structure

[PlantGeom.jl](https://vezy.github.io/PlantGeom.jl/stable/) provides diagrams
and 3D views of plants stored in a MultiScaleTreeGraph (MTG). An MTG records
the organs and their relationships. Geometry can be added to describe their
shapes, orientations and positions.

## Inspect connections between organs

Use PlantGeom's `diagram` to see how organs are connected and which organs
belong to each plant. It draws a schematic layout from the MTG: you do not
need meshes or measured positions. The positions in this diagram are chosen
for readability and do not show the plant's physical shape.

See [PlantGeom's diagram guide](https://vezy.github.io/PlantGeom.jl/stable/plot_diagram/makie_diagram.html)
for examples and colour options.

## View the plant in 3D

Use PlantGeom's `plantviz` when you want to see organ shapes and positions.
This view needs geometry attached to the MTG nodes, such as meshes and the
transformations that place them in the plant. You can import geometry from a
file or build it from organ attributes and reference shapes using PlantGeom.
The MTG's connections alone are not enough to reconstruct a 3D plant.

Start with the [3D plotting tutorial](https://vezy.github.io/PlantGeom.jl/stable/getting_started/showcase.html).
If your MTG does not yet have geometry, follow the
[geometry construction workflows](https://vezy.github.io/PlantGeom.jl/stable/build_and_simulate_3d_plants/choose_a_workflow).

## Use the same structure for simulation

The same MTG can be used for visualization and passed to `CompositeModel`.
The [MTG import guide](import_mtg.md) explains how to use its nodes as
simulation objects and initialize their values. Use the node and object IDs
to match organs with their simulation results.

If you built a simulation directly from `Object`s, you do not need to create
an MTG just to inspect it. The **Objects** tab in PlantSimEngine's
[graph viewer](../graph_visualizer_editor.md) shows their parent links.
Its **Applications** and **Executions** tabs show the models and their
connections. These help you check which calculations run on each object
and where their inputs come from.

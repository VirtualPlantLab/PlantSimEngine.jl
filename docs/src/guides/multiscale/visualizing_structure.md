# Visualize Plant Structure

A structure diagram helps check which organs belong to which plant. A model
dependency diagram answers a different question: which calculation supplies
which input. Use the [graph viewer](../graph_visualizer_editor.md) for model
dependencies, and object parent links for plant structure.

## Draw the parent links

This small example needs `DataFrames` and `CairoMakie` in your project. It
draws one plant with two leaves from the public object diagnostics:

```@example structure_plot
using PlantSimEngine, DataFrames, CairoMakie

model = CompositeModel(
    Object(:plant; scale=:Plant, kind=:plant),
    Object(:leaf_1; scale=:Leaf, parent=:plant),
    Object(:leaf_2; scale=:Leaf, parent=:plant),
)
rows = Diagnostics.explain_objects(model)
select(DataFrame(rows), :id, :scale, :parent)
```

The coordinates below are chosen for a readable diagram. They are not organ
positions or a reconstructed 3D plant.

```@example structure_plot
positions = Dict(:plant => (0.0, 0.0),
                 :leaf_1 => (-1.0, 1.0), :leaf_2 => (1.0, 1.0))
fig = Figure(size=(620, 320))
ax = Axis(fig[1, 1]; title="One plant, two leaves", aspect=DataAspect())

for row in rows
    x, y = positions[row.id]
    if !isnothing(row.parent)
        px, py = positions[row.parent]
        lines!(ax, [px, x], [py, y]; color=:gray55, linewidth=2)
    end
    color = row.scale == :Plant ? :sienna : :seagreen
    scatter!(ax, [x], [y]; color, markersize=22)
    text!(ax, x, y; text=string(row.id), offset=(0, 16), align=(:center, :bottom))
end
limits!(ax, -1.6, 1.6, -0.3, 1.6)
hidedecorations!(ax)
hidespines!(ax)
save("plant-structure.svg", fig) # hide
nothing # hide
```

![](plant-structure.svg)

For a larger structure, choose a tree-layout algorithm or positions from your
geometry data. Keep object IDs as the link between results, geometry, and
labels. After growth or pruning, call `Diagnostics.explain_objects(model)`
again to draw the current topology; retained simulation outputs still include
the history of removed organs.

For plant instances, `Diagnostics.explain_instances(model)` identifies their
roots. `Diagnostics.explain_scopes(model)` helps check the groups used by
selectors. Rendering stays outside the process equations, so the same model
can be used with or without a visualization.

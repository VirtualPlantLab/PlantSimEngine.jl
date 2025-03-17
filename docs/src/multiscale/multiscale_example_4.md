# Visualizing a plant

We've created our toy plant, part of the fun is to actually visualize it !

Let's see how to do so with the [PlantGeom](https://github.com/VEZY/PlantGeom.jl) companion package.

We'll be reusing the mtg from part 3 of the plant tutorial: [Fixing bugs in the plant simulation](@ref), so you need to run that simulation first.

You'll need to add PlantGeom and a compatible visualization package to your environment. We'll use Plots:

```julia
using Plots
using PlantGeom

RecipesBase.plot(mtg)
```

This provides the following visualization:
![MTG Plots visualization](../www/mtg_plot_1.svg)

And that's it !

We can see the root expansion in one direction, and the internodes with their leaves in the other.

You can find other examples with PlantGeom and other backends such as CairoMakie [here](https://vezy.github.io/PlantGeom.jl/stable/)

!!! note
    This is just a quick visualization, with no 3D, and little control over parameters. There's a lot more that can be done with PlantGeom (and more to come on the roadmap), which we might showcase later.
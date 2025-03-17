###########################################
# Toy plant model MTG visualisation using PlantGeom
###########################################
using PlantSimEngine

using MultiScaleTreeGraph
using Plots
using PlantGeom

# reusing the mtg from part 3:
RecipesBase.plot(mtg)

#=
using GLMakie
#using CairoMakie
using PlantGeom

PlantGeom.diagram(mtg)=#
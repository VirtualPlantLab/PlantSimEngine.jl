# Automated tests : downstream dependency checking

PlantSimEngine is [open sourced on Github](https://github.com/VirtualPlantLab/PlantSimEngine.jl), and so are its other companion packages, [PlantGeom.jl](https://github.com/VEZY/PlantGeom.jl), [PlantMeteo.jl](https://github.com/VEZY/PlantMeteo.jl), [PlantBioPhysics.jl](https://github.com/VEZY/PlantBioPhysics.jl), [MultiScaleTreeGraph.jl](https://github.com/VEZY/MultiScaleTreeGraph.jl), and [XPalm](https://github.com/PalmStudio/XPalm.jl).

One handy CI (Continuous Integration) feature implemented for these packages is automated integration and downstream testing: after changes to a package, its known downstream dependencies are tested to ensure no breaking changes were introduced. 

For instance, PlantBioPhysics uses PlantSimEngine, so an integration test ensures that PlantBioPhysics's tests don't break in an unforeseen manner after a new PlantSimEngine release. There also is a benchmark check in the downstream tests: [https://github.com/VirtualPlantLab/PlantSimEngine.jl/blob/main/test/downstream/test-plantbiophysics.jl]

This is something you can take advantage of if you wish to develop using PlantSimEngine, by providing us with your package name (or adding it to the CI yml file in a Pull Request); we can then add it to the list of downstream packages to test, and generate PR when breaking changes are introduced.